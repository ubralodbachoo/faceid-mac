import SwiftUI
import FaceUnlockMac
import FaceUnlockCore

struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            trailing
        }.font(.system(size: 13)).padding(.horizontal, 16).frame(minHeight: 48)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.horizontal, 16) }
}

struct FacesSettingsView: View {
    @ObservedObject var model: EnrollmentModel
    @ObservedObject var preferences: AppPreferences
    var otherWorkActive: Bool
    var beforeCapture: () -> Void
    @State private var captureOpen = false
    @State private var removing: RegisteredFace?
    @State private var renaming: RegisteredFace?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Registered faces").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.prepareCapture(addingFace: model.hasEnrollment); captureOpen = true
                } label: { Image(systemName: "plus").font(.system(size: 16, weight: .medium)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).accessibilityLabel("Add face")
                    .disabled(busy || (model.savedFaceCount ?? 0) >= 3)
            }.padding(.horizontal, 6)
            if !model.hasEnrollment {
                SettingsCard {
                    SettingsRow("No registered faces") { Text("Use + to add").foregroundStyle(.secondary) }
                }
            } else if model.registeredFaces.isEmpty {
                SettingsCard {
                    SettingsRow("Saved faces") { Button("Show names", action: model.inspectSaved).disabled(busy) }
                }
            } else {
                ForEach(model.registeredFaces) { face in
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Button {
                                    newName = face.name; renaming = face
                                } label: {
                                    Text(face.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        .padding(.horizontal, 11).padding(.vertical, 6)
                                        .background(.white.opacity(0.1), in: Capsule())
                                }.buttonStyle(.plain).help("Rename face")
                                Spacer()
                                Toggle("Enable \(face.name)", isOn: Binding(get: { face.isEnabled }, set: { model.setFaceEnabled(at: face.id, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            HStack {
                                Text(face.isEnabled ? "Enabled" : "Disabled").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Recapture") {
                                    model.prepareCapture(replacingFace: face.id); captureOpen = true
                                }.controlSize(.small)
                                Button { removing = face } label: { Image(systemName: "trash").frame(width: 22, height: 22) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(face.name)")
                            }
                        }.padding(14)
                    }.disabled(busy)
                }
            }
            if model.isBusy && !captureOpen { ProgressView().controlSize(.small) }
            if model.phase == .failed { Text(model.status).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Encrypted on this Mac · Up to 3 faces").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        .sheet(isPresented: $captureOpen) {
            FaceRegistrationView(model: model, preferences: preferences, beforeCapture: beforeCapture, onClose: { captureOpen = false })
                .frame(width: 340).fixedSize(horizontal: false, vertical: true)
                .preferredColorScheme(.dark)
                .interactiveDismissDisabled(model.isBusy || model.canSave)
        }
        .sheet(item: $renaming) { face in
            VStack(alignment: .leading, spacing: 18) {
                Text("Face name").font(.headline)
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).disabled(model.isBusy)
                HStack {
                    Button("Cancel") { renaming = nil }.disabled(model.isBusy)
                    Spacer()
                    Button("Save") { model.renameFace(at: face.id, to: newName); renaming = nil }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy || (try? EnrollmentTemplate.validateName(newName)) == nil)
                }
            }.padding(24).frame(width: 300).preferredColorScheme(.dark)
        }
        .confirmationDialog("Remove \(removing?.name ?? "face")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove face", role: .destructive) {
                if let removing { model.removeFace(at: removing.id) }
                removing = nil
            }
        }
        .onChange(of: model.phase) { _, phase in if phase == .saved { captureOpen = false } }
    }

    private var busy: Bool { otherWorkActive || model.isBusy || model.canSave }
}

struct PasswordSettingsView: View {
    @ObservedObject var model: PasswordSettingsModel
    @ObservedObject var vault: CredentialVault
    var otherWorkActive: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow("Mac password") {
                    Text(vault.hasCredential ? "Saved" : "Not saved").foregroundStyle(.secondary)
                }
                SettingsDivider()
                VStack(alignment: .leading, spacing: 14) {
                    SecureField("Mac login password", text: $password)
                        .textContentType(.password).textFieldStyle(.roundedBorder).controlSize(.large)
                        .accessibilityIdentifier("settingsPassword")
                        .disabled(model.isBusy || otherWorkActive).onSubmit(save)
                    HStack {
                        Spacer()
                        Button(vault.hasCredential ? "Update password" : "Save password", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(password.isEmpty || model.isBusy || otherWorkActive)
                    }
                }.padding(16)
            }
            if model.isBusy { ProgressView().controlSize(.small) }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Encrypted on this Mac. Confirm with macOS.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        .help("Updates Face Unlock’s saved copy of your Mac login password.")
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

struct ColorSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    let indicator: LockScreenIndicator
    var previewDisabled: Bool

    var body: some View {
        SettingsCard {
            SettingsRow("Face ID color") { Text(preferences.accent.title).foregroundStyle(.secondary) }
            SettingsDivider()
            HStack(spacing: 13) {
                ForEach(FaceIDAccent.allCases) { accent in
                    Button { preferences.accent = accent } label: {
                        ZStack {
                            Circle().fill(accent.color).frame(width: 24, height: 24)
                            if preferences.accent == accent {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            }
                        }.frame(width: 30, height: 30)
                            .overlay(Circle().stroke(preferences.accent == accent ? .white.opacity(0.65) : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).help(accent.title).accessibilityLabel(accent.title)
                        .accessibilityAddTraits(preferences.accent == accent ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Button("Preview") { indicator.preview() }.controlSize(.small).disabled(previewDisabled)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}
