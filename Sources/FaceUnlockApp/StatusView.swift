import SwiftUI
import FaceUnlockCore

struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Face Unlock development skeleton")
                .font(.headline)
            Text("Unlocking is inactive. This build only reads setup status.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                ForEach(Component.allCases, id: \.self) { component in
                    GridRow {
                        Text(component.title)
                        Text(model.report.status(for: component).rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("\(model.report.blockers.count) setup requirements remaining")
                .font(.callout)
            Button("Refresh status", action: model.refresh)
        }
        .padding(24)
        .frame(width: 540)
    }
}
