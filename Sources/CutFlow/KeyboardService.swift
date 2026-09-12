import AppKit
import ApplicationServices
import CutFlowCore

final class KeyboardService {
    var onChange: (() -> Void)?
    var onCutFilesChanged: (([URL]) -> Void)?
    var onVisualInterruption: (() -> Void)?
    private(set) var cutFileURLs: [URL] = []
    var enabled = true { didSet { if !enabled { cancel() } } }
    var forkLift = true
    var protectText = true
    private(set) var running = false
    private(set) var session = CutSession()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var poll: Timer?
    // Keep key-down and key-up consistent, even after focus/modifiers change.
    private var mappedKeys: [Int64: (key: Int64, option: Bool)] = [:]
    private let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]

    var tapIsActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            running = CGEvent.tapIsEnabled(tap: tap)
            return
        }
        // macOS itself decides whether this active event tap is authorized.
        // Do not reject a real attempt based only on a cached AX trust flag.
        let types: [CGEventType] = [.keyDown, .keyUp, .scrollWheel, .leftMouseDown, .leftMouseDragged, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<KeyboardService>.fromOpaque(context).takeUnretainedValue()
                return service.handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { running = false; onChange?(); return }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        running = CGEvent.tapIsEnabled(tap: newTap)
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.refreshClipboard() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        onChange?()
    }

    func stop() {
        poll?.invalidate(); poll = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; running = false
        mappedKeys.removeAll()
        cancel()
    }

    func cancel() {
        session.cancel()
        updateCutFiles([])
        onChange?()
    }

    private func updateCutFiles(_ urls: [URL]) {
        guard cutFileURLs != urls else { return }
        cutFileURLs = urls
        onCutFilesChanged?(urls)
    }

    func refreshClipboard() {
        guard session.state != .idle else { return }
        let old = session.state
        let board = NSPasteboard.general
        var files: [URL] = []
        if case let .awaitingCopy(baseline, _, _) = session.state, board.changeCount != baseline {
            files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
        }
        session.observe(changeCount: board.changeCount, fileCount: files.count,
                        frontmostOwner: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                        now: ProcessInfo.processInfo.systemUptime)
        if session.state != old {
            if case let .ready(_, owner, _) = session.state, owner == "com.apple.finder" {
                updateCutFiles(files)
            } else { updateCutFiles([]) }
            onChange?()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            mappedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .scrollWheel || type == .leftMouseDown || type == .leftMouseDragged || type == .rightMouseDown {
            if !cutFileURLs.isEmpty { onVisualInterruption?() }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if let mapping = mappedKeys.removeValue(forKey: key) { remap(event, mapping.key, mapping.option) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        // Swallow repeated cut/move presses so holding V cannot move then copy again.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0, mappedKeys[key] != nil { return nil }
        let flags = event.flags.intersection(modifiers)
        // A fresh copy/cut in any app cancels the old move intent, including an empty copy.
        if flags == .maskCommand && (key == 8 || key == 7) { cancel() }
        if key == 53 { cancel() }
        guard enabled, let app = NSWorkspace.shared.frontmostApplication,
              let owner = app.bundleIdentifier, ShortcutPolicy.supports(owner, forkLift: forkLift)
        else { return Unmanaged.passUnretained(event) }

        if key == 9 && flags == [.maskCommand, .maskAlternate] {
            // Respect a manually invoked native move; do not retain a second pending move.
            cancel()
            return Unmanaged.passUnretained(event)
        }
        guard flags == .maskCommand, key == 7 || key == 9 else { return Unmanaged.passUnretained(event) }
        if protectText && !isFileContext(pid: app.processIdentifier) { return Unmanaged.passUnretained(event) }

        if key == 7 {
            session.begin(changeCount: NSPasteboard.general.changeCount, owner: owner,
                          now: ProcessInfo.processInfo.systemUptime)
            mappedKeys[key] = (8, false)
            remap(event, 8, false) // X → C; Finder remains responsible for copying.
            onChange?()
        } else {
            refreshClipboard()
            // Do not paste an older clipboard if the user presses V before Finder
            // has completed the copy. A new press after capture performs the move.
            if case .awaitingCopy = session.state { return nil }
            if session.consumeMove(changeCount: NSPasteboard.general.changeCount, owner: owner) {
                updateCutFiles([])
                mappedKeys[key] = (9, true)
                remap(event, 9, true) // V → Option-V; Finder owns conflicts, undo, and transfer.
                onChange?()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func remap(_ event: CGEvent, _ key: Int64, _ option: Bool) {
        event.setIntegerValueField(.keyboardEventKeycode, value: key)
        if option { event.flags.insert(.maskAlternate) }
        // Clear cached characters after changing the physical key code.
        event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
    }

    private func isFileContext(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        if ShortcutPolicy.isTextRole(role) { return false }
        var editable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable) == .success,
           editable.boolValue { return false }
        return true
    }
}
