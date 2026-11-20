import SwiftUI
import FaceUnlockCore

/// One registration design for both the notch and the application's capture sheet.
struct FaceRegistrationView: View {
    @ObservedObject var model: EnrollmentModel
    @ObservedObject var preferences: AppPreferences
    var onContinue: (() -> Void)? = nil
    var beforeCapture: () -> Void = {}
    var onClose: () -> Void
    @State private var replacing = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button {
                    if model.isBusy || model.canSave { model.cancel() }
                    onClose()
                } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close registration")
            }
            CameraGuideView(model: model)
                .scaleEffect(0.75).frame(width: 240, height: 240)
            Text(instruction).font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 34)
                .accessibilityIdentifier("registrationInstruction")
            actions
            if model.phase == .review && !model.status.isEmpty && model.status != "Your scan is complete. Save your face to finish." {
                Text(model.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .accentColor(preferences.accent.color)
        .confirmationDialog("Replace all saved faces?", isPresented: $replacing, titleVisibility: .visible) {
            Button("Register again", role: .destructive) { beforeCapture(); model.start() }
        } message: { Text("Use + in Faces to keep existing registrations.") }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .capturing: EmptyView()
        case .review:
            TextField("Face name", text: $model.faceName)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 230)
                .accessibilityIdentifier("enrollmentName").onSubmit(save)
            Button("Save face", action: save).buttonStyle(.borderedProminent)
                .disabled(!model.canSave || (try? EnrollmentTemplate.validateName(model.faceName)) == nil)
        case .paused:
            Button("Continue scan", action: model.resume).buttonStyle(.borderedProminent)
        case .authorizing, .preparing, .cameraPermission, .validating, .deleting:
            ProgressView().controlSize(.small)
        case .saved:
            Button(onContinue == nil ? "Done" : "Continue") {
                if let onContinue { onContinue() } else { onClose() }
            }.buttonStyle(.borderedProminent)
            if onContinue != nil {
                Button("Register again") { replacing = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .idle, .failed:
            Button(model.phase == .failed ? "Try again" : "Start scan") {
                if onContinue != nil && model.hasEnrollment { replacing = true }
                else {
                    beforeCapture()
                    if onContinue != nil { model.start() } else { model.retryCapture() }
                }
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("startFaceSetup")
            if model.hasEnrollment, let onContinue {
                Button("Use saved face", action: onContinue).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var instruction: String {
        switch model.phase {
        case .capturing:
            model.detectedFaceBounds == nil ? model.status : model.currentPose.title
        case .review: "Name your face"
        case .paused: "Scan paused"
        case .authorizing: "Confirm with macOS"
        case .preparing: "Preparing camera"
        case .cameraPermission: "Allow camera access"
        case .failed: model.status
        case .saved: "Face registered"
        case .validating: "Checking saved faces"
        case .deleting: "Removing face"
        case .idle: "Look toward the camera"
        }
    }

    private func save() {
        guard !model.isBusy, model.canSave else { return }
        model.save()
        if model.phase == .saved { onContinue?() }
    }
}
