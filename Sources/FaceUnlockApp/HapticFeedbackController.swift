import AppKit
import Combine

enum HapticCue: Equatable { case progress, success, failure }

/// Each cue follows a real operation event; decorative previews never trigger it.
@MainActor
final class HapticFeedbackController {
    private let enabled: () -> Bool
    private let uptime: () -> TimeInterval
    private let emit: (HapticCue) -> Void
    private var lastCueAt: TimeInterval?
    private var lastUnlockPhase = LockScreenPhase.idle
    private var lastEnrollmentPhase = EnrollmentPhase.idle
    private var lastPoseCount = 0
    private var observations: Set<AnyCancellable> = []

    init(enabled: @escaping () -> Bool, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (HapticCue) -> Void = { cue in
             let pattern: NSHapticFeedbackManager.FeedbackPattern
             switch cue {
             case .progress: pattern = .alignment
             case .success: pattern = .levelChange
             case .failure: pattern = .generic
             }
             NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
         }) {
        self.enabled = enabled; self.uptime = uptime; self.emit = emit
    }

    func observe(lockScreen: LockScreenFlowModel, enrollment: EnrollmentModel) {
        lockScreen.$phase.sink { [weak self] in self?.unlockChanged($0) }.store(in: &observations)
        enrollment.$completedPoses.sink { [weak self] in self?.poseCountChanged($0) }.store(in: &observations)
        enrollment.$phase.sink { [weak self] in self?.enrollmentChanged($0) }.store(in: &observations)
    }

    func unlockChanged(_ phase: LockScreenPhase) {
        defer { lastUnlockPhase = phase }
        guard phase != lastUnlockPhase else { return }
        if phase == .unlocked { play(.success) }
        else if phase == .fallback && [.scanning, .waitingForPasswordField, .submitting, .awaitingDesktop].contains(lastUnlockPhase) {
            play(.failure)
        }
    }

    func poseCountChanged(_ count: Int) {
        defer { lastPoseCount = count }
        if count > lastPoseCount { play(.progress) }
    }

    func enrollmentChanged(_ phase: EnrollmentPhase) {
        defer { lastEnrollmentPhase = phase }
        if phase == .saved && lastEnrollmentPhase == .review { play(.success) }
        else if phase == .failed && [.capturing, .review, .paused].contains(lastEnrollmentPhase) { play(.failure) }
    }

    private func play(_ cue: HapticCue) {
        guard enabled() else { return }
        let now = uptime()
        guard now.isFinite, lastCueAt.map({ now - $0 >= 0.12 }) ?? true else { return }
        lastCueAt = now; emit(cue)
    }
}
