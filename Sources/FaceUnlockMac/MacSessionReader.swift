import CoreGraphics
import CoreFoundation
import Darwin
import Foundation
import SystemConfiguration
import FaceUnlockCore

@MainActor
public struct MacSessionReader {
    public init() {}

    public func read() -> SessionSnapshot {
        var consoleUID: uid_t = 0
        var consoleGID: gid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) as String?
        let consoleUserID: UInt32? = if let name, name != "loginwindow", consoleUID != 0 {
            consoleUID
        } else {
            nil
        }
        let fields = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        // Timestamp after both reads. These APIs are not an atomic account/lock transaction.
        return SessionDictionaryParser.snapshot(
            fields: fields, processUserID: getuid(), consoleUserID: consoleUserID,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }
}

enum SessionDictionaryParser {
    static func snapshot(
        fields: [String: Any], processUserID: UInt32, consoleUserID: UInt32?, uptime: Double
    ) -> SessionSnapshot {
        let lockFlag = boolean(fields["CGSSessionScreenIsLocked"])
        // This flag is undocumented. Absence is UNKNOWN, never evidence of an unlocked screen.
        let lock: ScreenLockState = lockFlag.map { $0 ? .locked : .unlocked } ?? .unknown
        return SessionSnapshot(
            processUserID: processUserID, consoleUserID: consoleUserID,
            sessionUserID: userID(fields[kCGSessionUserIDKey as String]),
            isOnConsole: boolean(fields[kCGSessionOnConsoleKey as String]),
            loginComplete: boolean(fields[kCGSessionLoginDoneKey as String]),
            screenLock: lock, sampledAtUptime: uptime
        )
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func userID(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt32(exactly: number.doubleValue)
    }
}
