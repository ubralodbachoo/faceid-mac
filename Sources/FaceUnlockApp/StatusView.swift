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
    @State private var page = SettingsPage.overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSetup: () -> Void

    init(model: AppModel, onSetup: @escaping () -> Void) {
        self.model = model; self.onSetup = onSetup
        preferences = model.preferences; setup = model.setup
        lockScreen = model.lockScreen; enrollment = model.enrollment
        passwordSettings = model.passwordSettings
    }

    private var workActive: Bool {
        setup.isBusy || enrollment.isBusy || enrollment.canSave || lockScreen.isBusy || passwordSettings.isBusy ||
        model.faceTest.isBusy || model.manualTest.isArmed || model.vault.isBusy || model.recognition.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "faceid").font(.system(size: 20, weight: .light))
                Text("Face Unlock").font(.system(size: 14, weight: .semibold))
                Spacer()
                #if !FACEUNLOCK_CUSTOMER
                Text("ADMIN").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary)
                AdminToolsButton(model: model)
                #endif
            }.padding(.horizontal, 32).padding(.vertical, 21)
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if page != .overview {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.title).font(.system(size: 29, weight: .semibold))
                            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                    pageContent
                }.padding(.horizontal, 40).padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page)
            .transition(.opacity)
            SettingsDock(selection: $page).padding(.top, 12).padding(.bottom, 23)
        }
        .frame(width: 760, height: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .overview: overview
        case .permissions:
            PermissionSettingsView(model: model)
            Label("Camera images stay on this Mac. No microphone is used.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        case .faces:
            EnrollmentView(model: enrollment, compact: true, settingsMode: true, beforeCapture: {
                model.lockScreen.disableAutomaticScanning()
            })
            .disabled(passwordSettings.isBusy || setup.isBusy || lockScreen.isBusy)
            .onDisappear { if enrollment.isBusy || enrollment.canSave { enrollment.cancel() } }
        case .password: PasswordSettingsView(model: passwordSettings, vault: model.vault,
                                             otherWorkActive: enrollment.isBusy || enrollment.canSave || setup.isBusy || lockScreen.isBusy)
        case .appearance: AppearanceSettingsView(preferences: preferences, indicator: model.lockIndicator, previewDisabled: workActive)
        }
    }

    private var subtitle: String {
        switch page {
        case .overview: ""
        case .permissions: "Manage the access Face Unlock needs."
        case .faces: "Register your face or add another appearance."
        case .password: "Keep your saved Mac login password up to date."
        case .appearance: "Make the notch feel like yours."
        }
    }

    private var overview: some View {
        VStack(spacing: 22) {
            FaceIDAnimationFrame(stage: .scanning, motionTime: 1, stageTime: 0,
                                 reduceMotion: true, accent: preferences.accent.color)
                .frame(width: 112, height: 112)
                .background(.black, in: RoundedRectangle(cornerRadius: 30))
                .padding(.top, 12)
            VStack(spacing: 8) {
                Text(lockScreen.automaticUnlockEnabled ? "A glance. You’re in." : "Your Mac, at a glance.")
                    .font(.system(size: 30, weight: .semibold))
                Text(lockScreen.automaticUnlockEnabled ? "Face Unlock is on. Lock your Mac and look at the camera." : "Face Unlock is off for this session.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if preferences.setupCompleted {
                Button(lockScreen.automaticUnlockEnabled ? "Turn off Face Unlock" : "Enable Face Unlock") {
                    if lockScreen.automaticUnlockEnabled { setup.turnOff() }
                    else { setup.enableSavedSetup() }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(workActive)
            } else {
                Button("Continue setup in the notch", action: onSetup)
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(workActive)
            }
            if setup.isBusy { ProgressView().controlSize(.small) }
            if !setup.status.isEmpty {
                Text(setup.status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let failure = lockScreen.failure, failure != .canceled, failure != .scanOnly {
                Text(lockScreen.status).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                summary("Permissions", detail: permissionsReady ? "Allowed" : "Needs attention", symbol: "hand.raised", page: .permissions)
                summary("Faces", detail: enrollment.hasEnrollment ? "Registered" : "Not registered", symbol: "faceid", page: .faces)
                summary("Password", detail: model.vault.hasCredential ? "Saved securely" : "Not saved", symbol: "key.horizontal", page: .password)
            }.padding(.top, 8)
            #if !FACEUNLOCK_CUSTOMER
            Button("Replay setup in notch", action: onSetup).buttonStyle(.link).disabled(workActive)
            #endif
            Text("Keep Face Unlock running in the menu bar. After reopening the app, enable it again and confirm with macOS.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }.frame(maxWidth: .infinity)
    }

    private var permissionsReady: Bool {
        model.report.status(for: .cameraPermission) == .available && model.report.status(for: .accessibilityPermission) == .available
    }

    private func summary(_ title: String, detail: String, symbol: String, page: SettingsPage) -> some View {
        Button { self.page = page } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light))
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
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
