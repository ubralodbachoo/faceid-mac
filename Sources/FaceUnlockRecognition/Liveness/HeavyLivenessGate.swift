import CoreGraphics
import Foundation

public enum ExperimentalLivenessDecision: String, Sendable {
    case unavailable, pending, passed, rejected
}

/// Glance Heavy policy only. This is heuristic RGB evidence, never calibrated PAD verification.
/// Own one gate per scan and reset it whenever the identity track is interrupted.
public struct HeavyLivenessGate {
    private var frames: [LivenessFrame] = []
    private var evaluator = LivenessEvaluator(mode: .heavy)
    private var lastTime: Double?
    private var confirmedAt: Double?
    public private(set) var cue: String?
    /// Earliest observation backing the current positive latch, for the input freshness guard.
    public var evidenceObservedAt: Double? { confirmedAt }

    public init() {}

    public mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        evaluator.reset()
        lastTime = nil; confirmedAt = nil; cue = nil
    }

    public mutating func observe(_ frame: LivenessFrame?, at time: Double) -> ExperimentalLivenessDecision {
        guard time.isFinite, time >= 0, let frame, frame.isUsable else { reset(); return .unavailable }
        if let lastTime {
            guard time > lastTime else { reset(); return .unavailable }
            if time - lastTime > 0.6 { reset() }
        }
        // A latched positive may not survive an extended wait for the password field.
        if let confirmedAt, time - confirmedAt > 0.75 { reset() }
        lastTime = time
        frames.append(frame.stamped(at: time))
        frames.removeAll { time - $0.timestamp.timeIntervalSinceReferenceDate > 2 }
        if frames.count > 40 { frames.removeFirst(frames.count - 40) }
        let readings = LivenessCues.readings(window: frames, geometry: GeometryLiveness.evaluate(frames))
        let snapshot = evaluator.observe(readings)
        switch snapshot.decision {
        case .denied(let reason):
            cue = reason.rawValue
            return .rejected
        case .confirmed(let reason):
            guard let reason else { return .pending } // No deny-only auto-confirmation.
            if confirmedAt == nil { confirmedAt = time }
            cue = reason.rawValue
            return .passed
        case .pending:
            cue = nil
            return .pending
        }
    }
}

private extension LivenessFrame {
    var isUsable: Bool {
        guard hasReliableLandmarks, let yaw, yaw.isFinite,
              let interocularDistance, interocularDistance.isFinite, interocularDistance > 0,
              let noseOffsetRatio, noseOffsetRatio.isFinite,
              let leftEyeAspectRatio, leftEyeAspectRatio.isFinite, leftEyeAspectRatio > 0,
              let rightEyeAspectRatio, rightEyeAspectRatio.isFinite, rightEyeAspectRatio > 0,
              let deviceOverlapFraction, deviceOverlapFraction.isFinite, (0...1).contains(deviceOverlapFraction),
              let glare, glare.cropPixelWidth.isFinite, glare.cropPixelWidth >= 50,
              glare.specularFraction.isFinite, (0...1).contains(glare.specularFraction),
              glare.specularClusterRatio.isFinite, (0...1).contains(glare.specularClusterRatio),
              !landmarks.isEmpty, landmarks.allSatisfy({ $0.point.x.isFinite && $0.point.y.isFinite }) else { return false }
        return true
    }

    func stamped(at time: Double) -> LivenessFrame {
        LivenessFrame(timestamp: Date(timeIntervalSinceReferenceDate: time), landmarks: landmarks,
            interocularDistance: interocularDistance, yaw: yaw,
            leftEyeAspectRatio: leftEyeAspectRatio, rightEyeAspectRatio: rightEyeAspectRatio,
            noseOffsetRatio: noseOffsetRatio, hasReliableLandmarks: hasReliableLandmarks,
            deviceOverlapFraction: deviceOverlapFraction, glare: glare, deviceDiagnostics: deviceDiagnostics)
    }
}
