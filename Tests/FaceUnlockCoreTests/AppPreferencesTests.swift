import Foundation
import XCTest
@testable import FaceUnlockApp

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testFirstRunCompletionPersistsButAdminCanAlwaysReplay() throws {
        let suite = "FaceUnlock.PreferencesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.shouldPresentSetupAtLaunch(isAdmin: false))
        preferences.recordCompletedSetup()
        let reopened = AppPreferences(defaults: defaults)
        XCTAssertFalse(reopened.shouldPresentSetupAtLaunch(isAdmin: false))
        XCTAssertTrue(reopened.shouldPresentSetupAtLaunch(isAdmin: true))
    }

    @MainActor
    func testAppearanceSurvivesRelaunchAndUnknownColorFallsBack() throws {
        let suite = "FaceUnlock.PreferencesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.accent = .violet
        XCTAssertEqual(AppPreferences(defaults: defaults).accent, .violet)
        XCTAssertFalse(preferences.setupCompleted)
        defaults.set("removed-color", forKey: "faceIDAccent")
        XCTAssertEqual(AppPreferences(defaults: defaults).accent, .green)
    }

    func testSetupStaysOnScreenAndMeetsTheTopEdge() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1280, y: 200, width: 1280, height: 720),
                       CGRect(x: 0, y: -600, width: 800, height: 600)] {
            let frame = NotchSetupGeometry.frame(screen: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.maxY, screen.maxY)
            XCTAssertEqual(frame.midX, screen.midX)
        }
    }
    @MainActor
    func testEffectsTogglesPersistExplicitFalseAndDefaultToOn() throws {
        let suite = "FaceUnlock.PreferencesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.lightRays); XCTAssertTrue(preferences.animations); XCTAssertTrue(preferences.hapticFeedback)
        preferences.lightRays = false; preferences.animations = false; preferences.hapticFeedback = false
        let reopened = AppPreferences(defaults: defaults)
        XCTAssertFalse(reopened.lightRays); XCTAssertFalse(reopened.animations); XCTAssertFalse(reopened.hapticFeedback)
    }

}
