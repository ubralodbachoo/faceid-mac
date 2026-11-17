import AppKit
import Combine
import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

enum LockScreenIndicatorGeometry {
    static func height(width: CGFloat, safeTop: CGFloat) -> CGFloat {
        max(max(0, safeTop) + 104, width * 0.95)
    }

    static func frame(screen: CGRect, safeTop: CGFloat,
                      leftArea: CGRect? = nil, rightArea: CGRect? = nil) -> CGRect {
        let top = max(0, safeTop)
        var width = min(180, screen.width)
        var center = screen.midX
        if top > 0, let leftArea, let rightArea,
           leftArea.width > 0, rightArea.width > 0,
           leftArea.maxX >= screen.minX, rightArea.minX <= screen.maxX,
           rightArea.minX > leftArea.maxX {
            width = rightArea.minX - leftArea.maxX
            center = (rightArea.minX + leftArea.maxX) / 2
        }
        let height = height(width: width, safeTop: top)
        return CGRect(x: center - width / 2, y: screen.maxY - height, width: width, height: height)
    }
}

struct LockScreenIndicatorDiagnostics: Codable, Sendable {
    var attachmentAttempts = 0
    var attachmentSucceeded = false
    var bridgeAvailable = false
    var bridgeInitializationFailure: String?
    var windowAttachmentFailure: String?
}

/// Refresh after ordering: AppKit ordering/space transitions may undo earlier delegation.
@MainActor
struct LockScreenOverlayDelivery {
    private(set) var delegated = false
    mutating func refresh(locked: Bool, orderFront: () -> Void, attach: () -> Bool, detach: () -> Void) {
        orderFront()
        if locked { delegated = attach() || delegated }
        else if delegated { detach(); delegated = false; orderFront() }
    }
    mutating func hide(detach: () -> Void, orderOut: () -> Void) {
        if delegated { detach(); delegated = false }
        orderOut()
    }
}

/// No key window, pointer interception, activation, video view, or password-field replacement.
@MainActor
final class LockScreenIndicator: NSObject {
    private var panel: IndicatorPanel?
    private var dismissal: Task<Void, Never>?
    private var previewSequence: Task<Void, Never>?
    private let presentation = LockScreenIndicatorPresentation()
    private var observation: AnyCancellable?
    private var visiblePhase = LockScreenPhase.idle
    private var visibleCaption: String?
    private var delivery = LockScreenOverlayDelivery()
    private var visibilityRefresh: Task<Void, Never>?
    private(set) var diagnostics = LockScreenIndicatorDiagnostics()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func observe(_ model: LockScreenFlowModel) {
        observation = model.$phase.sink { [weak self, weak model] phase in
            self?.update(phase, caption: model?.failure?.caption)
        }
    }

    func prepareForLockScreen() { LockScreenWindowBridge.prepare() }

