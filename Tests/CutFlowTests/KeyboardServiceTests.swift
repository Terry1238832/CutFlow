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
        }, fileContext: { [unowned self] _ in !editable }, uptime: { [unowned self] in now }, finderCommand: nil)
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
        service.handle(type: event.type, event: event)
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
        let translated = send(down)!
        XCTAssertFalse(translated === down)
        XCTAssertEqual(translated.getIntegerValueField(.keyboardEventKeycode), 8)
        var length = 0
        var actual = [UniChar](repeating: 0, count: 16)
        translated.keyboardGetUnicodeString(maxStringLength: actual.count, actualStringLength: &length, unicodeString: &actual)
        XCTAssertNotEqual(String(utf16CodeUnits: actual, count: length), "stale")
        XCTAssertEqual(NSEvent(cgEvent: translated)?.charactersIgnoringModifiers, "c")
        owner = "com.apple.TextEdit"
        let up = key(7, up: true, flags: [])
        let translatedUp = send(up)!
        XCTAssertEqual(translatedUp.getIntegerValueField(.keyboardEventKeycode), 8)
    }

    func testAppKitShortcutPayloadAlsoBecomesCopy() {
        let original = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 1, windowNumber: 0, context: nil,
            characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
        let translated = send(original.cgEvent!)!
        let delivered = NSEvent(cgEvent: translated)!
        XCTAssertEqual(delivered.keyCode, 8)
        XCTAssertEqual(delivered.characters, "c")
        XCTAssertEqual(delivered.charactersIgnoringModifiers, "c")
        XCTAssertEqual(original.charactersIgnoringModifiers, "x")
    }

    func testAppKitPasteBecomesOptionPasteIncludingRelease() {
        arm()
        for (type, flags) in [(NSEvent.EventType.keyDown, NSEvent.ModifierFlags.command),
                              (.keyUp, NSEvent.ModifierFlags())] {
            let original = NSEvent.keyEvent(with: type, location: .zero,
                modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            let delivered = NSEvent(cgEvent: send(original.cgEvent!)!)!
            XCTAssertEqual(delivered.type, type)
            XCTAssertEqual(delivered.keyCode, 9)
            XCTAssertEqual(delivered.charactersIgnoringModifiers, "v")
            XCTAssertTrue(delivered.modifierFlags.contains(.option))
            XCTAssertEqual(delivered.modifierFlags.contains(.command), flags.contains(.command))
        }
    }

    func testMultiFileCaptureAndMoveClearVisualState() {
        arm()
        XCTAssertEqual(service.cutFileURLs, files)
        let down = send(key(9))!
        XCTAssertTrue(down.flags.contains(.maskAlternate))
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
        let up = send(key(9, up: true, flags: []))!
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
        let retry = send(key(9))!
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
        let cut = send(key(7))!
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
        let move = send(key(9))!
        XCTAssertTrue(move.flags.contains(.maskAlternate))
    }

    func testCrossManagerPasteDoesNotConsumeSourceMove() {
        arm(); owner = "com.binarynights.ForkLift"
        let event = key(9); send(event)
        XCTAssertFalse(event.flags.contains(.maskAlternate))
        owner = "com.apple.finder"
        let sourcePaste = send(key(9))!
        XCTAssertTrue(sourcePaste.flags.contains(.maskAlternate))
    }

    func testTapFailureClearsMoveIntent() {
        arm()
        _ = service.handle(type: .tapDisabledByTimeout, event: key(9))
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertTrue(service.cutFileURLs.isEmpty)
    }

    func testCopyTimeoutLeavesADiagnosticInsteadOfOnlyReturningToIdle() {
        send(key(7)); send(key(7, up: true))
        now = 2
        service.refreshClipboard()
        XCTAssertEqual(service.session.state, .idle)
        XCTAssertEqual(service.receivedKeyDownCount, 1)
        XCTAssertTrue(service.shortcutHistory.last?.contains("复制超时") == true)
    }

    func testTextProtectionAndFocusChangeHaveDistinctDiagnostics() {
        editable = true
        send(key(7))
        XCTAssertTrue(service.shortcutHistory.last?.contains("文字编辑保护") == true)
        editable = false
        send(key(7)); send(key(7, up: true))
        owner = "com.apple.TextEdit"
        service.refreshClipboard()
        XCTAssertTrue(service.shortcutHistory.last?.contains("切换了应用") == true)
    }

    func testDiagnosticHistoryIsBoundedAndDoesNotRetainClipboardContent() {
        for _ in 0..<10 {
            send(key(7)); send(key(7, up: true))
            board.clearContents(); board.setString("private clipboard content", forType: .string)
            service.refreshClipboard()
        }
        XCTAssertEqual(service.shortcutHistory.count, 8)
        XCTAssertFalse(service.shortcutHistory.joined().contains("private clipboard content"))
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
