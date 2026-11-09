import SwiftUI
import FaceUnlockMac

struct CredentialTestView: View {
    @ObservedObject var vault: CredentialVault
    @ObservedObject var controller: ManualUnlockController
    @State private var password = ""
    @State private var actionStatus = ""
    @State private var confirmDelete = false
    @State private var consentToSubmit = false
    @State private var probeCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credential session").font(.headline)
            Text("Authenticate with macOS to authorize a 90-second session. The development key is in your login Keychain; the password is stored as AES-GCM ciphertext.")
                .font(.callout)
            HStack {
                Button("Authorize session…") {
                    Task {
                        do { try await vault.authorize(); actionStatus = "Session authorized" }
                        catch { actionStatus = error.localizedDescription }
                    }
                }
                .disabled(vault.isBusy || controller.isArmed)
                Button("Revoke / cancel") { controller.cancel(); password = "" }
            }
            SecureField("Your Mac login password", text: $password)
                .textContentType(.password)
                .disabled(!vault.isAuthorized || controller.isArmed || vault.isBusy)
            HStack {
                Button(vault.hasCredential ? "Replace encrypted password" : "Save encrypted password") {
                    var bytes = Data(password.utf8)
                    password = ""
                    defer { bytes.resetBytes(in: 0..<bytes.count) }
                    do { try vault.save(bytes); actionStatus = "Saved. Password correctness is not yet verified." }
                    catch { actionStatus = error.localizedDescription }
                }
                .disabled(password.isEmpty || !vault.isAuthorized || vault.isBusy || controller.isArmed)
                Button("Delete stored password…") { confirmDelete = true }
                    .disabled(vault.isBusy || controller.isArmed)
            }
            Text(vault.status).font(.callout)
            if !actionStatus.isEmpty { Text(actionStatus).font(.callout).textSelection(.enabled) }

            Divider()
            Text("Manual lock-screen test").font(.headline)
            Text("Arm a test, lock your Mac normally, and leave the password field focused. Each test expires after 60 seconds. No retries or startup automation are installed.")
                .font(.callout)
            HStack {
                Button("Accessibility setup…") { controller.requestAccessibility() }
                Button("Camera permission…") { Task { await controller.requestCamera() } }
                Button("Inspect current focus") { controller.inspectFocus() }
            }
            .disabled(controller.isArmed)
            Toggle("Check one camera frame while locked (discarded immediately)", isOn: $probeCamera)
                .disabled(controller.isArmed)
            Button("Arm observation-only test") { controller.arm(submitPassword: false, probeCamera: probeCamera) }
                .disabled(controller.isArmed || vault.isBusy)
            Toggle("Allow this manual test to enter my saved Mac password once", isOn: $consentToSubmit)
                .disabled(controller.isArmed)
            HStack {
                Button("Arm one password submission") {
                    controller.arm(submitPassword: true, probeCamera: probeCamera)
                    consentToSubmit = false
                }
                .disabled(!consentToSubmit || !vault.isAuthorized || !vault.hasCredential || controller.isArmed || vault.isBusy)
                Button("Cancel test") { controller.cancel() }.disabled(!controller.isArmed)
            }
            Text(controller.status).font(.callout).textSelection(.enabled)
            if controller.canConfirmDesktop {
                Text("Report whether you returned without typing your password or using Touch ID. Submission alone is not a confirmed unlock.").font(.callout)
                HStack {
                    Button("Desktop reached without fallback") { controller.confirmDesktop(noManualUnlock: true) }
                    Button("Password / Touch ID fallback needed") { controller.confirmDesktop(noManualUnlock: false) }
                }
            }
            DisclosureGroup("Test report (contains no password)") {
                Text(controller.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .confirmationDialog("Delete the encrypted password and its key?", isPresented: $confirmDelete) {
            Button("Delete stored password", role: .destructive) {
                password = ""
                Task {
                    do { try await vault.delete(); actionStatus = "Credential removed" }
                    catch { actionStatus = error.localizedDescription }
                }
            }
        }
        .onChange(of: vault.isAuthorized) { _, authorized in if !authorized { password = "" } }
        .onDisappear { password = "" }
    }
}
