import SwiftUI
import FaceUnlockCore

struct FaceTestView: View {
    @ObservedObject var model: FaceTestModel
    let hasEnrollment: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text("Compare the camera with the face you registered.")
                .font(.callout).foregroundStyle(.secondary)

            ZStack {
                Circle().fill(Color(red: 0.085, green: 0.095, blue: 0.11))
                if model.phase == .capturing, let session = model.previewSession {
                    CameraPreviewView(session: session).clipShape(Circle())
                } else if model.phase == .capturing, let image = model.previewImage {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: 270, height: 270).scaleEffect(x: -1, y: 1).clipShape(Circle())
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 58, weight: .ultraLight))
                        Text("Camera off").font(.caption)
                    }.foregroundStyle(.white.opacity(0.7))
                }
                Circle().strokeBorder(resultColor.opacity(0.8), lineWidth: 3)
            }
            .frame(width: 270, height: 270)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.phase == .capturing ? "Live mirrored camera for face comparison" : "Camera is off")

            if model.phase == .capturing {
                ProgressView(value: Double(model.sampleCount), total: Double(FaceComparisonPolicy.requiredFrames))
                    .frame(width: 270)
                Text("\(model.sampleCount) of \(FaceComparisonPolicy.requiredFrames) usable frames · \(model.secondsRemaining)s remaining")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(hasEnrollment ? model.status : "Register your face in Face setup before running a test.")
                .multilineTextAlignment(.center).font(.callout)
                .frame(maxWidth: 480, minHeight: 38)
                .accessibilityIdentifier("faceTestFeedback")

            if let result = model.result {
                VStack(spacing: 6) {
                    Text("Similarity \(result.medianSimilarity, specifier: "%.3f")")
                        .font(.title3.monospacedDigit())
                    Text("Experimental cutoff: 0.500 · This score is not a probability.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Face comparison only · Liveness unverified")
                        .font(.callout).foregroundStyle(.orange)
                    DisclosureGroup("Comparison details") {
                        Text("\(result.frameCount) frames, each compared with the three closest saved samples. \(result.aboveCutoff) of \(result.frameCount) were at or above the cutoff. Scores ranged from \(result.minimumSimilarity, specifier: "%.3f") to \(result.maximumSimilarity, specifier: "%.3f"). Median analysis: \(model.analysisMilliseconds ?? 0, specifier: "%.0f") ms per frame.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        Text("Model preparation: \(model.preparationMilliseconds ?? 0, specifier: "%.0f") ms · Camera startup: \(model.cameraStartupMilliseconds ?? 0, specifier: "%.0f") ms · Camera test: \((model.scanMilliseconds ?? 0) / 1000, specifier: "%.2f") s. Touch ID time is excluded.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    .frame(maxWidth: 440)
                }
                .textSelection(.enabled)
            } else if let score = model.latestSimilarity {
                Text("Live similarity \(score, specifier: "%.3f")")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }

            if let summary = model.acquisitionSummary, model.phase == .failed {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 470)
            }
            if let average = model.averageCameraMilliseconds {
                Text("Average camera test: \(average / 1000, specifier: "%.2f")s · \(model.completedCameraTimes.count) completed · \(model.failedCameraTests) failed")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.failedCameraTests > 0 {
                Text("No completed camera comparisons · \(model.failedCameraTests) failed")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if model.isBusy {
                    if model.phase != .capturing { ProgressView().controlSize(.small) }
                    Button("Cancel test", action: model.cancel)
                } else {
                    if model.cameraSettingsNeeded { Button("Open camera settings", action: model.openCameraSettings) }
                    Button(model.phase == .idle ? "Test my face" : "Test again", action: model.start)
                        .buttonStyle(.borderedProminent).disabled(!hasEnrollment)
                        .keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large)

            VStack(spacing: 6) {
                Text("Experimental recognition test. This does not unlock your Mac.")
                Text("The comparison finishes when 12 usable frames are collected. Scans stop after 15s if incomplete.")
                Text("Liveness is unverified. A photo or video may also match.")
                Text("Processed on this Mac. Images and test scores are not saved.")
            }
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
    }

    private var title: String {
        switch model.phase {
        case .idle: "Test your face"
        case .authorizing: "Open your saved face"
        case .preparing: "Preparing the test"
        case .capturing: "Look toward the camera"
        case .failed: "Test did not complete"
        case .finished:
            switch model.result?.outcome {
            case .similar: "Face looks similar"
            case .different: "Face looks different"
            default: "Could not decide"
            }
        }
    }

    private var resultColor: Color {
        switch model.result?.outcome {
        case .similar: .accentColor
        case .different, .inconclusive: .orange
        case nil: .accentColor
        }
    }

    private var symbol: String {
        switch model.result?.outcome {
        case .similar: "person.crop.circle"
        case .different: "person.crop.circle.badge.xmark"
        case .inconclusive: "questionmark.circle"
        case nil: "person.crop.circle"
        }
    }
}
