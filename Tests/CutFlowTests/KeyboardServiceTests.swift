import AppKit
import XCTest
@testable import CutFlow

/// Exercises the production CGEvent handler. Events are never posted, the
/// system pasteboard is never read/written, and no Accessibility grant is needed.
final class KeyboardServiceTests: XCTestCase {
    private var board: NSPasteboard!
    private var service: KeyboardService!
    private var owner: String? = "com.apple.finder"
    private var editable = false
    private var now: TimeInterval = 0
    private let files = [URL(fileURLWithPath: "/tmp/cutflow-test/中文 file.txt"),
                         URL(fileURLWithPath: "/tmp/cutflow-test/folder", isDirectory: true)]

    override func setUp() {
        super.setUp()
        owner = "com.apple.finder"; editable = false; now = 0
        board = NSPasteboard.withUniqueName()
        service = KeyboardService(pasteboard: board, currentApplication: { [unowned self] in
            owner.map { .init(bundleID: $0, pid: 1) }
        }, fileContext: { [unowned self] _ in !editable }, uptime: { [unowned self] in now })
    }

    override func tearDown() {
        service.stop(); service = nil
        board.releaseGlobally(); board = nil
        super.tearDown()
    }

    private func key(_ code: CGKeyCode, up: Bool = false, flags: CGEventFlags = .maskCommand,
                     repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: !up)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    @discardableResult private func send(_ event: CGEvent) -> CGEvent? {
        service.handle(type: event.type, event: event)?.takeUnretainedValue()
    }

    private func writeFiles() {
        board.clearContents()
        XCTAssertTrue(board.writeObjects(files.map { $0 as NSURL }))
    }

    private func arm() {
        send(key(7)); send(key(7, up: true))
        writeFiles(); service.refreshClipboard()
        XCTAssertTrue(service.session.canMove(changeCount: board.changeCount, owner: owner!))
    }

