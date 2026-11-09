import AppKit
@preconcurrency import ApplicationServices
import Combine
import Darwin
import Foundation
import FaceUnlockCore

@MainActor
public final class ManualUnlockController: NSObject, ObservableObject {
    @Published public private(set) var isArmed = false
    @Published public private(set) var status = "No manual test armed"
    @Published public private(set) var events: [String] = []
    @Published public private(set) var canConfirmDesktop = false
    private let monitor: MacSessionMonitor
    public let vault: CredentialVault
    private let input = LockScreenInput()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var attempt: ManualAttempt?

    public init(monitor: MacSessionMonitor, vault: CredentialVault) {
        self.monitor = monitor
        self.vault = vault
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            center.addObserver(self, selector: #selector(revokeForSessionChange(_:)), name: name, object: nil)
        }
    }

    public func requestAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public func requestCamera() async {
        let allowed = await LockedCameraProbe.requestPermission()
        record(allowed ? "Camera permission granted; capture still requires an armed probe" : "Camera permission unavailable")
    }

    public func inspectFocus() {
        do { _ = try input.inspectTarget(); record("Verified focused Apple loginwindow secure field") }
        catch { record(error.localizedDescription) }
    }

    public var report: String {
        let snapshot = MacSessionReader().read()
        return """
        Face Unlock Milestone 1 — manual test report
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(Self.architecture)
        Hardware model: \(Self.hardwareModel)
        App: \(Bundle.main.bundleIdentifier ?? "unbundled") \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        Signing: development ad-hoc build; no distribution claim
        UID: \(getuid()); console: \(snapshot.consoleUserID.map(String.init) ?? "unknown"); session: \(snapshot.sessionUserID.map(String.init) ?? "unknown")
        Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")
        Stored ciphertext: \(vault.hasCredential ? "present" : "absent/unavailable")
        Credential session: \(vault.sessionIsValid ? "authorized" : "locked/expired")
        Current screen report: \(snapshot.screenLock.rawValue)
        Entry method: PID-directed CGEvents, verified Apple loginwindow secure field only
        Face recognition: not connected
        Recent events (memory only):
        \(events.joined(separator: "\n"))
        """
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public func arm(submitPassword: Bool, probeCamera: Bool) {
        guard !isArmed, !vault.isBusy else { return }
        guard NSApp?.isActive == true else { record("Arm the test from this app on your desktop"); return }
        let snapshot = MacSessionReader().read()
        guard accountMatches(snapshot), snapshot.screenLock != .locked else {
            record("Arming requires the current account on its desktop"); return
        }
        guard AXIsProcessTrusted() else { record(InputError.accessibility.localizedDescription); return }
        guard !submitPassword || (vault.sessionIsValid && vault.hasCredential) else {
            record(VaultError.locked.localizedDescription); return
        }
        cancel(revoke: false)
        canConfirmDesktop = false
        let token = UUID()
        generation = token
        attempt = ManualAttempt(userID: getuid(), now: ContinuousTime.now)
        isArmed = true
        record(submitPassword
            ? "ARMED: one password submission within 60 seconds. Lock your Mac normally."
            : "ARMED: observation-only test for 60 seconds. No password will be read or entered.")
        task = Task { [weak self] in
            await self?.run(token: token, submitPassword: submitPassword, probeCamera: probeCamera)
        }
    }

    public func cancel(revoke: Bool = true) {
        generation = UUID()
        attempt?.cancel()
        task?.cancel()
        task = nil
        isArmed = false
        if revoke { vault.lock(); record("Test canceled; credential session locked") }
    }

    public func confirmDesktop(noManualUnlock: Bool) {
        guard canConfirmDesktop, NSApp?.isActive == true else { return }
        let snapshot = MacSessionReader().read()
        guard accountMatches(snapshot), snapshot.screenLock != .locked else {
            record("Cannot confirm desktop: current session is unavailable or still reported locked"); return
        }
        canConfirmDesktop = false
        record(noManualUnlock
            ? "USER CONFIRMED desktop reached after submission without password/Touch ID fallback"
            : "USER REPORTED fallback was needed; the test did not prove an automatic unlock")
    }

    @objc private func revokeForSessionChange(_ notification: Notification) { cancel() }

    private func run(token: UUID, submitPassword: Bool, probeCamera: Bool) async {
        defer {
            if generation == token {
                isArmed = false
                if submitPassword { vault.lock() }
            }
        }
        var cameraChecked = false
        var lastBlocker = ""
        while generation == token, !Task.isCancelled {
            guard let attempt, ContinuousTime.now < attempt.deadline else {
                record("Test expired without submission. Last blocker: \(lastBlocker.isEmpty ? "no explicit locked session" : lastBlocker)")
                return
            }
            if submitPassword && !vault.sessionIsValid { record(VaultError.locked.localizedDescription); return }
            monitor.refresh()
            let snapshot = monitor.snapshot
            let assessment = snapshot.assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5)
            if assessment == .wrongAccount { record(ManualAttemptError.wrongAccount.localizedDescription); vault.lock(); return }
            if assessment == .observedLocked, !monitor.isSuspended {
                do {
                    if probeCamera && !cameraChecked {
                        record("Locked session observed; checking camera")
                        try await LockedCameraProbe.captureOneFrame()
                        guard generation == token, !Task.isCancelled else { return }
                        let fresh = MacSessionReader().read()
                        guard fresh.assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked else {
                            record("Session changed during camera probe; no password submitted"); return
                        }
                        cameraChecked = true
                        record("Camera frame received while current session was reported locked; frame discarded")
                    }
                    guard generation == token, !Task.isCancelled else { return }
                    guard ContinuousTime.now < attempt.deadline else {
                        record("Test expired during preflight; no password submitted"); return
                    }
                    _ = try input.inspectTarget()
                    if !submitPassword {
                        record("Observation-only test passed: locked account and secure field verified. Camera: \(cameraChecked ? "frame received" : "not tested"). No password submitted.")
                        return
                    }
                    var oneShot = attempt
                    let target = try input.inspectTarget()
                    try oneShot.consume(
                        now: ContinuousTime.now, snapshot: MacSessionReader().read(),
                        snapshotUptime: ProcessInfo.processInfo.systemUptime,
                        credentialsReady: vault.sessionIsValid, accessibilityGranted: AXIsProcessTrusted(),
                        secureFocusVerified: true
                    )
                    self.attempt = oneShot
                    do {
                        try vault.withPassword { data in
                            try input.submit(data, to: target) { [self] in
                                guard generation == token, ContinuousTime.now < oneShot.deadline,
                                      vault.sessionIsValid, !monitor.isSuspended else { return false }
                                return MacSessionReader().read().assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked
                            }
                        }
                        canConfirmDesktop = true
                        record("One password attempt submitted to verified loginwindow PID. Desktop unlock is NOT yet confirmed. Return here to report the outcome.")
                    } catch { record("Input stopped; no retry: \(error.localizedDescription)") }
                    return
                } catch let error as ProbeError {
                    record(error.localizedDescription); return
                } catch {
                    // Wait only while nothing has been submitted (for the lock UI to expose focus).
                    guard self.attempt?.consumed != true else { record(error.localizedDescription); return }
                    if error.localizedDescription != lastBlocker {
                        lastBlocker = error.localizedDescription
                        record("Waiting: \(lastBlocker)")
                    }
                }
            } else { lastBlocker = assessment.rawValue }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    private func accountMatches(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.processUserID == getuid() && snapshot.consoleUserID == getuid()
            && snapshot.sessionUserID == getuid() && snapshot.isOnConsole == true && snapshot.loginComplete == true
    }

    private func record(_ message: String) {
        status = message
        events.insert("\(Date().formatted(date: .omitted, time: .standard)): \(message)", at: 0)
        events = Array(events.prefix(12))
    }

    deinit { task?.cancel() }
}
