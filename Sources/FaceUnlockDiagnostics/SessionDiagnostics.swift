import Foundation
import FaceUnlockCore
import FaceUnlockMac

/// One-shot, read-only inspection for development. Does not lock or unlock the computer.
@main
struct SessionDiagnostics {
    @MainActor
    static func main() {
        let snapshot = MacSessionReader().read()
        print("Process UID: \(snapshot.processUserID)")
        print("Console UID: \(snapshot.consoleUserID.map(String.init) ?? "Unknown")")
        print("Session UID: \(snapshot.sessionUserID.map(String.init) ?? "Unknown")")
        print("On console: \(snapshot.isOnConsole.map(String.init) ?? "Unknown")")
        print("Login complete: \(snapshot.loginComplete.map(String.init) ?? "Unknown")")
        print("Screen: \(snapshot.screenLock.rawValue)")
        print("Assessment: \(snapshot.assessment(at: ProcessInfo.processInfo.systemUptime).rawValue)")
        print("Diagnostic only; the lock flag is undocumented and cannot authorize password entry.")
        print("Input target: \(InputDiagnostics.inspect())")
    }
}
