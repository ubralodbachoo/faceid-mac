import Foundation

public enum EnrollmentPose: Int, Codable, CaseIterable, Sendable {
    case center, left, upperLeft, up, upperRight, right, lowerRight, down, lowerLeft

    public var title: String {
        switch self {
        case .center: "Look naturally at the camera"
        case .left: "Turn gently to your left"
        case .upperLeft: "Look a little up and left"
        case .up: "Lift your chin slightly"
        case .upperRight: "Look a little up and right"
        case .right: "Turn gently to your right"
        case .lowerRight: "Look a little down and right"
        case .down: "Lower your chin slightly"
        case .lowerLeft: "Look a little down and left"
        }
    }
    public var compassAngle: Double? {
        switch self {
        case .center: nil
        case .left: 270
        case .upperLeft: 315
        case .up: 0
        case .upperRight: 45
        case .right: 90
        case .lowerRight: 135
        case .down: 180
        case .lowerLeft: 225
        }
    }
    var yawSign: Double {
        switch self {
        case .left, .upperLeft, .lowerLeft: 1
        case .right, .upperRight, .lowerRight: -1
        default: 0
        }
    }
    var pitchSign: Double {
        switch self {
        case .up, .upperLeft, .upperRight: -1
        case .down, .lowerLeft, .lowerRight: 1
        default: 0
        }
    }
}

public struct VideoEnrollmentUpdate: Sendable {
    public let pose: EnrollmentPose?
    public let completedPoses: Int
    public let sampleCount: Int
    public let holdProgress: Double
    public let feedback: String
    public let trackedBounds: FaceBounds?
    public let capturedPose: Bool
}

