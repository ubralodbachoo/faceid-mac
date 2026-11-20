import SwiftUI
import FaceUnlockMac

struct PasswordSettingsView: View {
    @ObservedObject var model: PasswordSettingsModel
    @ObservedObject var vault: CredentialVault
    var otherWorkActive: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(vault.hasCredential ? "A password is saved on this Mac" : "No password saved yet",
                  systemImage: vault.hasCredential ? "lock.shield" : "key.horizontal")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Text("Mac login password").font(.system(size: 12, weight: .medium))
                SecureField("Enter your current password", text: $password)
                    .textContentType(.password).textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityIdentifier("settingsPassword")
                    .disabled(model.isBusy || otherWorkActive)
                    .onSubmit(save)
                Text("Update this whenever you change your Mac login password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(vault.hasCredential ? "Update saved password" : "Save password", action: save)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(password.isEmpty || model.isBusy || otherWorkActive)
            if model.isBusy { ProgressView().controlSize(.small) }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            Label("Encrypted and stored locally. macOS asks you to confirm before saving.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            Text("This updates Face Unlock’s saved copy. Your Mac login password is managed by macOS.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
        .onDisappear { password = ""; if model.isBusy { model.cancel() } }
    }

    private func save() {
        guard !password.isEmpty, !model.isBusy, !otherWorkActive else { return }
        var bytes = Data(password.utf8)
        password = ""
        model.save(bytes)
        bytes.resetBytes(in: 0..<bytes.count)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let indicator: LockScreenIndicator
    var previewDisabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
                FaceIDAnimationFrame(stage: .scanning, motionTime: context.date.timeIntervalSinceReferenceDate,
                                     stageTime: 0, reduceMotion: reduceMotion, accent: preferences.accent.color)
                    .frame(width: 140, height: 140)
                    .padding(18)
                    .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 38, bottomTrailingRadius: 38))
            }
            Text(preferences.accent.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 22) {
                ForEach(FaceIDAccent.allCases) { accent in
                    Button { preferences.accent = accent } label: {
                        ZStack {
                            Circle().fill(accent.color).frame(width: 32, height: 32)
                            if preferences.accent == accent {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.black)
                            }
                        }.frame(width: 44, height: 44)
                            .overlay(Circle().stroke(preferences.accent == accent ? Color.primary.opacity(0.65) : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).help(accent.title).accessibilityLabel(accent.title)
                        .accessibilityAddTraits(preferences.accent == accent ? .isSelected : [])
                }
            }
            Button("Preview on notch") { indicator.preview() }
                .controlSize(.large).disabled(previewDisabled)
            Text("Your color applies to the Face ID animation and is saved automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 18)
    }
}
