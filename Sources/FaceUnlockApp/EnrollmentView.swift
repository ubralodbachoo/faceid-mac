import SwiftUI
import FaceUnlockCore

struct EnrollmentView: View {
    @ObservedObject var model: EnrollmentModel
    var onTestFace: () -> Void = {}
    var onContinue: (() -> Void)? = nil
    var compact = false
    var settingsMode = false
    var beforeCapture: () -> Void = {}
    @State private var confirmingReplacement = false
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: settingsMode ? 10 : 14) {
            VStack(spacing: 7) {
                Text(title).font(.system(size: settingsMode ? 20 : 26, weight: .semibold))
                if !settingsMode {
                    Text(subtitle)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470, minHeight: 34)
                }
            }

            CameraGuideView(model: model)
                .scaleEffect(settingsMode ? 0.5625 : compact ? 0.75 : 1)
                .frame(width: settingsMode ? 180 : compact ? 240 : 320,
                       height: settingsMode ? 180 : compact ? 240 : 320)

            if model.phase == .capturing || model.phase == .paused || model.phase == .review {
                Text("\(model.completedPoses) of 9 angles ready")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("\(model.completedPoses) of 9 face angles captured")
            } else if onContinue == nil && !settingsMode {
                HStack(spacing: 12) {
                    Label("Confirm", systemImage: "lock")
                    Image(systemName: "chevron.right").font(.system(size: 9))
                    Label("Scan", systemImage: "viewfinder")
                    Image(systemName: "chevron.right").font(.system(size: 9))
                    Label("Save", systemImage: "checkmark.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Text(model.status)
                .font(settingsMode ? .caption : .callout)
                .foregroundStyle(model.phase == .failed ? Color.orange : Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 490, minHeight: settingsMode ? 24 : 38)
                .textSelection(.enabled)
                .accessibilityIdentifier("enrollmentFeedback")

            actions
                .controlSize(settingsMode ? .regular : .large)
                .frame(minHeight: settingsMode ? 28 : 38)

            if settingsMode {
                Text("Camera images are never saved.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    Label("Processed on this Mac. Camera images are never saved.", systemImage: "lock.shield")
                    Text(model.phase == .capturing || model.phase == .paused || model.phase == .review
                         ? "Switching apps pauses the camera. \(remainingTime) remaining to finish."
                        : onContinue != nil ? "Save your face, then continue to your Mac password."
                        : "Try Face test to compare your face, or finish setup to enable face unlock.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, settingsMode ? 8 : 28)
        .padding(.vertical, settingsMode ? 6 : 18)
        .frame(maxWidth: .infinity)
        .confirmationDialog("Replace your saved faces?", isPresented: $confirmingReplacement, titleVisibility: .visible) {
            Button("Register again", role: .destructive) { beforeCapture(); model.start() }
        } message: {
            Text("Saving a new scan replaces all registered faces. Use Add face to keep them.")
        }
        .confirmationDialog("Remove all saved faces?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove saved face", role: .destructive, action: model.delete)
        } message: {
            Text("macOS will ask you to confirm. You can register again later.")
        }
    }

    @ViewBuilder private var actions: some View {
        if model.phase == .review {
            HStack(spacing: 12) {
                Button("Cancel", action: model.cancel)
                Button(onContinue == nil ? "Save face" : "Save face and continue") {
                    model.save()
                    if model.phase == .saved { onContinue?() }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || !model.canSave)
            }
        } else if model.phase == .paused {
            HStack(spacing: 12) {
                Button(settingsMode ? "Cancel scan" : "Cancel setup", action: model.cancel)
                Button("Continue scan", action: model.resume)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        } else if model.isBusy {
            HStack(spacing: 12) {
                if model.phase.isPreparing { ProgressView().controlSize(.small) }
                Button(settingsMode ? "Cancel scan" : "Cancel setup", action: model.cancel)
            }
        } else if model.hasEnrollment {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Register again") { confirmingReplacement = true }
                    if settingsMode {
                        Button("Add face") { beforeCapture(); model.startAddingFace() }
                            .buttonStyle(.borderedProminent)
                            .disabled((model.savedFaceCount ?? 0) >= 3)
                    } else if let onContinue {
                        Button("Continue", action: onContinue).buttonStyle(.borderedProminent)
                    } else {
                        #if !FACEUNLOCK_CUSTOMER
                        Button("Test my face", action: onTestFace).buttonStyle(.borderedProminent)
                        #endif
                    }
                }
                DisclosureGroup("Manage saved face") {
                    #if !FACEUNLOCK_CUSTOMER
                    Button("Check saved data", action: model.inspectSaved).buttonStyle(.link).font(.caption)
                    #endif
                    Button("Remove all saved faces…", role: .destructive) { confirmingRemoval = true }
                        .buttonStyle(.link).font(.caption)
                }.fixedSize().font(.caption)
            }
        } else {
            HStack(spacing: 12) {
                if model.cameraSettingsNeeded {
                    Button("Open camera settings", action: model.openCameraSettings)
                }
                Button(model.phase == .failed ? "Try again" : settingsMode ? "Register face" : "Start face setup") {
                    beforeCapture()
                    if settingsMode && model.isAddingFace { model.startAddingFace() } else { model.start() }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("startFaceSetup")
                #if !FACEUNLOCK_CUSTOMER
                if model.hasEnrollment {
                    Button("Check saved data", action: model.inspectSaved)
                }
                #endif
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: model.hasEnrollment ? "Your saved face" : "Register your face"
        case .authorizing: "First, confirm it’s you"
        case .preparing: "Getting things ready"
        case .cameraPermission: "Allow camera access"
        case .capturing: model.currentPose.title
        case .paused: "Scan paused"
        case .review: "Ready to save"
        case .saved: "Your face is registered"
        case .validating: "Checking your saved face"
        case .deleting: "Removing your saved face"
        case .failed: "Let’s try that again"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle:
            model.hasEnrollment
                ? "Your face is saved on this Mac. Add another appearance or register again."
                : "A short, continuous scan. Gently follow the head-turn guide."
        case .authorizing: "Use the secure macOS dialog to authorize face setup."
        case .preparing: "The camera will open after everything is ready."
        case .cameraPermission: "Your camera is used only for this local setup. No microphone is needed."
        case .capturing: "Move gently toward the highlighted part of the ring, then hold for a moment."
        case .paused: "Your camera is off. Return to this window and continue where you left off."
        case .review: "The camera is off. Save to finish, or cancel to discard this scan."
        case .saved: "Your face template is encrypted and stored only on this Mac."
        case .validating: "Confirm with macOS to check your stored face data. This does not scan your face."
        case .deleting: "Confirm removal in the secure macOS dialog."
        case .failed: "Follow the message below, then start setup again."
        }
    }

    private var remainingTime: String {
        String(format: "%d:%02d", model.secondsRemaining / 60, model.secondsRemaining % 60)
    }
}

struct CameraGuideView: View {
    @ObservedObject var model: EnrollmentModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.appAnimationsEnabled) private var animations
    private var reduceMotion: Bool { systemReduceMotion || !animations }

    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.085, green: 0.095, blue: 0.11)).frame(width: 254, height: 254)
            if model.phase == .capturing, let session = model.previewSession {
                CameraPreviewView(session: session)
                    .frame(width: 250, height: 250).clipShape(Circle())
            } else if model.phase == .capturing, let image = model.previewImage {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: 250, height: 250).scaleEffect(x: -1, y: 1).clipShape(Circle())
            } else if model.phase == .saved || model.phase == .review {
                Image(systemName: "checkmark").font(.system(size: 58, weight: .light)).foregroundStyle(.mint)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "person.crop.circle").font(.system(size: 60, weight: .ultraLight))
                    if model.phase.isPreparing { ProgressView().tint(.white).controlSize(.small) }
                    else { Text("Camera off").font(.caption) }
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            ForEach(0..<64) { tick in
                Capsule().fill(tickColor(tick))
                    .frame(width: 2.5, height: 12)
                    .offset(y: -148)
                    .rotationEffect(.degrees(Double(tick) * 360 / 64))
            }

        }
        .frame(width: 320, height: 320)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.holdProgress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.phase == .capturing ? "Live mirrored camera preview with a direction progress ring" : "Camera preview is off")
        .accessibilityValue("\(model.completedPoses) of 9 angles captured. \(model.phase == .capturing ? model.currentPose.title : "")")
    }

    private func tickColor(_ tick: Int) -> Color {
        if model.phase == .saved || model.phase == .review { return .mint }
        guard model.phase == .capturing || model.phase == .paused else { return .white.opacity(0.75) }
        if model.currentPose == .center && model.completedPoses == 0 {
            return .accentColor.opacity(0.2 + model.holdProgress * 0.35)
        }
        let angle = Double(tick) * 360 / 64
        let directions = EnrollmentPose.allCases.filter { $0 != .center }
        guard let pose = directions.min(by: { distance(angle, $0.compassAngle!) < distance(angle, $1.compassAngle!) }) else { return .white.opacity(0.75) }
        if pose.rawValue < model.completedPoses { return .accentColor }
        if pose == model.currentPose {
            let start = pose.compassAngle! - 22.5
            let sectorProgress = (angle - start + 360).truncatingRemainder(dividingBy: 360) / 45
            return sectorProgress < model.holdProgress ? .accentColor : .accentColor.opacity(0.3)
        }
        return .white.opacity(0.75)
    }

    private func distance(_ first: Double, _ second: Double) -> Double {
        let difference = abs(first - second)
        return min(difference, 360 - difference)
    }
}
