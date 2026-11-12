import Foundation

/// Diagnostic policy only. These engineering cutoffs are NOT calibrated authentication thresholds.
public enum FaceComparisonPolicy {
    public static let identifier = "top3-median12-diagnostic-v5"
    public static let similarCutoff = 0.50
    public static let differentCutoff = 0.40
    public static let requiredFrames = 12
    public static let requiredAgreement = 10
    public static let minimumSpacing = 0.15
    public static let minimumDuration = 1.65
    public static let maximumGap = 0.60
}

/// Short windows are for desktop evaluation only; unlock always uses standard.
public enum FaceComparisonMode: String, CaseIterable, Sendable {
    case standard, shortEvaluation
    public var requiredFrames: Int { self == .standard ? FaceComparisonPolicy.requiredFrames : 6 }
    public var requiredAgreement: Int { self == .standard ? FaceComparisonPolicy.requiredAgreement : 5 }
    public var minimumDuration: Double { self == .standard ? FaceComparisonPolicy.minimumDuration : 0.75 }
}

public enum FaceComparisonOutcome: String, Sendable {
    case similar, different, inconclusive
}

public struct FaceComparisonResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let outcome: FaceComparisonOutcome
    public let medianSimilarity: Double
    public let minimumSimilarity: Double
    public let maximumSimilarity: Double
    public let aboveCutoff: Int
    public let frameCount: Int
    public var description: String { "FaceComparisonResult(biometric scores: redacted)" }
    public var debugDescription: String { description }
}

/// Retains scalar scores and bounds only. No frames or probe embeddings survive observe().
public struct FaceComparisonWindow: CustomStringConvertible, CustomDebugStringConvertible {
    private let template: EnrollmentTemplate
    private let mode: FaceComparisonMode
    private var scores: [Double] = []
    private var times: [Double] = []
    private var lastTime: Double?
    private var previousBounds: FaceBounds?
    public private(set) var result: FaceComparisonResult?
    public var count: Int { scores.count }
    public var latestSimilarity: Double? { scores.last }
    public var description: String { "FaceComparisonWindow(frames: \(count), biometric data: redacted)" }
    public var debugDescription: String { description }

    public init(template: EnrollmentTemplate, mode: FaceComparisonMode = .standard) throws {
        guard template.format == .continuousVideo else { throw EnrollmentError.incompatible }
        self.template = template; self.mode = mode
    }

    /// Admit only frames that can contribute, before expensive image analysis.
    /// Invalid/backward timestamps still reach observe() so it can invalidate old evidence.
    public func shouldAnalyze(at time: Double) -> Bool {
        guard let lastTime, time.isFinite, time > lastTime else { return true }
        return time - lastTime + 1e-9 >= FaceComparisonPolicy.minimumSpacing
    }

    public mutating func interrupt() {
        scores.removeAll(keepingCapacity: true)
        times.removeAll(keepingCapacity: true); lastTime = nil; previousBounds = nil; result = nil
    }

    public func similarity(for embedding: FaceEmbedding) throws -> Double {
        guard embedding.modelIdentifier == template.modelIdentifier else { throw EnrollmentError.incompatible }
        let nearest = try template.embeddings.map { try embedding.cosineSimilarity(to: $0) }.sorted(by: >).prefix(3)
        return nearest.reduce(0, +) / 3
    }

    public static func adjustment(for metrics: EnrollmentMetrics) -> String? {
        guard [metrics.quality, metrics.yaw, metrics.pitch, metrics.roll, metrics.faceWidthPixels,
               metrics.faceHeightPixels, metrics.luminance].allSatisfy(\.isFinite),
              let bounds = metrics.faceBounds, bounds.isValid else { return "Face the camera so it can measure your face." }
        if bounds.isClipped { return "Move back a little so your whole face is visible." }
        if metrics.faceWidthPixels < 120 || metrics.faceHeightPixels < 120 { return "Move a little closer to the camera." }
        if metrics.luminance < 35 { return "Add some light in front of your face." }
        if metrics.luminance > 235 { return "Reduce the bright light on your face." }
        if abs(metrics.yaw) > 0.50 || abs(metrics.pitch) > 0.65 || abs(metrics.roll) > 0.35 {
            return "Look toward the camera and keep your head level."
        }
        if !(0.2...1).contains(metrics.quality) { return "Hold still in even light, with your face unobstructed." }
        return nil
    }

    /// Each frame uses the mean of its three closest enrollment descriptors; one exceptional
    /// template score cannot decide the result. Invalid input breaks the temporal window.
    @discardableResult
    public mutating func observe(_ embedding: FaceEmbedding, metrics: EnrollmentMetrics, at time: Double) throws -> FaceComparisonResult? {
        guard embedding.modelIdentifier == template.modelIdentifier else { interrupt(); throw EnrollmentError.incompatible }
        guard time.isFinite, time >= 0, Self.adjustment(for: metrics) == nil else { interrupt(); return nil }
        if let lastTime {
            guard time > lastTime else { interrupt(); return nil }
            if time - lastTime > FaceComparisonPolicy.maximumGap { interrupt() }
            else if time - lastTime + 1e-9 < FaceComparisonPolicy.minimumSpacing { return nil }
        }
        if let previousBounds, let bounds = metrics.faceBounds,
           !FaceTrackContinuity.isContinuous(from: previousBounds, to: bounds) { interrupt() }
        let score = try similarity(for: embedding)
        if let previousScore = scores.last,
           (previousScore >= FaceComparisonPolicy.similarCutoff && score < FaceComparisonPolicy.differentCutoff) ||
           (previousScore < FaceComparisonPolicy.differentCutoff && score >= FaceComparisonPolicy.similarCutoff) {
            // Do not carry the owner's votes into a different face's window.
            interrupt()
        }
        lastTime = time; previousBounds = metrics.faceBounds
        scores.append(score); times.append(time); result = nil
        // A bounded rolling window must satisfy BOTH frame count and elapsed camera time.
        if scores.count > mode.requiredFrames { scores.removeFirst(); times.removeFirst() }
        guard scores.count == mode.requiredFrames,
              let firstTime = times.first, time - firstTime + 1e-9 >= mode.minimumDuration else { return nil }
        let ordered = scores.sorted()
        let middle = ordered.count / 2
        let median = (ordered[middle - 1] + ordered[middle]) / 2
        let above = scores.filter { $0 >= FaceComparisonPolicy.similarCutoff }.count
        let below = scores.filter { $0 < FaceComparisonPolicy.differentCutoff }.count
        let outcome: FaceComparisonOutcome = score >= FaceComparisonPolicy.similarCutoff && median >= FaceComparisonPolicy.similarCutoff && above >= mode.requiredAgreement ? .similar :
            (median < FaceComparisonPolicy.differentCutoff && below >= mode.requiredAgreement ? .different : .inconclusive)
        let completed = FaceComparisonResult(outcome: outcome, medianSimilarity: median,
                                             minimumSimilarity: ordered[0], maximumSimilarity: ordered[ordered.count - 1],
                                             aboveCutoff: above, frameCount: scores.count)
        result = completed
        return completed
    }
}
