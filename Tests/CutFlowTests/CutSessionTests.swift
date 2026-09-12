import XCTest
@testable import CutFlowCore

final class CutSessionTests: XCTestCase {
    private let finder = "com.apple.finder"
    private let forklift = "com.binarynights.ForkLift"

    private func armed() -> CutSession {
        var session = CutSession()
        session.begin(changeCount: 10, owner: finder, now: 0)
        session.observe(changeCount: 11, fileCount: 2, frontmostOwner: finder, now: 0.1)
        return session
    }

    func testOrdinaryCopyNeverMoves() {
        var session = CutSession()
        session.observe(changeCount: 11, fileCount: 3, frontmostOwner: finder, now: 0.1)
        XCTAssertFalse(session.consumeMove(changeCount: 11, owner: finder))
    }

    func testCutMustProduceFreshClipboard() {
        var session = CutSession()
        session.begin(changeCount: 10, owner: finder, now: 0)
        session.observe(changeCount: 10, fileCount: 3, frontmostOwner: finder, now: 0.1)
        XCTAssertFalse(session.canMove(changeCount: 10, owner: finder))
    }

    func testFreshFileCopyArmsMoveWithCorrectCount() {
        let session = armed()
        XCTAssertEqual(session.state, .ready(changeCount: 11, owner: finder, fileCount: 2))
    }

    func testMoveIsConsumedExactlyOnce() {
        var session = armed()
        XCTAssertTrue(session.consumeMove(changeCount: 11, owner: finder))
        XCTAssertFalse(session.consumeMove(changeCount: 11, owner: finder))
    }

    func testChangedClipboardCannotMoveEvenBeforePolling() {
        var session = armed()
        XCTAssertFalse(session.consumeMove(changeCount: 12, owner: finder))
    }

    func testClipboardReplacementClearsIntent() {
        var session = armed()
        session.observe(changeCount: 12, fileCount: 5, frontmostOwner: finder, now: 1)
        XCTAssertEqual(session.state, .idle)
    }

    func testTextCopyCannotArmFileMove() {
        var session = CutSession()
        session.begin(changeCount: 10, owner: finder, now: 0)
        session.observe(changeCount: 11, fileCount: 0, frontmostOwner: finder, now: 0.1)
        XCTAssertEqual(session.state, .idle)
    }

    func testCopyFailureTimesOutWithoutUsingOldFiles() {
        var session = CutSession()
        session.begin(changeCount: 10, owner: finder, now: 0)
        session.observe(changeCount: 10, fileCount: 2, frontmostOwner: finder, now: 2)
        XCTAssertEqual(session.state, .idle)
    }

    func testLateClipboardCannotArmMove() {
        var session = CutSession()
        session.begin(changeCount: 10, owner: finder, now: 0)
        session.observe(changeCount: 11, fileCount: 2, frontmostOwner: finder, now: 2)
        XCTAssertEqual(session.state, .idle)
    }

    func testFocusChangeDuringCopyCancelsCapture() {
        var session = CutSession()
        session.begin(changeCount: 10, owner: finder, now: 0)
        session.observe(changeCount: 11, fileCount: 2, frontmostOwner: "com.apple.TextEdit", now: 0.1)
        XCTAssertEqual(session.state, .idle)
    }

    func testMoveDoesNotCrossFileManagers() {
        var session = armed()
        XCTAssertFalse(session.consumeMove(changeCount: 11, owner: forklift))
        XCTAssertTrue(session.canMove(changeCount: 11, owner: finder))
    }

    func testArmedCutSurvivesSwitchingAwayAndBack() {
        var session = armed()
        session.observe(changeCount: 11, fileCount: 0, frontmostOwner: "com.apple.TextEdit", now: 50)
        XCTAssertTrue(session.canMove(changeCount: 11, owner: finder))
    }

    func testCancelPreventsMoveWithoutNeedingClipboardMutation() {
        var session = armed()
        session.cancel()
        XCTAssertFalse(session.canMove(changeCount: 11, owner: finder))
    }

    func testSecondCutReplacesFirstAndNeedsFreshCopy() {
        var session = armed()
        session.begin(changeCount: 11, owner: finder, now: 1)
        XCTAssertFalse(session.canMove(changeCount: 11, owner: finder))
        session.observe(changeCount: 12, fileCount: 1, frontmostOwner: finder, now: 1.1)
        XCTAssertEqual(session.state, .ready(changeCount: 12, owner: finder, fileCount: 1))
    }

    func testFileManagerAllowlist() {
        XCTAssertTrue(ShortcutPolicy.supports(finder, forkLift: false))
        XCTAssertTrue(ShortcutPolicy.supports(forklift, forkLift: true))
        XCTAssertTrue(ShortcutPolicy.supports("com.binarynights.forklift-setapp", forkLift: true))
        XCTAssertFalse(ShortcutPolicy.supports(forklift, forkLift: false))
        XCTAssertFalse(ShortcutPolicy.supports("com.apple.TextEdit", forkLift: true))
        XCTAssertFalse(ShortcutPolicy.supports("com.apple.finder.spoof", forkLift: true))
    }

    func testTextFocusRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(ShortcutPolicy.isTextRole(role))
        }
        XCTAssertFalse(ShortcutPolicy.isTextRole("AXOutline"))
        XCTAssertFalse(ShortcutPolicy.isTextRole("AXBrowser"))
    }
}
