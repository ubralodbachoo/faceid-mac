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

/// No key window, pointer interception, activation, video view, or password-field replacement.
@MainActor
final class LockScreenIndicator: NSObject {
    private var panel: IndicatorPanel?
    private var dismissal: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var visiblePhase = LockScreenPhase.idle
    private var visibleCaption: String?
    private var delegated = false

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

    func preview() {
        show(.scanning)
        dismiss(after: 3)
    }

    private func update(_ phase: LockScreenPhase, caption: String?) {
        switch phase {
        case .scanning, .submitting, .awaitingDesktop: show(phase)
        case .unlocked:
            show(phase); dismiss(after: 1.4)
        case .fallback:
            // Desktop preflight errors must not create an unsolicited lock-screen overlay.
            if panel?.isVisible == true { show(phase, caption: caption); dismiss(after: 4) }
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
        panel.setFrame(frame, display: false)
        panel.contentView = NSHostingView(rootView: LockScreenIndicatorView(phase: phase, safeTop: screen.safeAreaInsets.top, width: frame.width, failureCaption: caption))
        panel.orderFrontRegardless()
        if MacSessionReader().read().assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked {
            if !delegated { delegated = LockScreenWindowBridge.shared?.attach(panel) == true }
        } else if delegated {
            LockScreenWindowBridge.shared?.detach(panel); delegated = false
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        dismissal?.cancel(); dismissal = nil
        if delegated, let panel { LockScreenWindowBridge.shared?.detach(panel); delegated = false }
        panel?.orderOut(nil); visiblePhase = .idle; visibleCaption = nil
    }

    private func dismiss(after seconds: Double) {
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.hide()
        }
    }

    @objc private func reposition() {
        guard panel?.isVisible == true else { return }
        let phase = visiblePhase
        show(phase, caption: visibleCaption)
        if phase == .fallback || phase == .unlocked { dismiss(after: phase == .fallback ? 4 : 1.4) }
    }
}

private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct LockScreenIndicatorView: View {
    let phase: LockScreenPhase
    let safeTop: CGFloat
    let width: CGFloat
    let failureCaption: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanning = false

    private var symbol: String {
        switch phase {
        case .unlocked: "checkmark.circle"
        case .fallback: "lock.circle"
        case .submitting, .awaitingDesktop: "lock.open"
        default: "faceid"
        }
    }

    private var label: String {
        switch phase {
        case .unlocked: "Desktop observed"
        case .fallback: failureCaption ?? "Use password or Touch ID"
        case .submitting: "Submitting password"
        case .awaitingDesktop: "Waiting for the desktop"
        default: "Looking for your face"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, safeTop))
            VStack(spacing: 8) {
              ZStack {
                Image(systemName: symbol)
                    .font(.system(size: phase == .fallback ? 60 : min(width * 0.52, 84), weight: .light))
                    .foregroundStyle(phase == .fallback ? Color.orange : Color(red: 0.25, green: 0.62, blue: 1))
                    .opacity(phase == .scanning && !reduceMotion && scanning ? 0.55 : 1)
                if phase == .scanning {
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.25, green: 0.62, blue: 1).opacity(0.5))
                        .frame(width: min(width * 0.52, 84), height: 2)
                        .offset(y: reduceMotion ? 0 : (scanning ? 38 : -38))
                }
              }
              if phase == .fallback, let failureCaption {
                  Text(failureCaption).font(.system(size: 11, weight: .medium))
                      .foregroundStyle(.orange).multilineTextAlignment(.center)
                      .lineLimit(2).padding(.horizontal, 12)
              }
            }
            .frame(height: LockScreenIndicatorGeometry.height(width: width, safeTop: safeTop) - max(0, safeTop))
        }
        .frame(width: width, height: LockScreenIndicatorGeometry.height(width: width, safeTop: safeTop))
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: min(width * 0.22, 44), bottomTrailingRadius: min(width * 0.22, 44)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .onAppear {
            guard phase == .scanning, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { scanning = true }
        }
    }
}