    func preview() {
        hide()
        show(.scanning)
        previewSequence = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2.2))
                self?.show(.waitingForPasswordField)
                try await Task.sleep(for: .seconds(1.6))
                self?.show(.unlocked)
                try await Task.sleep(for: .seconds(1.05))
                self?.dismiss(after: 0)
            } catch { return }
        }
    }

    private func update(_ phase: LockScreenPhase, caption: String?) {
        previewSequence?.cancel(); previewSequence = nil
        switch phase {
        case .scanning, .waitingForPasswordField, .submitting, .awaitingDesktop:
            if phase == .scanning && visiblePhase != .scanning { diagnostics = LockScreenIndicatorDiagnostics() }
            show(phase)
        case .unlocked:
            show(phase); dismiss(after: 1.05)
        case .fallback:
            // Desktop preflight errors must not create an unsolicited lock-screen overlay.
            if panel?.isVisible == true { show(phase, caption: caption); dismiss(after: 1) }
        default: hide()
        }
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func show(_ phase: LockScreenPhase, caption: String? = nil) {
        dismissal?.cancel(); dismissal = nil
        guard let screen = preferredScreen else { return }
        visiblePhase = phase
        visibleCaption = caption
        let frame = LockScreenIndicatorGeometry.frame(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
            leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        let panel: IndicatorPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = IndicatorPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.title = "Face Unlock indicator"
            self.panel = panel
        }
        presentation.update(phase: phase, safeTop: screen.safeAreaInsets.top,
                            width: frame.width, failureCaption: caption)
        panel.setFrame(frame, display: false)
        // Preserve one hosting view and animation clock across processing sub-stages.
        if !(panel.contentView is NSHostingView<LockScreenIndicatorView>) {
            let hosting = NSHostingView(rootView: LockScreenIndicatorView(presentation: presentation))
            // The view already reserves the physical notch height. AppKit's automatic
            // safe-area inset would add it a second time and separate the black surfaces.
            hosting.safeAreaRegions = []
            panel.contentView = hosting
        }
        // Lay out/composite before moving into the lock-screen space.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        refreshVisibility()
        if visibilityRefresh == nil {
            visibilityRefresh = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self else { return }
                    self.refreshVisibility()
                }
            }
        }
    }

    private func refreshVisibility() {
        guard let panel, visiblePhase != .idle else { return }
        let locked = MacSessionReader().read().assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked
        delivery.refresh(locked: locked, orderFront: { panel.orderFrontRegardless() }, attach: {
            diagnostics.attachmentAttempts += 1
            let bridge = LockScreenWindowBridge.shared
            diagnostics.bridgeAvailable = bridge != nil
            diagnostics.bridgeInitializationFailure = LockScreenWindowBridge.initializationFailure
            let attached = bridge?.attach(panel) == true
            diagnostics.windowAttachmentFailure = bridge?.lastAttachmentFailure
            diagnostics.attachmentSucceeded = diagnostics.attachmentSucceeded || attached
            return attached
        }, detach: { LockScreenWindowBridge.shared?.detach(panel) })
    }

    func hide() {
        previewSequence?.cancel(); previewSequence = nil
        presentation.reset()
        dismissal?.cancel(); dismissal = nil
        visibilityRefresh?.cancel(); visibilityRefresh = nil
        if let panel {
            delivery.hide(detach: { LockScreenWindowBridge.shared?.detach(panel) }, orderOut: { panel.orderOut(nil) })
        }
        visiblePhase = .idle; visibleCaption = nil
    }

    private func dismiss(after seconds: Double) {
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.presentation.collapse()
            do { try await Task.sleep(for: .milliseconds(340)) } catch { return }
            self?.hide()
        }
    }

    @objc private func reposition() {
        guard panel?.isVisible == true else { return }
        let phase = visiblePhase
        show(phase, caption: visibleCaption)
        if phase == .fallback || phase == .unlocked { dismiss(after: phase == .fallback ? 1 : 1.05) }
    }
}

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One clock per visible attempt; field preparation/submission never restart the sphere.
@MainActor
final class LockScreenIndicatorPresentation: ObservableObject {
    @Published private(set) var phase = LockScreenPhase.idle
    @Published private(set) var collapsing = false
    private(set) var safeTop: CGFloat = 0
    private(set) var width: CGFloat = 180
    private(set) var failureCaption: String?
    private(set) var startedAt: TimeInterval = 0
    private(set) var stageBeganAt: TimeInterval = 0

    func update(phase: LockScreenPhase, safeTop: CGFloat, width: CGFloat,
                failureCaption: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        collapsing = false
        if self.phase == .idle { startedAt = now; stageBeganAt = now }
        if FaceIDAnimationStage(phase) != FaceIDAnimationStage(self.phase) { stageBeganAt = now }
        self.safeTop = safeTop; self.width = width; self.failureCaption = failureCaption
        self.phase = phase
    }

    func collapse() { collapsing = true }
    func reset() { phase = .idle; collapsing = false }
}

private struct LockScreenIndicatorView: View {
    @ObservedObject var presentation: LockScreenIndicatorPresentation
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: LockScreenPhase { presentation.phase }
    private var retryableFailure: Bool {
        presentation.failureCaption == LockScreenFailure.identity.caption ||
        presentation.failureCaption == LockScreenFailure.timeout.caption
    }
    private var label: String {
        switch phase {
        case .unlocked: "Unlocked"
        case .fallback: retryableFailure ? "Try again" : "Failed. \(presentation.failureCaption ?? "Use password or Touch ID")"
        case .waitingForPasswordField, .submitting, .awaitingDesktop: "Processing"
        default: "Scanning for your face"
        }
    }

    var body: some View {
        let width = presentation.width
        let safeTop = max(0, presentation.safeTop)
        let height = LockScreenIndicatorGeometry.height(width: width, safeTop: safeTop)
        VStack(spacing: 0) {
            Color.clear.frame(height: safeTop)
            // Procedural vector frames: no upsampled video or repeating scan-line asset.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || phase == .idle)) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                let stage = FaceIDAnimationStage(phase)
                let motionTime = (stage == .unlocked ? presentation.stageBeganAt : now) - presentation.startedAt
                FaceIDAnimationFrame(stage: stage, motionTime: motionTime,
                    stageTime: now - presentation.stageBeganAt, reduceMotion: reduceMotion)
                    .frame(width: min(width * 0.67, 136), height: min(width * 0.67, 136))
                    .frame(width: width, height: height - safeTop)
            }
        }
        .frame(width: width, height: height)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: min(width * 0.22, 44),
                                                      bottomTrailingRadius: min(width * 0.22, 44)))
        .mask(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: min(width * 0.22, 44),
                                   bottomTrailingRadius: min(width * 0.22, 44))
                .frame(height: expanded && !presentation.collapsing ? height : max(24, safeTop))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.34), value: expanded)
        .animation(reduceMotion ? nil : .smooth(duration: 0.34), value: presentation.collapsing)
        .ignoresSafeArea()
        .onAppear { expanded = true }
        .onChange(of: phase) { _, phase in expanded = phase != .idle }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
