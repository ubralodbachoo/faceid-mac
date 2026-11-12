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

/// Operational metadata only. Never contains field contents, app names, account IDs or secrets.
public struct InputTargetDiagnostic: Codable, Sendable {
    public var stage = "not-checked"
    public var applicationCategory: String?
    public var attribute: String?
    public var accessibilityError: Int32?
    public var source: String?
    public var fieldFailure: String?
    public var focusedFieldFailure: String?
    public var focusedAttribute: String?
    public var focusedAccessibilityError: Int32?
    public var searchRoots = 0
    public var visitedElements = 0
}

/// Check both focus sources. A non-secure application element must not hide a valid system field.
func selectSecureField<T>(application: T?, system: T?, isValid: (T) -> Bool, equal: (T, T) -> Bool) -> T? {
    let app = application.flatMap { isValid($0) ? $0 : nil }
    let global = system.flatMap { isValid($0) ? $0 : nil }
    if let app, let global { return equal(app, global) ? global : nil }
    return global ?? app
}

@MainActor
struct LockScreenInput {
    static private(set) var diagnostic = InputTargetDiagnostic()

    private func focusedLoginwindow() throws -> AXUIElement {
        Self.diagnostic = InputTargetDiagnostic()
        Self.diagnostic.stage = "accessibility-permission"
        guard AXIsProcessTrusted() else { throw InputError.accessibility }
        let system = AXUIElementCreateSystemWide()
        Self.diagnostic.stage = "focused-application"
        guard let app = element(system, kAXFocusedApplicationAttribute) else { throw InputError.target }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid > 0 else { throw InputError.target }
        let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        Self.diagnostic.applicationCategory = identifier == "com.apple.loginwindow" ? "loginwindow"
            : identifier == Bundle.main.bundleIdentifier ? "self" : "other-or-unavailable"
        Self.diagnostic.stage = "loginwindow-identity"
        guard identifier == "com.apple.loginwindow" else { throw InputError.target }
        Self.diagnostic.stage = "loginwindow-signature"
        guard isAppleLoginwindow(pid: pid) else { throw InputError.target }
        return app
    }