/// Temporal collection policy only, never an identity or liveness decision. No images are held.
/// A continuous stable burst is required; a single lucky frame or repeated timestamp cannot advance.
public struct VideoEnrollmentCollector: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let samplesPerPose = 2
    public static let requiredSamples = EnrollmentPose.allCases.count * samplesPerPose
    public static let pipelineIdentifier = "vision-rect3-landmarks3-quality3-fivepoint-video-v2"
    public static let policyIdentifier = "nine-directions-stable-burst-v1"
    public let modelIdentifier: String
    private var vectors: [FaceEmbedding] = []
    private var poseIndex = 0
    private var candidates: [Candidate] = []
    private var lastTime: Double?
    private var segmentStart: Double?
    private var smoothYaw: Double?
    private var smoothPitch: Double?
    private var smoothBounds: FaceBounds?
    private var baselineYaw = 0.0
    private var baselinePitch = 0.0
    public var currentPose: EnrollmentPose? { poseIndex < EnrollmentPose.allCases.count ? EnrollmentPose.allCases[poseIndex] : nil }
    public var completedPoses: Int { poseIndex }
    public var sampleCount: Int { vectors.count }
    public var description: String { "VideoEnrollmentCollector(poses: \(poseIndex), samples: \(vectors.count), biometric data: redacted)" }
    public var debugDescription: String { description }

    public init(modelIdentifier: String) { self.modelIdentifier = modelIdentifier }

    /// Called on tracking loss, multiple faces, pause, or interrupted inference. Accepted poses
    /// survive within the caller's authorization lease; unfinished bursts and smoothing never do.
    public mutating func interrupt(restartWarmup: Bool = false) {
        candidates.removeAll()
        lastTime = nil
        if restartWarmup { segmentStart = nil }
        smoothYaw = nil; smoothPitch = nil; smoothBounds = nil
    }

    public mutating func observe(_ embedding: FaceEmbedding, metrics: EnrollmentMetrics, at time: Double) throws -> VideoEnrollmentUpdate {
        guard embedding.modelIdentifier == modelIdentifier else { throw EnrollmentError.incompatible }
        guard let pose = currentPose else { throw EnrollmentError.incomplete }
        guard time.isFinite, time >= 0 else { interrupt(); throw EnrollmentError.quality }
        if let lastTime, time <= lastTime { candidates.removeAll(); return update("Waiting for a fresh camera frame.") }
        if let lastTime, time - lastTime > 0.4 { interrupt() }
        lastTime = time
        if segmentStart == nil { segmentStart = time }
        guard let bounds = metrics.faceBounds, bounds.isValid else {
            candidates.removeAll(); return update("Face the camera so it can locate your face.")
        }
        if let issue = qualityAdjustment(metrics, pose: pose) {
            candidates.removeAll()
            smoothYaw = nil; smoothPitch = nil; smoothBounds = bounds
            return update(issue)
        }
        let previousBounds = smoothBounds
        let alpha = 0.45
        smoothYaw = smoothYaw.map { $0 + alpha * (metrics.yaw - $0) } ?? metrics.yaw
        smoothPitch = smoothPitch.map { $0 + alpha * (metrics.pitch - $0) } ?? metrics.pitch
        smoothBounds = previousBounds.map { old in
            FaceBounds(x: old.x + alpha * (bounds.x - old.x), y: old.y + alpha * (bounds.y - old.y),
                       width: old.width + alpha * (bounds.width - old.width), height: old.height + alpha * (bounds.height - old.height))
        } ?? bounds
        guard let yaw = smoothYaw, let pitch = smoothPitch else { throw EnrollmentError.quality }
        guard time - (segmentStart ?? time) >= 0.35 else { candidates.removeAll(); return update("Getting a steady view of your face…") }
        let rawMatches = matches(pose, yaw: metrics.yaw, pitch: metrics.pitch)
        guard rawMatches && matches(pose, yaw: yaw, pitch: pitch) else {
            candidates.removeAll(); return update(pose.title)
        }
        let positionSteady = previousBounds.map {
            abs(($0.x + $0.width / 2) - (bounds.x + bounds.width / 2)) < 0.045 &&
            abs(($0.y + $0.height / 2) - (bounds.y + bounds.height / 2)) < 0.055
        } ?? true
        guard positionSteady, abs(metrics.yaw - yaw) <= 0.10, abs(metrics.pitch - pitch) <= 0.10 else {
            candidates.removeAll(); return update("Slow down a little and settle into the turn.")
        }
        candidates.append(Candidate(embedding: embedding, time: time, quality: metrics.quality,
                                    yaw: metrics.yaw, pitch: metrics.pitch))
        if candidates.count > 24 { candidates.removeFirst(candidates.count - 24) }
        // Four distinct observations over at least 0.30 seconds; choose two quality-ranked,
        // temporally separated samples instead of immediately keeping a single frame.
        guard candidates.count >= 4, let first = candidates.first, time - first.time >= 0.30 else {
            return update("Hold that angle for a moment…")
        }
        let ranked = candidates.sorted { $0.quality > $1.quality }
        guard let best = ranked.first,
              let second = ranked.dropFirst().first(where: { abs($0.time - best.time) >= 0.2 }) else {
            return update("Hold that angle for a moment…")
        }
        let selected = [best, second].sorted { $0.time < $1.time }
        vectors.append(contentsOf: selected.map(\.embedding))
        if pose == .center {
            baselineYaw = candidates.map(\.yaw).reduce(0, +) / Double(candidates.count)
            baselinePitch = candidates.map(\.pitch).reduce(0, +) / Double(candidates.count)
        }
        poseIndex += 1
        candidates.removeAll()
        return update(currentPose?.title ?? "Scan complete. Ready to save.", captured: true)
    }

    public func finish() throws -> EnrollmentTemplate {
        guard currentPose == nil else { throw EnrollmentError.incomplete }
        return try EnrollmentTemplate(embeddings: vectors, modelIdentifier: modelIdentifier)
    }

    private func update(_ feedback: String, captured: Bool = false) -> VideoEnrollmentUpdate {
        let duration = candidates.first.flatMap { first in lastTime.map { $0 - first.time } } ?? 0
        let progress = min(1, min(Double(candidates.count) / 4, duration / 0.30))
        return VideoEnrollmentUpdate(pose: currentPose, completedPoses: poseIndex, sampleCount: vectors.count,
                                     holdProgress: progress, feedback: feedback, trackedBounds: smoothBounds, capturedPose: captured)
    }

    private func qualityAdjustment(_ metrics: EnrollmentMetrics, pose: EnrollmentPose) -> String? {
        guard [metrics.quality, metrics.yaw, metrics.pitch, metrics.roll, metrics.faceWidthPixels,
               metrics.faceHeightPixels, metrics.luminance].allSatisfy(\.isFinite) else { return "The camera could not read your face. Look toward the lens." }
        if metrics.faceBounds?.isClipped == true { return "Move a little farther back so your whole face is visible." }
        if pose == .center && !metrics.centered { return "Place your face near the middle of the circle." }
        if metrics.faceWidthPixels < 120 || metrics.faceHeightPixels < 120 { return "Move a little closer to the camera." }
        if metrics.luminance < 35 { return "Add some light in front of your face." }
        if metrics.luminance > 235 { return "Reduce the bright light on your face." }
        if metrics.quality < 0.2 || metrics.quality > 1 { return "Hold still in even light, with your face unobstructed." }
        if abs(metrics.roll) > 0.35 { return "Keep your head level instead of leaning sideways." }
        if abs(metrics.yaw) > 0.8 || abs(metrics.pitch) > 0.7 { return "Turn back a little so the camera can see both eyes." }
        return nil
    }

    private func matches(_ pose: EnrollmentPose, yaw: Double, pitch: Double) -> Bool {
        // Laptop cameras look down at the user. Calibrate a stable, usable natural pitch
        // instead of making everyone first reach an artificial zero-pitch pose.
        if pose == .center { return abs(yaw) <= 0.35 && abs(pitch) <= 0.55 }
        let relativeYaw = yaw - baselineYaw, relativePitch = pitch - baselinePitch
        let yawOK = pose.yawSign == 0 ? abs(relativeYaw) <= 0.18
            : (0.13...0.48).contains(relativeYaw * pose.yawSign)
        let pitchOK = pose.pitchSign == 0 ? abs(relativePitch) <= 0.18
            : (0.10...0.38).contains(relativePitch * pose.pitchSign)
        return yawOK && pitchOK
    }

    private struct Candidate: Sendable {
        let embedding: FaceEmbedding
        let time: Double
        let quality: Double
        let yaw: Double
        let pitch: Double
    }
}
