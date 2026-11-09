import AppKit
import Combine
import Darwin
import FaceUnlockCore

public struct SessionChange: Identifiable {
    public let id = UUID()
    public let recordedAt: Date
    public let summary: String
}

/// Observes only. No camera, credentials, keyboard events, or system configuration writes.
@MainActor
public final class MacSessionMonitor: NSObject, ObservableObject {
    @Published public private(set) var snapshot: SessionSnapshot
    @Published public private(set) var lastEvent = "Initial observation"
    @Published public private(set) var recentChanges: [SessionChange] = []
    private let reader = MacSessionReader()
    private var polling: Task<Void, Never>?
    private var sleeping = false
    private var inactive = false
    public var isSuspended: Bool { sleeping || inactive }

    public override init() {
        snapshot = MacSessionReader().read()
        super.init()
        recordChange()
    }

    public func start() {
        guard polling == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
        refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.refresh()
            }
        }
    }

    public func stop() {
        polling?.cancel()
        polling = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        invalidate()
        lastEvent = "Observation stopped"
    }

    public func refresh() {
        if sleeping || inactive { invalidate() } else { snapshot = reader.read() }
        recordChange()
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        // Lifecycle signals invalidate observations; polling independently resamples.
        switch notification.name {
        case NSWorkspace.willSleepNotification:
            sleeping = true
            lastEvent = "System will sleep"
        case NSWorkspace.didWakeNotification:
            sleeping = false
            lastEvent = "System woke"
        case NSWorkspace.sessionDidResignActiveNotification:
            inactive = true
            lastEvent = "Session became inactive"
        case NSWorkspace.sessionDidBecomeActiveNotification:
            inactive = false
            lastEvent = "Session became active"
        default: return
        }
        // Never retain a locked observation across sleep or a session transition.
        invalidate()
    }

    private func invalidate() {
        snapshot = SessionSnapshot(processUserID: getuid(), sampledAtUptime: ProcessInfo.processInfo.systemUptime)
        recordChange()
    }

    private func recordChange() {
        let account = snapshot.consoleUserID.map(String.init) ?? "Unknown"
        let summary = "Console UID \(account): \(snapshot.assessment(at: snapshot.sampledAtUptime).rawValue)"
        guard recentChanges.first?.summary != summary else { return }
        recentChanges.insert(SessionChange(recordedAt: Date(), summary: summary), at: 0)
        recentChanges = Array(recentChanges.prefix(8))
    }

    deinit { polling?.cancel() }
}
