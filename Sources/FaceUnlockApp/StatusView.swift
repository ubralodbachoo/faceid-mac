import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

struct StatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var setup: SetupFlowModel
    @ObservedObject private var lockScreen: LockScreenFlowModel
    @ObservedObject private var enrollment: EnrollmentModel
    @ObservedObject private var passwordSettings: PasswordSettingsModel
    @State private var page = SettingsPage.general
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSetup: () -> Void

    init(model: AppModel, onSetup: @escaping () -> Void) {
        self.model = model; self.onSetup = onSetup
        preferences = model.preferences; setup = model.setup
        lockScreen = model.lockScreen; enrollment = model.enrollment
        passwordSettings = model.passwordSettings
    }

    private var motionReduced: Bool { reduceMotion || !preferences.animations }

    private var workActive: Bool {
        setup.isBusy || enrollment.isBusy || enrollment.canSave || lockScreen.isBusy || passwordSettings.isBusy ||
        model.faceTest.isBusy || model.manualTest.isArmed || model.vault.isBusy || model.recognition.isBusy
    }

    var body: some View {
        ZStack {
            Color.black
            if preferences.lightRays { LightRaysBackground().allowsHitTesting(false).accessibilityHidden(true) }
            LinearGradient(colors: [.black.opacity(0.28), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    ScrollView {
                        pageContent
                            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(page)
                    .transition(motionReduced ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
                .animation(motionReduced ? nil : .easeInOut(duration: 0.28), value: page)
                SettingsDock(selection: $page).padding(.top, 8).padding(.bottom, 14)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || motionReduced ? 0 : 10)
        }
        .frame(width: 520, height: 520)
        .clipped()
        .preferredColorScheme(.dark)
        .environment(\.appAnimationsEnabled, preferences.animations)
        .tint(preferences.accent == .white ? .blue : preferences.accent.color)
        .onAppear { withAnimation(motionReduced ? nil : .easeOut(duration: 0.35)) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: general
        case .faces:
            FacesSettingsView(model: enrollment, preferences: preferences, otherWorkActive: passwordSettings.isBusy || setup.isBusy || lockScreen.isBusy,
                              beforeCapture: { model.lockScreen.disableAutomaticScanning() })
                .onDisappear { if enrollment.isBusy || enrollment.canSave { enrollment.cancel() } }
        case .password:
            PasswordSettingsView(model: passwordSettings, vault: model.vault,
                                 otherWorkActive: enrollment.isBusy || enrollment.canSave || setup.isBusy || lockScreen.isBusy)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                SettingsRow("Enable Face Unlock") {
                    Toggle("Enable Face Unlock", isOn: Binding(get: { lockScreen.automaticUnlockEnabled }, set: { enabled in
                        if enabled { setup.enableSavedSetup() } else { setup.turnOff() }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(workActive || !preferences.setupCompleted)
                }
                if !preferences.setupCompleted {
                    SettingsDivider()
                    SettingsRow("Setup") {
                        Button("Open notch", action: onSetup).disabled(workActive)
                    }
                }
            }
            if setup.isBusy { ProgressView().controlSize(.small) }
            if !setup.status.isEmpty && setup.status != "Face unlock is off." {
                Text(setup.status).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.horizontal, 4)
            }
            if let failure = lockScreen.failure, failure != .canceled, failure != .scanOnly {
                Text(lockScreen.status).font(.caption).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 12)
                PermissionSettingsView(model: model, compact: true)
            }
            ColorSettingsView(preferences: preferences, indicator: model.lockIndicator, previewDisabled: workActive)
            SettingsCard {
                preferenceToggle("Light rays", isOn: $preferences.lightRays)
                SettingsDivider()
                preferenceToggle("Animations", isOn: $preferences.animations)
                SettingsDivider()
                preferenceToggle("Haptic feedback", isOn: $preferences.hapticFeedback)
            }
            #if !FACEUNLOCK_CUSTOMER
            VStack(alignment: .leading, spacing: 8) {
                Text("Admin").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 12)
                SettingsCard {
                    SettingsRow("Replay setup") { Button("Open notch", action: onSetup).disabled(workActive) }
                    SettingsDivider()
                    SettingsRow("Developer tools") { AdminToolsButton(model: model) }
                }
            }
            #endif
        }
        .font(.system(size: 13))
    }
    private func preferenceToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        SettingsRow(title) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

}

#if !FACEUNLOCK_CUSTOMER
private struct AdminToolsButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var enrollment: EnrollmentModel
    @ObservedObject private var faceTest: FaceTestModel
    @ObservedObject private var lockScreen: LockScreenFlowModel
    private enum Tool: String, Identifiable {
        case faceTest, lockScreen, diagnostics
        var id: String { rawValue }
    }
    @State private var tool: Tool?

    init(model: AppModel) {
        self.model = model; enrollment = model.enrollment
        faceTest = model.faceTest; lockScreen = model.lockScreen
    }

    var body: some View {
        Menu {
            Button("Test my face") { tool = .faceTest }
            Button("Lock-screen diagnostics") { tool = .lockScreen }
            Button("Developer tools") { tool = .diagnostics }
        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Admin tools")
        .disabled(enrollment.isBusy || enrollment.canSave || faceTest.isBusy || lockScreen.isBusy || model.setup.isBusy)
        .sheet(item: $tool) { selected in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { tool = nil }
                        .disabled(enrollment.isBusy || faceTest.isBusy || lockScreen.isBusy || model.vault.isBusy || model.manualTest.isArmed || model.recognition.isBusy)
                }.padding(16)
                Divider()
                ScrollView {
                    switch selected {
                    case .faceTest:
                        FaceTestView(model: faceTest, hasEnrollment: enrollment.hasEnrollment)
                            .disabled(lockScreen.automaticScanningEnabled)
                        if lockScreen.automaticScanningEnabled {
                            Text("Turn off face unlock before running a camera test.").font(.callout).padding()
                        }
                    case .lockScreen:
                        LockScreenFlowView(model: lockScreen, indicator: model.lockIndicator,
                            hasEnrollment: enrollment.hasEnrollment,
                            otherWorkActive: enrollment.isBusy || enrollment.canSave || faceTest.isBusy || model.manualTest.isArmed || model.vault.isBusy,
                            onCredentialSetup: { tool = nil })
                    case .diagnostics: diagnostics.disabled(lockScreen.automaticScanningEnabled)
                    }
                }
            }.frame(width: 720, height: 740)
            .interactiveDismissDisabled(enrollment.isBusy || enrollment.canSave || faceTest.isBusy || lockScreen.isBusy || model.vault.isBusy || model.manualTest.isArmed || model.recognition.isBusy)
        }
        .onDisappear { faceTest.cancel() }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Developer tools").font(.title2.weight(.semibold))
            Text("Model diagnostics and manual password tests are separate from face registration.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                ForEach(Component.allCases, id: \.self) { component in
                    GridRow {
                        Text(component.title)
                        Text(model.report.status(for: component).rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            RecognitionTestView(model: model.recognition)
            Divider()
            CredentialTestView(vault: model.vault, controller: model.manualTest)
            Divider()
            SessionStatusView(monitor: model.sessionMonitor)
            Button("Refresh status", action: model.refresh)
        }
        .padding(24)
    }
}

private struct SessionStatusView: View {
    @ObservedObject var monitor: FaceUnlockMac.MacSessionMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("Session observations").font(.headline)
                Text("App UID: \(monitor.snapshot.processUserID) · Console UID: \(uid(monitor.snapshot.consoleUserID)) · Session UID: \(uid(monitor.snapshot.sessionUserID))")
                Text("On console: \(flag(monitor.snapshot.isOnConsole)) · Login complete: \(flag(monitor.snapshot.loginComplete))")
                Text("Screen: \(monitor.snapshot.screenLock.rawValue)")
                Text(monitor.snapshot.assessment(at: ProcessInfo.processInfo.systemUptime).rawValue)
                Text("Last event: \(monitor.lastEvent)")
                Text("Lock flag is undocumented. These observations cannot authorize password entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !monitor.recentChanges.isEmpty {
                    Text("Recent changes (memory only)").font(.subheadline)
                    ForEach(monitor.recentChanges.prefix(3)) { change in
                        HStack(alignment: .top) {
                            Text(change.recordedAt, style: .time).monospacedDigit()
                            Text(change.summary)
                        }
                        .font(.caption)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private func uid(_ value: UInt32?) -> String { value.map(String.init) ?? "Unknown" }
    private func flag(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Unknown" }
}

#endif