    func inspectTarget(preferred: SecureInputTarget? = nil) throws -> SecureInputTarget {
        let app = try focusedLoginwindow()
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { throw InputError.target }
        let system = AXUIElementCreateSystemWide()
        Self.diagnostic.stage = "focused-field"
        let appField = element(app, kAXFocusedUIElementAttribute)
        let globalField = element(system, kAXFocusedUIElementAttribute)
        var validFocusSources = 0
        func valid(_ candidate: AXUIElement) -> Bool {
            var owner: pid_t = 0
            guard AXUIElementGetPid(candidate, &owner) == .success, owner == pid else {
                Self.diagnostic.fieldFailure = "owner"; return false
            }
            guard string(candidate, kAXRoleAttribute) == kAXTextFieldRole as String else {
                Self.diagnostic.fieldFailure = "role"; return false
            }
            guard string(candidate, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String else {
                Self.diagnostic.fieldFailure = "secure-subrole"; return false
            }
            guard boolean(candidate, kAXFocusedAttribute) == true else {
                Self.diagnostic.fieldFailure = "focus"; return false
            }
            guard boolean(candidate, kAXEnabledAttribute) == true else {
                Self.diagnostic.fieldFailure = "enabled"; return false
            }
            validFocusSources += 1
            return true
        }
        let field = selectSecureField(application: appField, system: globalField, isValid: valid, equal: { CFEqual($0, $1) })
        if let field { return readyTarget(field, pid: pid, source: globalField.map { CFEqual(field, $0) } == true ? "system" : "application") }
        guard validFocusSources < 2 else {
            Self.diagnostic.fieldFailure = "conflicting-focused-fields"; throw InputError.field
        }
        if let preferred, preferred.pid == pid, valid(preferred.field) {
            return readyTarget(preferred.field, pid: pid, source: "verified-target")
        }
        let originalFailure = Self.diagnostic.fieldFailure ?? "missing-focused-field"
        let originalError = Self.diagnostic.accessibilityError
        Self.diagnostic.focusedFieldFailure = originalFailure
        Self.diagnostic.focusedAttribute = Self.diagnostic.attribute
        Self.diagnostic.focusedAccessibilityError = originalError
        let candidates = try secureFields(in: app, pid: pid, requireFocused: true)
        if candidates.count == 1 { return readyTarget(candidates[0], pid: pid, source: "window-tree") }
        Self.diagnostic.fieldFailure = candidates.isEmpty ? "no-focused-secure-field" : "ambiguous-focused-secure-fields"
        if Self.diagnostic.accessibilityError == nil { Self.diagnostic.accessibilityError = originalError }
        throw InputError.field
    }

    private func readyTarget(_ field: AXUIElement, pid: pid_t, source: String) -> SecureInputTarget {
        Self.diagnostic.stage = "ready"
        Self.diagnostic.source = source
        Self.diagnostic.fieldFailure = nil
        Self.diagnostic.attribute = nil; Self.diagnostic.accessibilityError = nil
        // Never read AXValue, selected text, titles or password contents.
        return SecureInputTarget(pid: pid, field: field)
    }

    /// Prepare focus after a match; the caller keeps scanning if this is not ready.
    /// Only the already focused, signature-verified Apple loginwindow is inspected.
    func prepareTarget() throws -> SecureInputTarget {
        if let target = try? inspectTarget() { return target }
        let original = Self.diagnostic
        let app = try focusedLoginwindow()
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { throw InputError.target }
        Self.diagnostic.focusedFieldFailure = original.focusedFieldFailure ?? original.fieldFailure
        Self.diagnostic.focusedAttribute = original.focusedAttribute ?? original.attribute
        Self.diagnostic.focusedAccessibilityError = original.focusedAccessibilityError ?? original.accessibilityError
        let candidates = try secureFields(in: app, pid: pid, requireFocused: false)
        guard candidates.count == 1 else {
            Self.diagnostic.fieldFailure = candidates.isEmpty ? "no-secure-field" : "ambiguous-secure-fields"
            throw InputError.field
        }
        let current = try focusedLoginwindow()
        guard CFEqual(current, app) else { throw InputError.changed }
        Self.diagnostic.stage = "focus-secure-field"
        let focused = AXUIElementSetAttributeValue(candidates[0], kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focused == .success else {
            Self.diagnostic.accessibilityError = focused.rawValue
            throw InputError.field
        }
        return try inspectTarget()
    }

    private func secureFields(in app: AXUIElement, pid: pid_t, requireFocused: Bool) throws -> [AXUIElement] {
        Self.diagnostic.stage = "secure-field-search"
        var roots: [AXUIElement] = []
        if let focused = element(app, kAXFocusedWindowAttribute) { roots.append(focused) }
        roots += attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        roots.append(app)
        Self.diagnostic.searchRoots = roots.count
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        let search = searchSecureFieldGraph(roots: roots, children: { node in
            attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }, owned: { node in
            var owner: pid_t = 0
            return AXUIElementGetPid(node, &owner) == .success && owner == pid
        }, candidate: { node in
            string(node, kAXRoleAttribute) == kAXTextFieldRole as String &&
            string(node, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String &&
            boolean(node, kAXEnabledAttribute) == true &&
            (!requireFocused || boolean(node, kAXFocusedAttribute) == true)
        }, equal: { CFEqual($0, $1) }, keepGoing: { ProcessInfo.processInfo.systemUptime < deadline })
        Self.diagnostic.visitedElements = search.visited
        guard search.complete else {
            Self.diagnostic.fieldFailure = "search-incomplete"; throw InputError.field
        }
        let candidates = search.fields
        return candidates
    }

    /// Wake the password prompt once, with a non-secret key sent only to verified loginwindow.
    /// Skip the wake key when the focused element is already a secure field.
    func revealPasswordPrompt() throws {
        let app = try focusedLoginwindow()
        let system = AXUIElementCreateSystemWide()
        let focusedFields = [element(app, kAXFocusedUIElementAttribute), element(system, kAXFocusedUIElementAttribute)].compactMap { $0 }
        if focusedFields.contains(where: { string($0, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String }) { return }
        let snapshot = MacSessionReader().read()
        guard snapshot.assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked else {
            throw InputError.changed
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid > 0,
              CFEqual(try focusedLoginwindow(), app) else { throw InputError.target }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) else { throw InputError.event }
        down.flags = []; up.flags = []
        down.postToPid(pid); up.postToPid(pid)
    }

    func submit(_ password: Data, to target: SecureInputTarget, stillAuthorized: () -> Bool) throws {
        guard let text = String(data: password, encoding: .utf8) else { throw VaultError.invalidPassword }
        var units = Array(text.utf16)
        defer { units.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: $0.count) } }
        let source = CGEventSource(stateID: .hidSystemState)

        func validate() throws {
            guard stillAuthorized() else { throw InputError.changed }
            let current = try inspectTarget(preferred: target)
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
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else {
            Self.diagnostic.attribute = name
            Self.diagnostic.accessibilityError = result.rawValue
            return nil
        }
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

/// Bounded metadata-only search. Explicit window roots work even when AXChildren on the app is empty.
func searchSecureFieldGraph<Node>(roots: [Node], children: (Node) -> [Node], owned: (Node) -> Bool,
    candidate: (Node) -> Bool, equal: (Node, Node) -> Bool, keepGoing: () -> Bool,
    limit: Int = 128) -> (fields: [Node], visited: Int, complete: Bool) {
    var pending = roots
    var visited: [Node] = []
    var fields: [Node] = []
    while !pending.isEmpty, visited.count < limit, keepGoing() {
        let node = pending.removeFirst()
        if visited.contains(where: { equal($0, node) }) { continue }
        visited.append(node)
        guard owned(node) else { continue }
        if candidate(node) { fields.append(node) }
        pending += children(node)
    }
    pending.removeAll { node in visited.contains { equal($0, node) } }
    return (fields, visited.count, pending.isEmpty)
}
