import Foundation

/// Diagnostic policy only. These engineering cutoffs are NOT calibrated authentication thresholds.
public enum FaceComparisonPolicy {
    public static let identifier = "top3-median12-diagnostic-v1"
    public static let similarCutoff = 0.50
    public static let differentCutoff = 0.40
    public static let requiredFrames = 12
    public static let minimumSpacing = 0.15
    public static let minimumDuration = 1.65
    public static let maximumGap = 0.60
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
    private var scores: [Double] = []
    private var firstTime: Double?
    private var lastTime: Double?
    private var previousBounds: FaceBounds?
    public private(set) var result: FaceComparisonResult?
    public var count: Int { scores.count }
    public var latestSimilarity: Double? { scores.last }
    public var description: String { "FaceComparisonWindow(frames: \(count), biometric data: redacted)" }
    public var debugDescription: String { description }

    public init(template: EnrollmentTemplate) throws {
        guard template.format == .continuousVideo else { throw EnrollmentError.incompatible }
        self.template = template
    }

    public mutating func interrupt() {
        scores.removeAll(keepingCapacity: true)
        firstTime = nil; lastTime = nil; previousBounds = nil; result = nil
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
        if let result { return result }
        if let lastTime {
            guard time > lastTime else { interrupt(); return nil }
            if time - lastTime > FaceComparisonPolicy.maximumGap { interrupt() }
            else if time - lastTime + 1e-9 < FaceComparisonPolicy.minimumSpacing { return nil }
        }
        if let previousBounds, let bounds = metrics.faceBounds {
            let oldArea = previousBounds.width * previousBounds.height
            let newArea = bounds.width * bounds.height
            if abs(bounds.x + bounds.width / 2 - previousBounds.x - previousBounds.width / 2) > 0.12 ||
                abs(bounds.y + bounds.height / 2 - previousBounds.y - previousBounds.height / 2) > 0.12 ||
                newArea / oldArea > 1.8 || oldArea / newArea > 1.8 { interrupt() }
        }
        let nearest = try template.embeddings.map { try embedding.cosineSimilarity(to: $0) }.sorted(by: >).prefix(3)
        let score = nearest.reduce(0, +) / 3
        if firstTime == nil { firstTime = time }
        lastTime = time; previousBounds = metrics.faceBounds
        scores.append(score)
        // A bounded rolling window must satisfy BOTH frame count and elapsed camera time.
        if scores.count > FaceComparisonPolicy.requiredFrames { scores.removeFirst() }
        guard scores.count == FaceComparisonPolicy.requiredFrames,
              let firstTime, time - firstTime + 1e-9 >= FaceComparisonPolicy.minimumDuration else { return nil }
        let ordered = scores.sorted()
        let median = (ordered[5] + ordered[6]) / 2
        let above = scores.filter { $0 >= FaceComparisonPolicy.similarCutoff }.count
        let below = scores.filter { $0 < FaceComparisonPolicy.differentCutoff }.count
        let outcome: FaceComparisonOutcome = median >= FaceComparisonPolicy.similarCutoff && above >= 10 ? .similar :
            (median < FaceComparisonPolicy.differentCutoff && below >= 10 ? .different : .inconclusive)
        let completed = FaceComparisonResult(outcome: outcome, medianSimilarity: median,
                                             minimumSimilarity: ordered[0], maximumSimilarity: ordered[11],
                                             aboveCutoff: above, frameCount: scores.count)
        result = completed
        return completed
    }
}
