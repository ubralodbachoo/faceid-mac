import AppKit
import Darwin
import FaceUnlockMac
import FaceUnlockCore

/// Development-only private SkyLight interop. Optional; never participates in credential authorization.
/// API reference: MIT-licensed jonnyoo/glance NotchOverlay/NotchSkyLight.swift (license bundled in Models).
@MainActor
final class LockScreenWindowBridge {
    static let shared: LockScreenWindowBridge? = LockScreenWindowBridge()
    private typealias ConnectionFunction = @convention(c) () -> Int32
    private typealias CreateFunction = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias LevelFunction = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpacesFunction = @convention(c) (Int32, CFArray) -> Int32
    private typealias AttachFunction = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias DetachFunction = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let library: UnsafeMutableRawPointer
    private let connectionID: Int32
    private let spaceID: Int32
    private let attachWindows: AttachFunction
    private let detachWindows: DetachFunction

    private init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let connectionFunction = symbol("SLSMainConnectionID", ConnectionFunction.self),
              let createFunction = symbol("SLSSpaceCreate", CreateFunction.self),
              let levelFunction = symbol("SLSSpaceSetAbsoluteLevel", LevelFunction.self),
              let showFunction = symbol("SLSShowSpaces", SpacesFunction.self),
              let attachFunction = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", AttachFunction.self),
              let detachFunction = symbol("SLSRemoveWindowsFromSpaces", DetachFunction.self) else {
            dlclose(library); return nil
        }
        let connection = connectionFunction()
        let space = createFunction(connection, 1, 0)
        guard space > 0,
              levelFunction(connection, space, 400) == 0,
              showFunction(connection, [NSNumber(value: space)] as CFArray) == 0 else {
            // Do not call unresolved/dangling symbols if macOS changes this private interface.
            dlclose(library); return nil
        }
        self.library = library; connectionID = connection; spaceID = space
        attachWindows = attachFunction; detachWindows = detachFunction
    }

    func attach(_ panel: NSPanel) -> Bool {
        // Decorative visibility must never extend beyond the freshly observed locked account.
        guard MacSessionReader().read().assessment(at: ProcessInfo.processInfo.systemUptime, maximumAge: 0.5) == .observedLocked else { return false }
        return attachWindows(connectionID, spaceID, [NSNumber(value: panel.windowNumber)] as CFArray, 7) == 0
    }

    func detach(_ panel: NSPanel) {
        _ = detachWindows(connectionID, [NSNumber(value: panel.windowNumber)] as CFArray, [NSNumber(value: spaceID)] as CFArray)
    }
}
