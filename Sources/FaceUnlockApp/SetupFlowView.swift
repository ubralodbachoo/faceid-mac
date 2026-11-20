import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

/// Guided onboarding appears only in the interactive notch panel.
struct SetupFlowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var setup: SetupFlowModel
    @ObservedObject private var enrollment: EnrollmentModel
    @ObservedObject private var vault: CredentialVault
    @ObservedObject private var lockScreen: LockScreenFlowModel
    @ObservedObject private var preferences: AppPreferences
    @State private var password = ""
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appAnimationsEnabled) private var animations
    private var reduceMotion: Bool { systemReduceMotion || !animations }
    let onDone: () -> Void

    init(model: AppModel, onDone: @escaping () -> Void = {}) {
        self.model = model; self.onDone = onDone
        setup = model.setup; enrollment = model.enrollment
        vault = model.vault; lockScreen = model.lockScreen; preferences = model.preferences
    }

    var body: some View {
        VStack(spacing: 22) {
            if setup.isComplete && lockScreen.automaticUnlockEnabled {
                complete
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                if setup.step != .face { progress }
                Group {
                    switch setup.step {
                    case .permissions: permissions
                    case .face: FaceRegistrationView(model: enrollment, preferences: preferences, onContinue: setup.continueFace, onClose: onDone)
                    case .password: passwordEntry
                    case .finish: finish
                    }
                }
                .id(setup.step)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                if !setup.status.isEmpty {
                    Text(setup.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                        .accessibilityIdentifier("setupFeedback")
                }
                if setup.isBusy { ProgressView().controlSize(.small) }
                if setup.step != .permissions && setup.step != .face && !setup.isBusy && !enrollment.isBusy && !enrollment.canSave {
                    Button("Back", action: setup.back).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 26).padding(.top, 15).padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: setup.step)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: setup.isComplete)
        .onChange(of: setup.step) { _, _ in password = "" }
        .onChange(of: lockScreen.automaticUnlockEnabled) { _, enabled in
            if !enabled { setup.unlockStopped() }
        }
        .onDisappear { password = "" }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d / 04", setup.step.rawValue + 1))
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
            Spacer()
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Capsule().fill(step.rawValue <= setup.step.rawValue ? Color.white.opacity(0.8) : .white.opacity(0.14))
                    .frame(width: step == setup.step ? 22 : 5, height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(setup.step.rawValue + 1) of 4: \(setup.step.title)")
    }

    private var permissions: some View {
        VStack(spacing: 22) {
            heading("A little access. All local.", subtitle: "Two permissions, then we’ll get to know your face.", symbol: "hand.raised")
            PermissionSettingsView(model: model)
            Button("Continue", action: setup.continuePermissions)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.report.status(for: .cameraPermission) != .available ||
                          model.report.status(for: .accessibilityPermission) != .available)
        }
    }

    private var passwordEntry: some View {
        VStack(spacing: 22) {
            heading("Your Mac password", subtitle: "The one you use to unlock this account.", symbol: "key.horizontal")
            SecureField("Mac login password", text: $password)
                .textContentType(.password).textFieldStyle(.roundedBorder)
                .controlSize(.large).frame(maxWidth: 330)
                .accessibilityIdentifier("setupPassword")
                .disabled(setup.isBusy).onSubmit(savePassword)
            Text("Encrypted and saved on this Mac. Confirm with macOS to continue.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Save and continue", action: savePassword)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(password.isEmpty || setup.isBusy)
            if vault.hasCredential {
                Button("Use saved password", action: setup.useSavedPassword)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary).disabled(setup.isBusy)
            }
        }.padding(.vertical, 6)
    }

    private var finish: some View {
        VStack(spacing: 20) {
            heading("One last thing.", subtitle: "Your face and password are ready.", symbol: "faceid")
            HStack(spacing: 18) {
                Label("Permissions", systemImage: "checkmark")
                Label("Face", systemImage: "checkmark")
                Label("Password", systemImage: "checkmark")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Face Unlock uses your camera and passive liveness checks. These experimental checks can still be fooled by photos or video. Password and Touch ID remain available.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Toggle("I understand a photo or video may unlock this Mac", isOn: $setup.acknowledgesPhotoRisk)
                .toggleStyle(.checkbox).font(.system(size: 12)).disabled(setup.isBusy)
            Button("Finish setup", action: setup.finish)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!setup.acknowledgesPhotoRisk || setup.isBusy)
            Text("Confirm with macOS to enable Face Unlock.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var complete: some View {
        VStack(spacing: 17) {
            Image(systemName: "checkmark.circle").font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(preferences.accent.color)
            Text("You’re all set.").font(.system(size: 25, weight: .semibold))
            Text("Lock your Mac and look at the camera.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Open System Settings", action: onDone)
                .buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(.vertical, 15)
    }

    private func savePassword() {
        guard !password.isEmpty, !setup.isBusy else { return }
        var bytes = Data(password.utf8)
        password = ""
        setup.savePassword(bytes)
        bytes.resetBytes(in: 0..<bytes.count)
    }

    private func heading(_ title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 31, weight: .ultraLight)).foregroundStyle(preferences.accent.color)
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 5)
    }
}
