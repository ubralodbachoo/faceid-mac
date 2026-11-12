import AppKit
import Darwin
import FaceUnlockMac
import FaceUnlockCore

/// Development-only private SkyLight interop. Optional; never participates in credential authorization.
/// API reference: MIT-licensed jonnyoo/glance NotchOverlay/NotchSkyLight.swift (license bundled in Models).
@MainActor
final class LockScreenWindowBridge {
    private static var cache = LockScreenBridgeCache<LockScreenWindowBridge>()
    private(set) static var initializationFailure: String?
    static var shared: LockScreenWindowBridge? {
        cache.resolve(at: ProcessInfo.processInfo.systemUptime) { LockScreenWindowBridge() }
    }

    /// Create the WindowServer space while the desktop is available, before locking.
    static func prepare() { _ = shared }
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias CreateFunction = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias LevelFunction = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpacesFunction = @convention(c) (Int32, CFArray) -> Void
    private typealias AttachFunction = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    private typealias DetachFunction = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias CopyWindowSpacesFunction = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private(set) var lastAttachmentFailure: String?
    private let library: UnsafeMutableRawPointer
    private let connectionID: Int32
    private let spaceID: UInt64
    private let showSpaces: SpacesFunction
    private let copyWindowSpaces: CopyWindowSpacesFunction
    private let attachWindows: AttachFunction
    private let detachWindows: DetachFunction

    private init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
            Self.initializationFailure = "library-load"; return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let connectionFunction = symbol("SLSMainConnectionID", ConnectionFunction.self),
              let createFunction = symbol("SLSSpaceCreate", CreateFunction.self),
              let levelFunction = symbol("SLSSpaceSetAbsoluteLevel", LevelFunction.self),
              let showFunction = symbol("SLSShowSpaces", SpacesFunction.self),
              let attachFunction = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", AttachFunction.self),
              let detachFunction = symbol("SLSRemoveWindowsFromSpaces", DetachFunction.self),
              let copyFunction = symbol("SLSCopySpacesForWindows", CopyWindowSpacesFunction.self) else {
            Self.initializationFailure = "missing-symbol"
            dlclose(library); return nil
        }
        let connection = connectionFunction()
        guard connection != 0 else {
            Self.initializationFailure = "connection"; dlclose(library); return nil
        }
        let space = createFunction(connection, 1, 0)
        guard space > 0 else {
            Self.initializationFailure = "space-create"; dlclose(library); return nil
        }
        // These private setters return void. Reading a fabricated Int32 result
        // produced random "space-show" failures depending on register contents.
        levelFunction(connection, space, 400)
        showFunction(connection, [NSNumber(value: space)] as CFArray)
        Self.initializationFailure = nil
        self.library = library; connectionID = connection; spaceID = space
        attachWindows = attachFunction; detachWindows = detachFunction
        showSpaces = showFunction; copyWindowSpaces = copyFunction
    }

    func attach(_ panel: NSPanel) -> Bool {
        // Decorative visibility must never extend beyond the freshly observed locked account.
        guard MacSessionReader().read().assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked else { return false }
        return moveToOverlaySpace(windowNumber: panel.windowNumber)
    }

    /// Internal so native tests can verify membership with an unordered, invisible panel.
    func moveToOverlaySpace(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { lastAttachmentFailure = "window-not-created"; return false }
        // Display wake can hide the custom space without removing its windows.
        showSpaces(connectionID, [NSNumber(value: spaceID)] as CFArray)
        attachWindows(connectionID, spaceID, [NSNumber(value: windowNumber)] as CFArray, 7)
        guard let result = copyWindowSpaces(connectionID, 15, [NSNumber(value: windowNumber)] as CFArray) else { lastAttachmentFailure = "membership-query-unavailable"; return false }
        let spaces = result.takeRetainedValue() as NSArray
        let attached = spaces.compactMap { $0 as? NSNumber }.contains { $0.uint64Value == spaceID }
        lastAttachmentFailure = attached ? nil : "space-membership-absent(\(spaces.count))"
        return attached
    }

    func detach(_ panel: NSPanel) {
        detachWindows(connectionID, [NSNumber(value: panel.windowNumber)] as CFArray, [NSNumber(value: spaceID)] as CFArray)
    }
}

/// Successful bridges persist; transient failures are retried at a bounded rate.
@MainActor
struct LockScreenBridgeCache<Value> {
    private var value: Value?
    private var lastAttempt = -Double.infinity
    mutating func resolve(at time: Double, create: () -> Value?) -> Value? {
        if let value { return value }
        guard time.isFinite, time >= 0,
              time < lastAttempt || time - lastAttempt >= 1 else { return nil }
        lastAttempt = time
        value = create()
        return value
    }
}
