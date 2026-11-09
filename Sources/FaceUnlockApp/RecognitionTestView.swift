import SwiftUI

struct RecognitionTestView: View {
    @ObservedObject var model: RecognitionTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ArcFace model diagnostics").font(.headline)
            Text("Glance’s w600k_mbf model · 112×112 RGB · 512-number descriptor · local Core ML")
                .font(.callout)
            HStack {
                Button("Run model self-test") { model.runSelfTest() }.disabled(model.isBusy)
                Button("Analyze local image…") { model.chooseImage() }.disabled(model.isBusy || !model.isValidated)
                if model.isBusy { Button("Cancel") { model.cancel() } }
            }
            Text(model.status).font(.callout).textSelection(.enabled)
            Text("No face enrollment or liveness verification yet. These diagnostics cannot enter your password.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Research weights: commercial distribution rights remain unresolved.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.report.isEmpty {
                DisclosureGroup("Model report (synthetic inputs only)") {
                    Text(model.report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}
