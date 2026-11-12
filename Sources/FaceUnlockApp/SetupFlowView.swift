import AppKit
import AVFoundation
import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

struct SetupFlowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var setup: SetupFlowModel
    @ObservedObject private var enrollment: EnrollmentModel
    @ObservedObject private var vault: CredentialVault
    @ObservedObject private var lockScreen: LockScreenFlowModel
    @State private var password = ""
    @State private var requestingCamera = false

    init(model: AppModel) {
        self.model = model
        setup = model.setup; enrollment = model.enrollment
        vault = model.vault; lockScreen = model.lockScreen
    }

    var body: some View {
        VStack(spacing: 24) {
            if lockScreen.automaticUnlockEnabled {
                enabled
            } else {
                progress
                switch setup.step {
                case .permissions: permissions
                case .face:
                    EnrollmentView(model: enrollment, onContinue: setup.continueFace)
                case .password: passwordEntry
                case .finish: finish
                }
                if !setup.status.isEmpty {
                    Text(setup.status).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                        .accessibilityIdentifier("setupFeedback")
                }
                if setup.isBusy { ProgressView().controlSize(.small) }
                if setup.step != .permissions && !setup.isBusy && !enrollment.isBusy && !enrollment.canSave {
                    Button("Back", action: setup.back).buttonStyle(.link)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .task(id: setup.step) {
            guard setup.step == .permissions else { return }
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: setup.step) { _, _ in password = "" }
        .onChange(of: lockScreen.automaticUnlockEnabled) { _, enabled in
            if !enabled { setup.unlockStopped() }
        }
        .onDisappear { password = "" }
    }

    private var progress: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(step == setup.step ? Color.accentColor : Color.secondary.opacity(0.12))
                        if step.rawValue < setup.step.rawValue {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .foregroundStyle(step == setup.step ? Color.white : Color.secondary)
                        }
                    }.frame(width: 30, height: 30)
                    Text(step.title).font(.caption.weight(step == setup.step ? .semibold : .regular))
                }.frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(setup.step.rawValue + 1) of 4: \(setup.step.title)")
    }

    private var permissions: some View {
        VStack(spacing: 24) {
            heading("Allow two permissions", subtitle: "Camera recognizes your face. Accessibility enters your password on the lock screen.", symbol: "hand.raised")
            VStack(spacing: 16) {
                permissionRow("Camera", detail: "Face scans stay on this Mac.", symbol: "camera",
                              granted: cameraAllowed) {
                    requestingCamera = true
                    Task {
                        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                        } else { openSettings("Privacy_Camera") }
                        requestingCamera = false; model.refresh()
                    }
                }
                Divider()
                permissionRow("Accessibility", detail: "Allows one password submission after a face match.", symbol: "accessibility",
                              granted: accessibilityAllowed) {
                    model.manualTest.requestAccessibility()
                    openSettings("Privacy_Accessibility")
                    model.refresh()
                }
            }.padding(20).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            Button("Continue", action: setup.continuePermissions)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!cameraAllowed || !accessibilityAllowed || requestingCamera)
        }.padding(.vertical, 24)
    }

    private var passwordEntry: some View {
        VStack(spacing: 22) {
            heading("Enter your Mac password", subtitle: "Use the password you normally type to unlock this account.", symbol: "key")
            SecureField("Mac login password", text: $password)
                .textContentType(.password).textFieldStyle(.roundedBorder)
                .controlSize(.large).frame(maxWidth: 360)
                .accessibilityIdentifier("setupPassword")
                .disabled(setup.isBusy)
                .onSubmit { savePassword() }
            Text("Your password is encrypted and stored on this Mac. macOS will ask you to authorize saving it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Save password and continue", action: savePassword)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(password.isEmpty || setup.isBusy)
            if vault.hasCredential {
                Button("Use saved password", action: setup.useSavedPassword).disabled(setup.isBusy)
            }
        }.padding(.vertical, 36)
    }

    private var finish: some View {
        VStack(spacing: 22) {
            heading("Ready to finish", subtitle: "Enable face unlock, then lock your Mac normally and look at the camera.", symbol: "faceid")
            VStack(alignment: .leading, spacing: 12) {
                Label("Permissions granted", systemImage: "checkmark.circle.fill")
                Label("Face registered", systemImage: "checkmark.circle.fill")
                Label("Password saved", systemImage: "checkmark.circle.fill")
            }.foregroundStyle(.secondary)
            Text("This experimental webcam unlock can be fooled by a photo or video. Password and Touch ID remain available.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Toggle("I understand that a photo or video may unlock this Mac", isOn: $setup.acknowledgesPhotoRisk)
                .toggleStyle(.checkbox).font(.callout).disabled(setup.isBusy)
            Button("Finish setup", action: setup.finish)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!setup.acknowledgesPhotoRisk || setup.isBusy)
            if lockScreen.failure != nil {
                Text(lockScreen.status).font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            Text("Confirm the macOS authorization dialogs to enable unlocking while this app is open.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 28)
    }

    private var enabled: some View {
        VStack(spacing: 22) {
            heading("Face unlock is on", subtitle: "Lock your Mac and look at the camera. Keep Face Unlock open.", symbol: "checkmark.circle")
            if let failure = lockScreen.failure, failure != .scanOnly && failure != .canceled {
                Label(failure.caption, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Text(lockScreen.status).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
            }
            Text("Your password is entered once after a match. Password and Touch ID are always available.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Turn off face unlock", action: setup.turnOff).controlSize(.large)
            Text("After quitting or restarting the app, finish setup again to authorize face unlock. Your face and encrypted password stay saved.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }.padding(.vertical, 60)
    }

    private var cameraAllowed: Bool { model.report.status(for: .cameraPermission) == .available }
    private var accessibilityAllowed: Bool { model.report.status(for: .accessibilityPermission) == .available }

    private func savePassword() {
        guard !password.isEmpty, !setup.isBusy else { return }
        var bytes = Data(password.utf8)
        password = ""
        setup.savePassword(bytes)
        bytes.resetBytes(in: 0..<bytes.count)
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func heading(_ title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 56, weight: .light)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 27, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
    }

    private func permissionRow(_ title: String, detail: String, symbol: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("Allow…", action: action).disabled(requestingCamera) }
        }
    }
}