    func testCutRemapsDownAndUpEvenAfterFocusAndModifiersChange() {
        let down = key(7)
        var text = Array("stale".utf16)
        down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: &text)
        XCTAssertNotNil(send(down))
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), 8)
        var length = 0
        var actual = [UniChar](repeating: 0, count: 16)
        down.keyboardGetUnicodeString(maxStringLength: actual.count, actualStringLength: &length, unicodeString: &actual)
        XCTAssertEqual(String(utf16CodeUnits: actual, count: length), "c")
        owner = "com.apple.TextEdit"
        let up = key(7, up: true, flags: [])
        send(up)
        XCTAssertEqual(up.getIntegerValueField(.keyboardEventKeycode), 8)
    }

    func testMultiFileCaptureAndMoveClearVisualState() {
        arm()
        XCTAssertEqual(service.cutFileURLs, files)
        let down = key(9); send(down)
        XCTAssertTrue(down.flags.contains(.maskAlternate))
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        let up = key(9, up: true, flags: [])
        send(up)
        XCTAssertTrue(up.flags.contains(.maskAlternate))
        let second = key(9); send(second)
        XCTAssertFalse(second.flags.contains(.maskAlternate))
    }

    func testHeldMoveCannotRepeatAsCopy() {
        arm(); send(key(9))
        XCTAssertNil(send(key(9, repeatKey: true)))
        send(key(9, up: true))
        XCTAssertNotNil(send(key(9)))
    }

    func testEarlyPasteMustBeReleasedBeforeMoveCanOccur() {
        send(key(7)); send(key(7, up: true))
        XCTAssertNil(send(key(9)))
        writeFiles(); service.refreshClipboard()
        XCTAssertNil(send(key(9, repeatKey: true)))
        XCTAssertFalse(service.cutFileURLs.isEmpty)
        XCTAssertNil(send(key(9, up: true)))
        let retry = key(9); send(retry)
        XCTAssertTrue(retry.flags.contains(.maskAlternate))
    }

    func testEarlyPasteAfterTimeoutDoesNotPasteOldClipboardOnRepeat() {
        writeFiles(); send(key(7)); send(key(7, up: true))
        XCTAssertNil(send(key(9)))
        now = 2; service.refreshClipboard()
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertNil(send(key(9, repeatKey: true)))
        XCTAssertNil(send(key(9, up: true)))
        let retry = key(9); XCTAssertNotNil(send(retry))
        XCTAssertFalse(retry.flags.contains(.maskAlternate))
    }

    func testHeldCutDoesNotRestartCapture() {
        send(key(7)); writeFiles(); service.refreshClipboard()
        XCTAssertNil(send(key(7, repeatKey: true)))
        XCTAssertFalse(service.cutFileURLs.isEmpty)
    }

    func testOrdinaryPasteAndModifiedShortcutsStayUnchanged() {
        for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskShift],
                                   [.maskCommand, .maskControl], [.maskCommand, .maskSecondaryFn], []] {
            let event = key(9, flags: flags); send(event)
            XCTAssertEqual(event.flags, flags)
        }
        for flags: CGEventFlags in [[.maskCommand, .maskShift], [.maskCommand, .maskAlternate], []] {
            let event = key(7, flags: flags); send(event)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 7)
            XCTAssertEqual(service.session.state, .idle)
        }
    }

    func testTextEditingKeepsCutAndPasteAndDoesNotConsumeMove() {
        editable = true
        let textCut = key(7); send(textCut)
        XCTAssertEqual(textCut.getIntegerValueField(.keyboardEventKeycode), 7)
        editable = false; arm(); editable = true
        let textPaste = key(9); send(textPaste)
        XCTAssertFalse(textPaste.flags.contains(.maskAlternate))
        XCTAssertFalse(service.cutFileURLs.isEmpty)
    }

    func testCompatibilityModeBypassesOnlyTextProtection() {
        editable = true; service.protectText = false
        let cut = key(7); send(cut)
        XCTAssertEqual(cut.getIntegerValueField(.keyboardEventKeycode), 8)
        owner = "com.apple.TextEdit"
        let outside = key(7); send(outside)
        XCTAssertEqual(outside.getIntegerValueField(.keyboardEventKeycode), 7)
    }

    func testCopyInOtherAppCancelsEvenWhenClipboardUnchanged() {
        arm(); owner = "com.apple.TextEdit"
        let before = board.changeCount
        send(key(8))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
    }

    func testEscapeCancelsButDoesNotDestroyClipboard() {
        arm(); let before = board.changeCount
        XCTAssertNotNil(send(key(53, flags: [])))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(service.session.state, .idle)
    }

    func testClipboardReplacementBeforePollNeverMoves() {
        arm(); board.clearContents(); board.setString("text", forType: .string)
        let paste = key(9); send(paste)
        XCTAssertFalse(paste.flags.contains(.maskAlternate))
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
    }

    func testNativeMoveConsumesPendingStateWithoutRewriting() {
        arm(); let event = key(9, flags: [.maskCommand, .maskAlternate])
        send(event)
        XCTAssertEqual(event.flags, [.maskCommand, .maskAlternate])
        XCTAssertEqual(service.session.state, .idle)
    }

    func testPauseAndStopClearPendingState() {
        arm(); service.enabled = false
        XCTAssertEqual(service.session.state, .idle)
        let event = key(7); send(event)
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 7)
        service.enabled = true; arm(); service.stop()
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
    }

    func testUnsupportedAppAndMissingFrontmostAppDoNotIntercept() {
        for app: String? in [nil, "com.apple.TextEdit", "com.apple.finder.spoof"] {
            owner = app
            let event = key(7); send(event)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 7)
            XCTAssertEqual(service.session.state, .idle)
        }
    }

    func testForkLiftRequiresEnabledSupportAndDoesNotCreateFinderOverlay() {
        owner = "com.binarynights.ForkLift"
        service.forkLift = false
        let ignored = key(7); send(ignored)
        XCTAssertEqual(ignored.getIntegerValueField(.keyboardEventKeycode), 7)
        service.forkLift = true; arm()
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        let move = key(9); send(move)
        XCTAssertTrue(move.flags.contains(.maskAlternate))
    }

    func testCrossManagerPasteDoesNotConsumeSourceMove() {
        arm(); owner = "com.binarynights.ForkLift"
        let event = key(9); send(event)
        XCTAssertFalse(event.flags.contains(.maskAlternate))
        owner = "com.apple.finder"
        let sourcePaste = key(9); send(sourcePaste)
        XCTAssertTrue(sourcePaste.flags.contains(.maskAlternate))
    }

    func testTapFailureClearsMoveIntent() {
        arm()
        _ = service.handle(type: .tapDisabledByTimeout, event: key(9))
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
    }

    func testMouseAndScrollOnlySuspendVisualsAndKeepMoveIntent() {
        var interruptions = 0
        service.onVisualInterruption = { interruptions += 1 }
        arm()
        for type: CGEventType in [.scrollWheel, .leftMouseDown, .leftMouseDragged, .rightMouseDown] {
            _ = service.handle(type: type, event: key(9))
        }
        XCTAssertEqual(interruptions, 4)
        XCTAssertTrue(service.session.canMove(changeCount: board.changeCount, owner: owner!))
    }
}
