import Foundation

public enum EnrollmentError: Error, LocalizedError {
    case quality, pose, lighting, incomplete, incompatible, expired, corrupt, busy
    public var errorDescription: String? {
        switch self {
        case .quality: "Use even light, hold still, and keep one unobstructed face closer to the camera."
        case .pose: "Follow the current pose instruction with a small movement; keep your head level."
        case .lighting: "Change the light on your face a little more, then look straight at the camera."
        case .incomplete: "Complete the guided face scan before saving. The saved enrollment was not changed."
        case .incompatible: "This saved face uses a different model or capture format. Register again before verification."
        case .expired: "The biometric session expired or was canceled. Authorize again."
        case .corrupt: "The encrypted enrollment could not be validated. No template was made available."
        case .busy: "An enrollment operation is already running."
        }
    }
}

public enum EnrollmentStep: String, Codable, CaseIterable, Sendable {
    case center, turnOneSide, turnOtherSide, tiltUp, tiltDown, brighter, dimmer
    public var title: String {
        switch self {
        case .center: "Look straight ahead"
        case .turnOneSide: "Turn a little to one side"
        case .turnOtherSide: "Now turn the other way"
        case .tiltUp: "Lift your chin slightly"
        case .tiltDown: "Now lower your chin slightly"
        case .brighter: "Add a little light"
        case .dimmer: "Try slightly softer light"
        }
    }
    public var help: String {
        switch self {
        case .center: "Place your face inside the oval and hold still."
        case .turnOneSide: "Turn toward either shoulder, keeping your eyes near the camera."
        case .turnOtherSide: "Turn toward your other shoulder. A small movement is enough."
        case .tiltUp: "Keep facing the camera and gently tilt your head upward."
        case .tiltDown: "Tilt in the opposite direction without turning sideways."
        case .brighter: "Face a nearby lamp or add light in front of you. Look straight ahead."
        case .dimmer: "Reduce that light a little, keeping your face visible and facing forward."
        }
    }
    public var symbol: String {
        switch self {
        case .center: "person.crop.rectangle"
        case .turnOneSide, .turnOtherSide: "arrow.left.and.right"
        case .tiltUp: "arrow.up"
        case .tiltDown: "arrow.down"
        case .brighter: "sun.max"
        case .dimmer: "sun.min"
        }
    }
    public var instruction: String {
        switch self {
        case .center: "Look straight at the camera in normal light."
        case .turnOneSide: "Turn slightly to one side."
        case .turnOtherSide: "Turn slightly to the opposite side."
        case .tiltUp: "Look slightly upward."
        case .tiltDown: "Look slightly downward."
        case .brighter: "Look straight ahead and add a little light on your face."
        case .dimmer: "Look straight ahead and reduce the light a little; keep your face visible."
        }
    }
}

/// Capture heuristics, not an identity threshold or liveness test. Never logged or persisted.
public struct EnrollmentMetrics: Codable, Sendable {
    public let quality: Double
    public let yaw: Double
    public let pitch: Double
    public let roll: Double
    public let faceWidthPixels: Double
    public let faceHeightPixels: Double
    public let centered: Bool
    public let luminance: Double
    public let faceBounds: FaceBounds?

    public init(quality: Double, yaw: Double, pitch: Double, roll: Double,
                faceWidthPixels: Double, faceHeightPixels: Double, centered: Bool, luminance: Double,
                faceBounds: FaceBounds? = nil) {
        self.quality = quality; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.faceWidthPixels = faceWidthPixels; self.faceHeightPixels = faceHeightPixels
        self.centered = centered; self.luminance = luminance
        self.faceBounds = faceBounds
    }

    public var adjustment: String? {
        guard [quality, yaw, pitch, roll, faceWidthPixels, faceHeightPixels, luminance].allSatisfy(\.isFinite) else {
            return "Face the camera so it can read your position."
        }
        if faceBounds?.isClipped == true { return "Move a little farther back so your whole face is visible." }
        if !centered { return "Move the detected face box toward the middle of the oval." }
        if faceWidthPixels < 120 || faceHeightPixels < 120 { return "Move a little closer to the camera." }
        if luminance < 45 { return "Add some light in front of your face." }
        if luminance > 220 { return "Reduce the bright light on your face." }
        if abs(roll) > 0.20 { return "Keep your head level, without leaning sideways." }
        if abs(yaw) > 0.50 || abs(pitch) > 0.40 { return "Turn back a little so the camera can see your face." }
        if !(0.35...1).contains(quality) { return "Hold still in even light, with your face unobstructed." }
        return nil
    }

    public func validate() throws {
        guard adjustment == nil else { throw EnrollmentError.quality }
    }
}

