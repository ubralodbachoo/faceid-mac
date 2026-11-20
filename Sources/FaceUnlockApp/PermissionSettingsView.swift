import AppKit
import AVFoundation
import SwiftUI
import FaceUnlockCore

struct PermissionSettingsView: View {
    @ObservedObject var model: AppModel
    var compact = false
    @State private var requestingCamera = false

    var body: some View {
        VStack(spacing: 0) {
            permission("Camera", detail: "Recognize your face on this Mac.", symbol: "camera",
                       allowed: cameraAllowed) {
                requestingCamera = true
                Task {
                    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                    } else { openSettings("Privacy_Camera") }
                    requestingCamera = false; model.refresh()
                }
            }
            Divider().padding(.leading, compact ? 0 : 58)
            permission("Accessibility", detail: "Enter your saved password after a match.", symbol: "accessibility",
                       allowed: accessibilityAllowed) {
                if !accessibilityAllowed { model.manualTest.requestAccessibility() }
                openSettings("Privacy_Accessibility")
                model.refresh()
            }
        }
        .padding(.horizontal, 18)
        .background(.white.opacity(compact ? 0.055 : 0.035), in: RoundedRectangle(cornerRadius: compact ? 18 : 20))
        .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 20).stroke(.white.opacity(compact ? 0.08 : 0), lineWidth: 1))
        .task {
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var cameraAllowed: Bool { model.report.status(for: .cameraPermission) == .available }
    private var accessibilityAllowed: Bool { model.report.status(for: .accessibilityPermission) == .available }

    private func permission(_ title: String, detail: String, symbol: String, allowed: Bool,
                            action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            if !compact { Image(systemName: symbol).font(.system(size: 22, weight: .light)).frame(width: 30) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 13, weight: compact ? .regular : .semibold))
                    if allowed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                }
                if !compact { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            Button(allowed ? "Settings…" : "Allow…", action: action)
                .disabled(requestingCamera)
                .accessibilityLabel("\(allowed ? "Manage" : "Allow") \(title)")
        }.padding(.vertical, compact ? 13 : 19)
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
