import AppKit
import Combine
import QuartzCore
import SwiftUI
import FaceUnlockMac

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel(provider: MacReadinessProvider())
    private var settingsWindow: NSWindow?
    private var setupPanel: SetupPanel?
    private var observations: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.positionSetup() }.store(in: &observations)
        DistributedNotificationCenter.default().publisher(for: NSNotification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.suspendWindows() }.store(in: &observations)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.suspendWindows() }.store(in: &observations)
        Publishers.CombineLatest(model.setup.$step, model.setup.$isComplete).dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.positionSetup(animated: true) }
            }.store(in: &observations)
        if model.preferences.shouldPresentSetupAtLaunch { showSetup() }
        else { showSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func openSettings() {
        if let setupPanel, setupPanel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            setupPanel.makeKeyAndOrderFront(nil)
        } else { showSettings() }
    }

    func showSettings() {
        model.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = AppEdition.isAdmin ? "Face Unlock — Admin" : "Face Unlock"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: StatusView(model: model, onSetup: { [weak self] in
                self?.showSetup()
            }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showSetup(at step: SetupStep = .permissions) {
        if let setupPanel {
            NSApp.activate(ignoringOtherApps: true)
            setupPanel.makeKeyAndOrderFront(nil)
            return
        }
        guard !model.setup.isBusy, !model.lockScreen.isBusy, !model.enrollment.isBusy,
              !model.enrollment.canSave, !model.faceTest.isBusy, !model.manualTest.isArmed,
              !model.vault.isBusy, !model.recognition.isBusy, !model.passwordSettings.isBusy else { return }
        model.lockIndicator.hide()
        model.setup.restart(at: step)
        settingsWindow?.orderOut(nil)
        let panel = SetupPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Face Unlock setup"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let screen = preferredScreen
        let root = NotchSetupView(model: model, safeTop: screen?.safeAreaInsets.top ?? 0,
                                  onClose: { [weak self] in self?.closeSetup(showSettings: true) })
        let hosting = NSHostingView(rootView: root)
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        panel.contentView = hosting
        setupPanel = panel
        positionSetup()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func positionSetup(animated: Bool = false) {
        guard let panel = setupPanel, let screen = preferredScreen else { return }
        let frame = NotchSetupGeometry.frame(screen: screen.frame, step: model.setup.step,
                                              complete: model.setup.isComplete, safeTop: screen.safeAreaInsets.top)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
        if let hosting = panel.contentView as? NSHostingView<NotchSetupView> {
            hosting.rootView = NotchSetupView(model: model, safeTop: screen.safeAreaInsets.top,
                                              onClose: { [weak self] in self?.closeSetup(showSettings: true) })
        }
    }

    private func closeSetup(showSettings: Bool) {
        guard setupPanel != nil else { return }
        if !model.setup.isComplete { model.setup.cancel() }
        if model.enrollment.isBusy || model.enrollment.canSave { model.enrollment.cancel() }
        setupPanel?.orderOut(nil)
        setupPanel?.contentView = nil // Removes any password field and stops permission polling.
        setupPanel?.close(); setupPanel = nil
        if showSettings { self.showSettings() }
    }

    private func suspendWindows() {
        if model.passwordSettings.isBusy { model.passwordSettings.cancel() }
        if model.enrollment.isBusy || model.enrollment.canSave { model.enrollment.cancel() }
        closeSetup(showSettings: false)
        settingsWindow?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        model.passwordSettings.cancel()
        if model.enrollment.isBusy || model.enrollment.canSave { model.enrollment.cancel() }
        model.faceTest.cancel(); model.manualTest.cancel(); model.recognition.cancel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.passwordSettings.cancel(); model.setup.cancel(); model.manualTest.cancel(); model.recognition.cancel()
        model.enrollment.cancel(); model.faceTest.cancel()
        model.lockScreen.disableAutomaticScanning(); model.lockScreen.cancel(); model.lockIndicator.hide()
    }
}

enum NotchSetupGeometry {
    static func frame(screen: CGRect, step: SetupStep = .permissions, complete: Bool = false, safeTop: CGFloat = 0) -> CGRect {
        let width = min(520, max(1, screen.width - 32))
        let contentHeight: CGFloat
        if complete { contentHeight = 290 }
        else {
            switch step {
            case .permissions: contentHeight = 455
            case .face: contentHeight = 690
            case .password: contentHeight = 425
            case .finish: contentHeight = 465
            }
        }
        let height = min(contentHeight + safeTop, max(1, screen.height - 24))
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }
}

private final class SetupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct NotchSetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var setup: SetupFlowModel
    @ObservedObject private var enrollment: EnrollmentModel
    let safeTop: CGFloat
    let onClose: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, safeTop: CGFloat, onClose: @escaping () -> Void) {
        self.model = model; self.safeTop = safeTop; self.onClose = onClose
        preferences = model.preferences; setup = model.setup; enrollment = model.enrollment
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(8, safeTop + 4))
            HStack {
                Label("Face Unlock", systemImage: "faceid").font(.system(size: 12, weight: .medium))
                if AppEdition.isAdmin {
                    Text("ADMIN").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(setup.isComplete ? "Done" : "Later", action: onClose)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .disabled(setup.isBusy || enrollment.isBusy || enrollment.canSave)
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 26).padding(.vertical, 12)
            ScrollView { SetupFlowView(model: model, onDone: onClose) }
        }
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 32, bottomTrailingRadius: 32))
        .preferredColorScheme(.dark)
        .tint(.white)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : -12)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { appeared = true } }
    }
}
