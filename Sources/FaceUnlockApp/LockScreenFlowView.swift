import SwiftUI

/// Optional diagnostics; the primary setup flow owns password entry and unlock enablement.
struct LockScreenFlowView: View {
    @ObservedObject var model: LockScreenFlowModel
    let indicator: LockScreenIndicator
    let hasEnrollment: Bool
    let otherWorkActive: Bool
    let onCredentialSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lock-screen diagnostics").font(.title2.weight(.semibold))
            Text("Use the four-step setup to enable face unlock. Scan-only mode checks recognition without entering a password.")
                .font(.callout).foregroundStyle(.secondary)
            Label(model.automaticUnlockEnabled ? "Face unlock is on" : model.automaticScanningEnabled ? "Scan only is on" : "Automatic scanning is off",
                  systemImage: model.automaticUnlockEnabled ? "lock.open" : "viewfinder")
            Text(model.status).font(.callout).textSelection(.enabled)
                .accessibilityIdentifier("lockScreenFeedback")
            if let failure = model.failure {
                Label(failure.caption, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                if model.automaticScanningEnabled {
                    Button("Turn off", action: { model.disableAutomaticScanning() })
                } else if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: { model.cancel() })
                } else {
                    Button("Scan only on every lock", action: model.enableAutomaticScanning)
                        .disabled(!hasEnrollment || otherWorkActive)
                    Button("Preview indicator", action: indicator.preview).disabled(otherWorkActive)
                }
            }.controlSize(.large)
            if !model.automaticScanningEnabled && !model.isBusy {
                Button("Return to setup", action: onCredentialSetup)
            }
            Text("A yellow lock in scan-only mode means no password was entered. A failed unlock shows the reason below the lock icon.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.events.isEmpty {
                DisclosureGroup("Recent events") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption)
                        }
                    }.padding(.top, 8).textSelection(.enabled)
                }
            }
            Text("The last attempt's stage, error category and frame counts are saved locally. No images, face scores or passwords are included in that report.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }
}
