import SwiftUI
import FaceUnlockCore
import FaceUnlockMac

struct StatusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var enrollment: EnrollmentModel
    @ObservedObject private var faceTest: FaceTestModel
    @ObservedObject private var lockScreen: LockScreenFlowModel
    private enum Tool: String, Identifiable {
        case faceTest, lockScreen, diagnostics
        var id: String { rawValue }
    }
    @State private var tool: Tool?

    init(model: AppModel) {
        self.model = model
        self.enrollment = model.enrollment
        self.faceTest = model.faceTest
        self.lockScreen = model.lockScreen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Face Unlock", systemImage: "faceid").font(.headline)
                Spacer()
                Menu {
                    Button("Test my face") { tool = .faceTest }
                    Button("Lock-screen diagnostics") { tool = .lockScreen }
                    Button("Developer tools") { tool = .diagnostics }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Tools")
                .disabled(enrollment.isBusy || enrollment.canSave || faceTest.isBusy || lockScreen.isBusy || model.setup.isBusy)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView { SetupFlowView(model: model) }
        }
        .frame(width: 680, height: 780)
        .sheet(item: $tool) { selected in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { tool = nil }
                        .disabled(enrollment.isBusy || faceTest.isBusy || lockScreen.isBusy || model.vault.isBusy || model.manualTest.isArmed || model.recognition.isBusy)
                }.padding(16)
                Divider()
                ScrollView {
                    switch selected {
                    case .faceTest:
                        FaceTestView(model: faceTest, hasEnrollment: enrollment.hasEnrollment)
                            .disabled(lockScreen.automaticScanningEnabled)
                        if lockScreen.automaticScanningEnabled {
                            Text("Turn off face unlock before running a camera test.")
                                .font(.callout).padding()
                        }
                    case .lockScreen:
                        LockScreenFlowView(model: lockScreen, indicator: model.lockIndicator,
                            hasEnrollment: enrollment.hasEnrollment,
                            otherWorkActive: enrollment.isBusy || enrollment.canSave || faceTest.isBusy || model.manualTest.isArmed || model.vault.isBusy,
                            onCredentialSetup: { tool = nil })
                    case .diagnostics:
                        diagnostics.disabled(lockScreen.automaticScanningEnabled)
                    }
                }
            }
            .frame(width: 720, height: 740)
            .interactiveDismissDisabled(faceTest.isBusy || lockScreen.isBusy || model.vault.isBusy || model.manualTest.isArmed || model.recognition.isBusy)
        }
        .onDisappear { enrollment.cancel(); faceTest.cancel() }
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