/// A complete, validated template. Printable forms deliberately exclude all descriptors.
public struct EnrollmentTemplate: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Format: Int, Sendable { case legacySevenViews = 1, continuousVideo = 2 }
    public let format: Format
    public let modelIdentifier: String
    public let embeddings: [FaceEmbedding]
    public var description: String { "EnrollmentTemplate(samples: \(embeddings.count), biometric data: redacted)" }
    public var debugDescription: String { description }

    public init(embeddings: [FaceEmbedding], modelIdentifier: String, format: Format = .continuousVideo) throws {
        let requiredCount = format == .continuousVideo ? VideoEnrollmentCollector.requiredSamples : 7
        guard embeddings.count == requiredCount else { throw EnrollmentError.incomplete }
        guard !modelIdentifier.isEmpty, embeddings.allSatisfy({ $0.modelIdentifier == modelIdentifier }) else {
            throw EnrollmentError.incompatible
        }
        self.embeddings = embeddings
        self.modelIdentifier = modelIdentifier
        self.format = format
    }
}

/// Legacy v1 collection, retained for compatibility tests only. Production uses VideoEnrollmentCollector.
public struct EnrollmentDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let modelIdentifier: String
    private var embeddings: [FaceEmbedding] = []
    private var baselineLuminance: Double?
    private var firstYaw: Double?
    private var firstPitch: Double?
    public var count: Int { embeddings.count }
    public var nextStep: EnrollmentStep? { count < EnrollmentStep.allCases.count ? EnrollmentStep.allCases[count] : nil }
    public var description: String { "EnrollmentDraft(samples: \(count), biometric data: redacted)" }
    public var debugDescription: String { description }

    public init(modelIdentifier: String) { self.modelIdentifier = modelIdentifier }

    public func poseAdjustment(for metrics: EnrollmentMetrics) -> String {
        switch nextStep {
        case .center, .brighter, .dimmer:
            if metrics.pitch > 0.10 { return "Lift your chin a little and look toward the camera lens." }
            if metrics.pitch < -0.10 { return "Lower your chin a little and look toward the camera lens." }
            return "Turn your nose toward the camera lens, without turning to either side."
        case .turnOneSide, .turnOtherSide:
            if metrics.pitch > 0.12 { return "Lift your chin a little while keeping the small sideways turn." }
            if metrics.pitch < -0.12 { return "Lower your chin a little while keeping the small sideways turn." }
            return nextStep == .turnOtherSide
                ? "Turn toward your other shoulder, past the straight-ahead position."
                : "Turn a little farther toward either shoulder."
        case .tiltUp, .tiltDown:
            if abs(metrics.yaw) > 0.10 { return "Keep your nose facing the camera while you move your chin." }
            return nextStep == .tiltDown
                ? "Move your chin in the opposite direction, past the straight-ahead position."
                : "Lift your chin a little more, without turning sideways."
        case nil: return "All seven views have been captured."
        }
    }

    public mutating func accept(_ embedding: FaceEmbedding, metrics: EnrollmentMetrics) throws {
        guard let step = nextStep else { throw EnrollmentError.incomplete }
        guard embedding.modelIdentifier == modelIdentifier else { throw EnrollmentError.incompatible }
        try metrics.validate()
        let frontal = abs(metrics.yaw) <= 0.10 && abs(metrics.pitch) <= 0.10
        switch step {
        case .center:
            guard frontal else { throw EnrollmentError.pose }
            baselineLuminance = metrics.luminance
        case .turnOneSide:
            guard abs(metrics.yaw) >= 0.16, abs(metrics.pitch) <= 0.12 else { throw EnrollmentError.pose }
            firstYaw = metrics.yaw
        case .turnOtherSide:
            guard abs(metrics.yaw) >= 0.16, abs(metrics.pitch) <= 0.12,
                  let firstYaw, firstYaw * metrics.yaw < 0 else { throw EnrollmentError.pose }
        case .tiltUp:
            // Vision/camera pitch conventions can vary. Require two opposite small tilts.
            guard abs(metrics.pitch) >= 0.12, abs(metrics.yaw) <= 0.10 else { throw EnrollmentError.pose }
            firstPitch = metrics.pitch
        case .tiltDown:
            guard abs(metrics.pitch) >= 0.12, abs(metrics.yaw) <= 0.10,
                  let firstPitch, firstPitch * metrics.pitch < 0 else { throw EnrollmentError.pose }
        case .brighter:
            guard frontal else { throw EnrollmentError.pose }
            guard let baselineLuminance, metrics.luminance >= baselineLuminance + 12 else { throw EnrollmentError.lighting }
        case .dimmer:
            guard frontal else { throw EnrollmentError.pose }
            guard let baselineLuminance, metrics.luminance <= baselineLuminance - 12 else { throw EnrollmentError.lighting }
        }
        embeddings.append(embedding)
    }

    public func finish() throws -> EnrollmentTemplate {
        try EnrollmentTemplate(embeddings: embeddings, modelIdentifier: modelIdentifier, format: .legacySevenViews)
    }
}
