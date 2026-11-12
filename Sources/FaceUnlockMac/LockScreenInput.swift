import AppKit
import ApplicationServices
import Foundation
import Security
import FaceUnlockCore

public enum InputDiagnostics {
    @MainActor public static func inspect() -> String {
        do { _ = try LockScreenInput().inspectTarget(); return "Verified Apple loginwindow secure field" }
        catch { return error.localizedDescription }
    }
}

public enum InputError: Error, LocalizedError {
    case accessibility, target, field, changed, event

    public var errorDescription: String? {
        switch self {
        case .accessibility: "Accessibility permission is missing. Enable this app in System Settings."
        case .target: "The focused application is not verified Apple loginwindow."
        case .field: "The focused element is not an enabled secure password field owned by loginwindow."
        case .changed: "Lock, account, authorization, or password-field focus changed. Input stopped."
        case .event: "A keyboard event could not be constructed."
        }
    }
}

struct SecureInputTarget {
    let pid: pid_t
    let field: AXUIElement
}

@MainActor
struct LockScreenInput {
    func inspectTarget() throws -> SecureInputTarget {
        guard AXIsProcessTrusted() else { throw InputError.accessibility }
        let system = AXUIElementCreateSystemWide()
        guard let app = element(system, kAXFocusedApplicationAttribute) else { throw InputError.target }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid > 0,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.loginwindow",
              isAppleLoginwindow(pid: pid) else { throw InputError.target }
        guard let field = element(system, kAXFocusedUIElementAttribute) else { throw InputError.field }
        var fieldPID: pid_t = 0
        guard AXUIElementGetPid(field, &fieldPID) == .success, fieldPID == pid,
              string(field, kAXRoleAttribute) == kAXTextFieldRole as String,
              string(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String,
              boolean(field, kAXFocusedAttribute) == true,
              boolean(field, kAXEnabledAttribute) == true else { throw InputError.field }
        // Intentionally never read AXValue, selected text, or contents of the password field.
        return SecureInputTarget(pid: pid, field: field)
    }

    func submit(_ password: Data, to target: SecureInputTarget, stillAuthorized: () -> Bool) throws {
        guard let text = String(data: password, encoding: .utf8) else { throw VaultError.invalidPassword }
        var units = Array(text.utf16)
        defer { units.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: $0.count) } }
        let source = CGEventSource(stateID: .hidSystemState)

        func validate() throws {
            guard stillAuthorized() else { throw InputError.changed }
            let current = try inspectTarget()
            guard current.pid == target.pid, CFEqual(current.field, target.field) else { throw InputError.changed }
        }

        func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
            try validate()
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw InputError.event }
            down.flags = flags
            up.flags = flags
            // PID-directed delivery only. Never fall back to globally typing into whatever has focus.
            down.postToPid(target.pid)
            up.postToPid(target.pid)
            Thread.sleep(forTimeInterval: 0.015)
        }

        // Clear any partial password without reading it; these navigation keycodes are layout independent.
        try key(124, flags: .maskCommand) // Command-Right
        try key(51, flags: .maskCommand)  // Command-Delete
        var offset = 0
        while offset < units.count {
            try validate()
            var end = min(offset + 16, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw InputError.event }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: end - offset, unicodeString: buffer.baseAddress! + offset)
                up.keyboardSetUnicodeString(stringLength: end - offset, unicodeString: buffer.baseAddress! + offset)
            }
            down.flags = []
            up.flags = []
            down.postToPid(target.pid)
            up.postToPid(target.pid)
            offset = end
            Thread.sleep(forTimeInterval: 0.015)
        }
        try key(36) // Return only after the final fresh guard.
    }

    private func isAppleLoginwindow(pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.loginwindow\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func boolean(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
