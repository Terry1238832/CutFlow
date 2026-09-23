import AppKit
import XCTest
@testable import CutFlow

final class FinderContextMenuTests: XCTestCase {
    func testOnlyEnabledNativeContextMoveIdentifierMatches() {
        XCTAssertTrue(FinderContextMenu.isMoveItem(identifier: "cmdMoveItemsHere:", enabled: true))
        for id: String? in [nil, "paste:", "cmdPasteExactly:", "cmdMoveToTrash:", "executePlugInCommand:"] {
            XCTAssertFalse(FinderContextMenu.isMoveItem(identifier: id, enabled: true))
        }
        XCTAssertFalse(FinderContextMenu.isMoveItem(identifier: "cmdMoveItemsHere:", enabled: false))
    }

    func testContextMenuWaitsForPhysicalCommandRelease() {
        XCTAssertFalse(FinderContextMenu.canOpenMenu(physicalFlags: [.maskCommand]))
        XCTAssertFalse(FinderContextMenu.canOpenMenu(physicalFlags: [.maskCommand, .maskControl]))
        XCTAssertTrue(FinderContextMenu.canOpenMenu(physicalFlags: []))
    }

    func testContextKeyIsPairedControlReturnAndTaggedForTapBypass() {
        for down in [true, false] {
            let event = FinderContextMenu.menuKey(down: down)!
            XCTAssertEqual(event.type, down ? .keyDown : .keyUp)
            XCTAssertEqual(event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]), .maskControl)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 36)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), FinderContextMenu.eventMarker)
            XCTAssertEqual(NSEvent(cgEvent: event)?.charactersIgnoringModifiers, "\r")
        }
    }

    func testDismissKeyTargetsOnlyTheMenuAndIsTagged() {
        for down in [true, false] {
            let event = FinderContextMenu.dismissKey(down: down)!
            XCTAssertEqual(event.type, down ? .keyDown : .keyUp)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 53)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), FinderContextMenu.eventMarker)
        }
    }
}
