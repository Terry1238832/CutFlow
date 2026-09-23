import AppKit
import XCTest
@testable import CutFlow

/// Uses the production handler and its deferred command boundary. No events
/// are posted and no real Finder menu or system clipboard is touched.
final class FinderCommandTests: XCTestCase {
    private var board: NSPasteboard!
    private var service: KeyboardService!
    private var queued: [() -> Void] = []
    private var actions: [FinderMenuCommand.Command] = []
    private var owner = "com.apple.finder"
    private var pid: pid_t = 42
    private var editable = false
    private var now: TimeInterval = 0
    private var outcome: FinderMenuCommand.Outcome = .performed
    private var writeOnCopy = true
    private var invalidateBeforePress = false
    private var destination: FinderPasteDestination.Decision = .currentDirectory
    private var contextRequests = 0
    private var contextMoves = 0
    private var contextChecks: [() -> Void] = []
    private var onMenuOpened: (() -> Void)?
    private let file = URL(fileURLWithPath: "/tmp/cutflow-test/剪切测试.txt")

    override func setUp() {
        super.setUp()
        board = NSPasteboard.withUniqueName()
        service = KeyboardService(pasteboard: board, currentApplication: { [unowned self] in
            .init(bundleID: owner, pid: pid)
        }, fileContext: { [unowned self] _ in !editable }, uptime: { [unowned self] in now },
        finderCommand: { [unowned self] command, _, valid in
            if invalidateBeforePress { owner = "com.apple.TextEdit" }
            guard valid() else { return .failed("执行前焦点发生变化") }
            actions.append(command)
            if command == .copy, outcome == .performed, writeOnCopy {
                board.clearContents()
                board.writeObjects([file as NSURL])
            }
            return outcome
        }, scheduleCommand: { [unowned self] in queued.append($0) },
        finderDestination: { [unowned self] _, _ in destination },
        finderContextMove: { [unowned self] _, preflight, transactionValid, finish in
            contextRequests += 1
            contextChecks.append { [unowned self] in
                guard preflight() else { finish(.failed("文件夹菜单已取消")); return }
                onMenuOpened?()
                guard transactionValid() else { finish(.failed("移动期间剪贴板或应用已变化")); return }
                contextMoves += 1
                finish(outcome)
            }
        })
    }
    override func tearDown() {
        service.stop(); service = nil
        queued.removeAll()
        contextChecks.removeAll()
        board.releaseGlobally(); board = nil
        super.tearDown()
    }
    @discardableResult private func key(_ code: CGKeyCode, up: Bool = false,
        flags: CGEventFlags = .maskCommand, repeating: Bool = false) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: !up)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return service.handle(type: event.type, event: event)
    }
    private func drain() {
        let tasks = queued; queued.removeAll()
        tasks.forEach { $0() }
    }
    private func arm() {
        XCTAssertNil(key(7)); XCTAssertNil(key(7, up: true)); drain()
        XCTAssertEqual(service.cutFileURLs, [file])
    }
    private func finishContextMove() {
        let checks = contextChecks; contextChecks.removeAll()
        checks.forEach { $0() }
    }
    private func startSelectedFolderMove() {
        arm()
        destination = .folder(URL(fileURLWithPath: "/tmp/cutflow-target", isDirectory: true))
        XCTAssertNil(key(9)); drain()
        XCTAssertEqual(actions, [.copy]) // No Open or current-directory Move.
        XCTAssertEqual(contextRequests, 1)
        XCTAssertEqual(contextMoves, 0)
    }
    func testSelectedFolderUsesContextMenuWithoutNavigatingOrMovingInParent() {
        startSelectedFolderMove()
        XCTAssertFalse(service.cutFileURLs.isEmpty)
        finishContextMove()
        XCTAssertEqual(contextMoves, 1)
        XCTAssertEqual(actions, [.copy])
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
    }
    func testOrdinaryCurrentDirectoryPasteDoesNotOpenAContextMenu() {
        arm(); key(9); drain()
        XCTAssertEqual(actions, [.copy, .move])
        XCTAssertEqual(contextRequests, 0)
    }
    func testAmbiguousDestinationFailsWithoutOpeningAMenuOrMoving() {
        arm(); destination = .unavailable("无法确认目标"); key(9); drain()
        XCTAssertEqual(actions, [.copy]); XCTAssertEqual(contextRequests, 0)
        XCTAssertEqual(service.lastFailure, "无法确认目标")
    }
    func testEscapeBeforeContextMenuReadyCancelsMove() {
        startSelectedFolderMove(); key(53, flags: []); finishContextMove()
        XCTAssertEqual(contextMoves, 0)
        XCTAssertEqual(service.session.state, .idle)
    }
    func testNavigationKeyBeforeContextMenuReadyCancelsMove() {
        startSelectedFolderMove(); key(125, flags: []); finishContextMove()
        XCTAssertEqual(contextMoves, 0)
    }
    func testMouseBeforeContextMenuReadyCancelsMove() {
        startSelectedFolderMove()
        _ = service.handle(type: .leftMouseDown, event: CGEvent(source: nil)!)
        finishContextMove(); XCTAssertEqual(contextMoves, 0)
    }
    func testClipboardChangeBeforeContextMenuReadyCancelsMove() {
        startSelectedFolderMove()
        board.clearContents(); board.setString("replacement", forType: .string)
        finishContextMove(); XCTAssertEqual(contextMoves, 0)
        XCTAssertEqual(board.string(forType: .string), "replacement")
    }
    func testOtherApplicationBeforeContextMenuReadyCancelsMove() {
        startSelectedFolderMove(); owner = "com.apple.TextEdit"; finishContextMove()
        XCTAssertEqual(contextMoves, 0)
    }
    func testTargetSelectionIsRecheckedBeforeContextMove() {
        startSelectedFolderMove(); destination = .folder(URL(fileURLWithPath: "/tmp/other-target"))
        finishContextMove(); XCTAssertEqual(contextMoves, 0)
    }
    func testTextFocusBeforeContextMenuReadyCancelsMove() {
        startSelectedFolderMove(); editable = true; finishContextMove()
        XCTAssertEqual(contextMoves, 0)
    }
    func testContextMenuFocusCanHideSelectionWithoutCancellingMove() {
        startSelectedFolderMove()
        onMenuOpened = { [unowned self] in
            editable = true
            destination = .unavailable("菜单显示时所选行暂不可读")
        }
        finishContextMove()
        XCTAssertEqual(contextMoves, 1)
        XCTAssertEqual(service.session.state, .idle)
    }
    func testClipboardChangeWhileContextMenuOpenStillCancelsMove() {
        startSelectedFolderMove()
        onMenuOpened = { [unowned self] in
            board.clearContents(); board.setString("replacement", forType: .string)
        }
        finishContextMove()
        XCTAssertEqual(contextMoves, 0)
    }
    func testFailureNeverFallsBackToOpeningAFolderOrParentDirectoryMove() {
        startSelectedFolderMove(); outcome = .failed("菜单不可用"); finishContextMove()
        XCTAssertEqual(contextMoves, 1); XCTAssertEqual(actions, [.copy])
        XCTAssertEqual(service.lastFailure, "菜单不可用")
        XCTAssertEqual(service.session.state, .idle)
    }
    func testHeldAndSecondPastePressWhileMenuPendingCannotDuplicateTransfer() {
        startSelectedFolderMove()
        XCTAssertNil(key(9, repeating: true)); XCTAssertNil(key(9, up: true))
        XCTAssertNil(key(9)); drain()
        XCTAssertEqual(contextRequests, 1)
        finishContextMove(); XCTAssertEqual(contextMoves, 1)
        XCTAssertNil(key(9, repeating: true)); XCTAssertNil(key(9, up: true))
    }
    func testNewCutCannotBeClearedByOldContextCompletion() {
        startSelectedFolderMove(); key(7); key(7, up: true); drain()
        finishContextMove()
        XCTAssertEqual(contextMoves, 0)
        XCTAssertEqual(service.cutFileURLs, [file])
        XCTAssertNil(service.lastFailure)
    }
    func testDisabledServiceCancelsPendingContextMove() {
        startSelectedFolderMove(); service.enabled = false; finishContextMove()
        XCTAssertEqual(contextMoves, 0)
    }
    func testOwnContextShortcutDoesNotCancelPendingMoveOrEnterDiagnostics() {
        startSelectedFolderMove()
        let count = service.receivedKeyDownCount
        for down in [true, false] {
            let event = FinderContextMenu.menuKey(down: down)!
            XCTAssertTrue(service.handle(type: event.type, event: event) === event)
        }
        XCTAssertEqual(service.receivedKeyDownCount, count)
        finishContextMove(); XCTAssertEqual(contextMoves, 1)
    }

    func testNativeCutRunsAfterCallbackAndStartsDimmingOnlyAfterFileClipboard() {
        writeOnCopy = false
        XCTAssertNil(key(7))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        drain()
        XCTAssertEqual(actions, [.copy])
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        board.clearContents(); board.writeObjects([file as NSURL])
        service.refreshClipboard()
        XCTAssertEqual(service.cutFileURLs, [file])
        XCTAssertNil(service.lastFailure)
    }
    func testNativeMoveUsesMoveCommandAndConsumesIntentOnce() {
        arm()
        XCTAssertNil(key(9)); XCTAssertNil(key(9, repeating: true))
        drain()
        XCTAssertEqual(actions, [.copy, .move])
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertNil(key(9, repeating: true)); XCTAssertNil(key(9, up: true))
        XCTAssertNotNil(key(9)) // A new ordinary paste remains native.
        XCTAssertTrue(queued.isEmpty)
    }
    func testCopyIsNotAssumedSuccessfulJustBecauseMenuAcceptedIt() {
        writeOnCopy = false
        key(7); drain(); now = 2; service.refreshClipboard()
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        XCTAssertTrue(service.lastFailure?.contains("复制超时") == true)
    }
    func testFailedMenuCommandProducesVisibleFailureAndNeverArmsMove() {
        outcome = .failed("菜单命令不可用")
        key(7); drain()
        XCTAssertEqual(service.lastFailure, "菜单命令不可用")
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertNotNil(key(9))
    }
    func testEscapeCancelsQueuedCopy() {
        key(7); key(53, flags: []); drain()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(service.session.state, .idle)
    }
    func testNewCopyCancelsQueuedMoveWithoutTouchingFinder() {
        arm(); key(9); key(8); drain()
        XCTAssertEqual(actions, [.copy])
    }
    func testDisabledServiceCancelsQueuedAction() {
        key(7); service.enabled = false; drain()
        XCTAssertTrue(actions.isEmpty)
    }
    func testChangedApplicationOrProcessPreventsDeferredAction() {
        key(7); owner = "com.apple.TextEdit"; drain()
        XCTAssertTrue(actions.isEmpty)
        owner = "com.apple.finder"; key(7, up: true)
        key(7); pid = 43; drain()
        XCTAssertTrue(actions.isEmpty)
    }
    func testTextFocusIsRecheckedBeforeMenuPress() {
        key(7); editable = true; drain()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNotNil(service.lastFailure)
    }
    func testValidityIsCheckedAgainAfterMenuLookup() {
        key(7); invalidateBeforePress = true; drain()
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNotNil(service.lastFailure)
    }
    func testClipboardReplacementPreventsDeferredMove() {
        arm(); key(9)
        board.clearContents(); board.setString("new clipboard", forType: .string)
        drain()
        XCTAssertEqual(actions, [.copy])
        XCTAssertEqual(board.string(forType: .string), "new clipboard")
    }
    func testMouseSelectionChangeCancelsDeferredCommand() {
        key(7)
        _ = service.handle(type: .leftMouseDown, event: CGEvent(source: nil)!)
        drain()
        XCTAssertTrue(actions.isEmpty)
    }
    func testEarlyPasteNeverExecutesOrdinaryPasteOrDuplicateMove() {
        key(7); key(7, up: true)
        XCTAssertNil(key(9)); drain()
        XCTAssertNil(key(9, repeating: true)); XCTAssertNil(key(9, up: true))
        XCTAssertEqual(actions, [.copy])
        XCTAssertNil(key(9)); drain()
        XCTAssertEqual(actions, [.copy, .move])
    }
    func testFailedMoveIsNotRetriedAndDoesNotFallBackToCopy() {
        arm(); outcome = .failed("移动不可用")
        XCTAssertNil(key(9)); drain()
        XCTAssertEqual(actions, [.copy, .move])
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertEqual(service.lastFailure, "移动不可用")
        XCTAssertNil(key(9, repeating: true))
    }
    func testOnlyExactNativeShortcutsMatchIndependentOfMenuLanguage() {
        XCTAssertTrue(FinderMenuCommand.Command.copy.matches(character: "C", modifiers: 0))
        XCTAssertTrue(FinderMenuCommand.Command.move.matches(character: "V", modifiers: 2))
        for modifiers: UInt32 in [0, 1, 4, 8, 3, 6, 10] {
            XCTAssertFalse(FinderMenuCommand.Command.move.matches(character: "v", modifiers: modifiers))
        }
        XCTAssertFalse(FinderMenuCommand.Command.move.matches(character: "c", modifiers: 2))
        XCTAssertFalse(FinderMenuCommand.Command.copy.matches(character: "c", modifiers: nil))
    }
}
