import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

struct StatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var enrollment: EnrollmentModel
    @State private var showsDiagnostics = false

    init(model: AppModel) {
        self.model = model
        self.enrollment = model.enrollment
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("Face Unlock", systemImage: "faceid").font(.headline)
                Spacer()
                Picker("View", selection: $showsDiagnostics) {
                    Text("Face setup").tag(false)
                    Text("Developer tools").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .disabled(enrollment.isBusy || enrollment.canSave)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            ScrollView {
                if showsDiagnostics { diagnostics }
                else { EnrollmentView(model: enrollment) }
            }
        }
        .frame(width: 640, height: 780)
        .onDisappear { enrollment.cancel() }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Developer tools").font(.title2.weight(.semibold))
            Text("Model diagnostics and manual password tests are separate from face registration.")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                ForEach(Component.allCases, id: \.self) { component in
                    GridRow {
                        Text(component.title)
                        Text(model.report.status(for: component).rawValue)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            RecognitionTestView(model: model.recognition)
            Divider()
            CredentialTestView(vault: model.vault, controller: model.manualTest)
            Divider()
            SessionStatusView(monitor: model.sessionMonitor)
            Button("Refresh status", action: model.refresh)
        }
        .padding(24)
    }
}

private struct SessionStatusView: View {
    @ObservedObject var monitor: FaceUnlockMac.MacSessionMonitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("Session observations").font(.headline)
                Text("App UID: \(monitor.snapshot.processUserID) · Console UID: \(uid(monitor.snapshot.consoleUserID)) · Session UID: \(uid(monitor.snapshot.sessionUserID))")
                Text("On console: \(flag(monitor.snapshot.isOnConsole)) · Login complete: \(flag(monitor.snapshot.loginComplete))")
                Text("Screen: \(monitor.snapshot.screenLock.rawValue)")
                Text(monitor.snapshot.assessment(at: ProcessInfo.processInfo.systemUptime).rawValue)
                Text("Last event: \(monitor.lastEvent)")
                Text("Lock flag is undocumented. These observations cannot authorize password entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !monitor.recentChanges.isEmpty {
                    Text("Recent changes (memory only)").font(.subheadline)
                    ForEach(monitor.recentChanges.prefix(3)) { change in
                        HStack(alignment: .top) {
                            Text(change.recordedAt, style: .time).monospacedDigit()
                            Text(change.summary)
                        }
                        .font(.caption)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private func uid(_ value: UInt32?) -> String { value.map(String.init) ?? "Unknown" }
    private func flag(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? "Unknown" }
}
