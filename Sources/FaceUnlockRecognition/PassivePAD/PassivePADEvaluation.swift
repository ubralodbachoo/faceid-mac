import Foundation

public enum PassivePADEvaluationDecision: String, Sendable {
    case unavailable, uncertain, liveCandidate, spoofCandidate
}

/// Experimental engineering cutoffs. Produces evidence only; callers enforce identity/session/input guards.
public struct PassivePADEvaluationWindow {
    public static let liveCutoff = 0.90
    public static let spoofCutoff = 0.10
    public static let requiredFrames = 3
    private var lastTime: Double?
    private var liveTimes: [Double] = []
    public var evidenceObservedAt: Double? { decision == .liveCandidate ? liveTimes.first : nil }
    private var liveFrames = 0
    private var spoofFrames = 0
    public private(set) var decision = PassivePADEvaluationDecision.unavailable

    public init() {}

    public mutating func reset() {
        liveTimes.removeAll(keepingCapacity: true)
        lastTime = nil; liveFrames = 0; spoofFrames = 0; decision = .unavailable
    }

    @discardableResult
    public mutating func observe(_ scores: PassivePADScores?, at time: Double) -> PassivePADEvaluationDecision {
        guard let scores, time.isFinite, time >= 0 else { reset(); return decision }
        if let lastTime {
            guard time > lastTime else { reset(); return decision }
            if time - lastTime > 0.6 { reset() }
        }
        lastTime = time
        if scores.minimumLive >= Self.liveCutoff {
            liveTimes.append(time)
            if liveTimes.count > Self.requiredFrames { liveTimes.removeFirst() }
        } else { liveTimes.removeAll(keepingCapacity: true) }
        liveFrames = liveTimes.count
        spoofFrames = max(scores.nearLive, scores.wideLive) <= Self.spoofCutoff ? spoofFrames + 1 : 0
        decision = liveFrames >= Self.requiredFrames ? .liveCandidate :
            spoofFrames >= Self.requiredFrames ? .spoofCandidate : .uncertain
        return decision
    }
}
