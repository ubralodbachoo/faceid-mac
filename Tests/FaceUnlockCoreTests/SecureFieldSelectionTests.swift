import Foundation
import XCTest
@testable import FaceUnlockMac

final class SecureFieldSelectionTests: XCTestCase {
    func testInvalidApplicationElementDoesNotHideValidSystemField() {
        let selected = selectSecureField(application: 1, system: 2, isValid: { $0 == 2 }, equal: ==)
        XCTAssertEqual(selected, 2)
    }

    func testInvalidSystemElementDoesNotHideValidApplicationField() {
        XCTAssertEqual(selectSecureField(application: 1, system: 2, isValid: { $0 == 1 }, equal: ==), 1)
    }

    func testConflictingValidFocusedFieldsFailClosed() {
        XCTAssertNil(selectSecureField(application: 1, system: 2, isValid: { _ in true }, equal: ==))
        XCTAssertEqual(selectSecureField(application: 1, system: 1, isValid: { _ in true }, equal: ==), 1)
    }

    func testMissingOrUnvalidatedFieldsNeverBecomeTargets() {
        XCTAssertNil(selectSecureField(application: Optional<Int>.none, system: nil, isValid: { _ in true }, equal: ==))
        XCTAssertNil(selectSecureField(application: 1, system: 2, isValid: { _ in false }, equal: ==))
        XCTAssertEqual(selectSecureField(application: Optional<Int>.none, system: 2, isValid: { _ in true }, equal: ==), 2)
    }

    func testWindowRootsFindSecureFieldWhenApplicationChildrenAreEmpty() {
        let search = searchSecureFieldGraph(roots: [10, 0], children: { $0 == 10 ? [11] : [] },
            owned: { _ in true }, candidate: { $0 == 11 }, equal: ==, keepGoing: { true })
        XCTAssertEqual(search.fields, [11])
        XCTAssertTrue(search.complete)
    }

    func testSearchDeduplicatesRootsRejectsForeignSubtreesAndBoundsWork() {
        let children: (Int) -> [Int] = { node in
            if node == 0 { return [0, 1, 2] }
            if node == 1 { return [99] }
            return []
        }
        let search = searchSecureFieldGraph(roots: [Int(0), 0, 1], children: children,
            owned: { (node: Int) in node != 1 }, candidate: { (node: Int) in node == 2 || node == 99 },
            equal: { (a: Int, b: Int) in a == b }, keepGoing: { true })
        XCTAssertEqual(search.fields, [2])
        XCTAssertTrue(search.complete)
        let bounded = searchSecureFieldGraph(roots: [0], children: { [$0 + 1] },
            owned: { _ in true }, candidate: { _ in false }, equal: ==, keepGoing: { true }, limit: 4)
        XCTAssertFalse(bounded.complete)
        XCTAssertEqual(bounded.visited, 4)
    }

    func testInputDiagnosticsContainOnlyOperationalMetadata() throws {
        var diagnostic = InputTargetDiagnostic()
        diagnostic.stage = "focused-field"
        diagnostic.applicationCategory = "loginwindow"
        diagnostic.attribute = "AXFocusedUIElement"
        diagnostic.accessibilityError = -25204
        diagnostic.fieldFailure = "focus"
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["stage", "applicationCategory", "attribute", "accessibilityError", "fieldFailure", "searchRoots", "visitedElements"])
    }
}
