import AppKit
import ApplicationServices
import CutFlowCore

final class KeyboardService {
    struct ApplicationContext {
        let bundleID: String
        let pid: pid_t
    }
    private let pasteboard: NSPasteboard
    private let currentApplication: () -> ApplicationContext?
    private let fileContext: (pid_t) -> Bool
    private let uptime: () -> TimeInterval
    private let finderCommand: FinderMenuCommand.Executor?
    private let scheduleCommand: (@escaping () -> Void) -> Void
    private let finderDestination: (pid_t, [URL]) -> FinderPasteDestination.Decision
    private let finderContextMove: FinderContextMenu.Executor

    // These boundaries allow the actual event handler to be tested with an
    // isolated pasteboard, without installing a tap or posting keyboard input.
    init(pasteboard: NSPasteboard = .general,
         currentApplication: @escaping () -> ApplicationContext? = {
             guard let app = NSWorkspace.shared.frontmostApplication,
                   let id = app.bundleIdentifier else { return nil }
             return ApplicationContext(bundleID: id, pid: app.processIdentifier)
         }, fileContext: ((pid_t) -> Bool)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         finderCommand: FinderMenuCommand.Executor? = FinderMenuCommand.perform,
         scheduleCommand: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         finderDestination: @escaping (pid_t, [URL]) -> FinderPasteDestination.Decision = FinderPasteDestination.read,
         finderContextMove: @escaping FinderContextMenu.Executor = FinderContextMenu.perform) {
        self.pasteboard = pasteboard
        self.currentApplication = currentApplication
        self.fileContext = fileContext ?? Self.isFileContext
        self.uptime = uptime
        self.finderCommand = finderCommand
        self.scheduleCommand = scheduleCommand
        self.finderDestination = finderDestination
        self.finderContextMove = finderContextMove
    }
    var onChange: (() -> Void)?
    var onCutFilesChanged: (([URL]) -> Void)?
    var onVisualInterruption: (() -> Void)?
    private(set) var cutFileURLs: [URL] = []
    var enabled = true { didSet { if !enabled { cancel() } } }
    var forkLift = true
    var protectText = true
    private(set) var running = false
    private(set) var session = CutSession()
    // Only counters and cut/paste outcomes; never retain typed text or file paths.
    private(set) var receivedKeyDownCount = 0
    private(set) var shortcutHistory: [String] = []
    private(set) var lastFailure: String?
    private var commandGeneration = 0
    private var pendingFinderCommand: FinderMenuCommand.Command?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var forwardingTap: CFMachPort?
    private var forwardingSource: CFRunLoopSource?
    private static let replacementMarker: Int64 = 0x435554464C4F57
    private var poll: Timer?
    // Keep key-down and key-up consistent, even after focus/modifiers change.
    private var mappedKeys: [Int64: (key: Int64, option: Bool)] = [:]
    private var suppressedKeys: Set<Int64> = []
    private let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]

    var tapIsActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private func record(_ message: String) {
        shortcutHistory.append(message)
        if shortcutHistory.count > 8 { shortcutHistory.removeFirst(shortcutHistory.count - 8) }
    }

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
                guard let output = service.handle(type: type, event: event) else { return nil }
                // Quartz releases replacement events after forwarding them. The
                // incoming event already belongs to Quartz; do not retain it again.
                return output === event ? Unmanaged.passUnretained(output) : Unmanaged.passRetained(output)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { running = false; onChange?(); return }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        running = CGEvent.tapIsEnabled(tap: newTap)
        startForwardingCheck()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.refreshClipboard() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        onChange?()
    }

    func stop() {
        poll?.invalidate(); poll = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let forwardingSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), forwardingSource, .commonModes) }
        if let forwardingTap { CFMachPortInvalidate(forwardingTap) }
        forwardingSource = nil; forwardingTap = nil
        source = nil; tap = nil; running = false
        mappedKeys.removeAll()
        suppressedKeys.removeAll()
        cancel()
    }

    func cancel() {
        commandGeneration += 1
        pendingFinderCommand = nil
        lastFailure = nil
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
        let board = pasteboard
        var files: [URL] = []
        if case let .awaitingCopy(baseline, _, _) = session.state, board.changeCount != baseline {
            files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
        }
        let owner = currentApplication()?.bundleID
        let now = uptime()
        session.observe(changeCount: board.changeCount, fileCount: files.count,
                        frontmostOwner: owner, now: now)
        if session.state != old {
            if case let .awaitingCopy(baseline, expectedOwner, deadline) = old {
                if case let .ready(_, _, count) = session.state {
                    record("剪切成功：已获取 \(count) 个文件")
                } else if owner != expectedOwner {
                    lastFailure = "复制完成前切换了应用，请回到 Finder 重新按 ⌘X。"
                    record("剪切取消：复制完成前切换了应用")
                } else if now > deadline && board.changeCount == baseline {
                    lastFailure = "Finder 未更新文件剪贴板（复制超时），请查看下方诊断。"
                    record("剪切失败：Finder 未更新剪贴板（复制超时）")
                } else {
                    lastFailure = "剪贴板未产生可移动的文件，请选中文件后重新按 ⌘X。"
                    record("剪切失败：剪贴板未产生可移动的文件")
                }
            } else if case .idle = session.state {
                record("剪切取消：剪贴板已被替换")
            }
            if case let .ready(_, owner, _) = session.state, owner == "com.apple.finder" {
                updateCutFiles(files)
            } else { updateCutFiles([]) }
            onChange?()
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == FinderContextMenu.eventMarker { return event }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            record(type == .tapDisabledByTimeout ? "系统暂停了监听：处理超时，已重试" : "系统暂停了监听：已重试")
            cancel()
            mappedKeys.removeAll()
            suppressedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        if type == .scrollWheel || type == .leftMouseDown || type == .leftMouseDragged || type == .rightMouseDown {
            if pendingFinderCommand != nil { fail("执行前选择或窗口发生变化，请重新操作。") }
            if !cutFileURLs.isEmpty { onVisualInterruption?() }
            return event
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if suppressedKeys.remove(key) != nil { return nil }
            if let mapping = mappedKeys.removeValue(forKey: key) { return remap(event, mapping.key, mapping.option) }
            return event
        }
        guard type == .keyDown else { return event }
        receivedKeyDownCount += 1
        // A paste rejected while copying stays rejected until V is released.
        // Otherwise its first repeat could move as soon as the copy completes.
        if suppressedKeys.contains(key) { return nil }
        if pendingFinderCommand == .move {
            if key == 9, event.flags.intersection(modifiers) == .maskCommand {
                suppressedKeys.insert(key)
                return nil
            }
            fail("准备移动期间收到新的键盘操作，已取消移动。")
        }
        // Swallow repeated cut/move presses so holding V cannot move then copy again.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0, mappedKeys[key] != nil { return nil }
        let flags = event.flags.intersection(modifiers)
        let app = currentApplication()
        if flags.contains(.maskCommand), key == 7 || key == 9 {
            let command = key == 7 ? "⌘X" : "⌘V"
            if !enabled { record("\(command)：快捷键已暂停") }
            else if let app, ShortcutPolicy.supports(app.bundleID, forkLift: forkLift) {
                record("收到 \(command)：\(app.bundleID)\(flags == .maskCommand ? "" : "（包含额外修饰键）")")
            } else { record("\(command)：前台应用为 \(app?.bundleID ?? "未知")，保留原快捷键") }
        }
        // A fresh copy/cut in any app cancels the old move intent, including an empty copy.
        if flags == .maskCommand && (key == 8 || key == 7) { cancel() }
        if key == 53 { cancel() }
        guard enabled, let app,
              ShortcutPolicy.supports(app.bundleID, forkLift: forkLift)
        else { return event }
        let owner = app.bundleID

        if key == 9 && flags == [.maskCommand, .maskAlternate] {
            // Respect a manually invoked native move; do not retain a second pending move.
            cancel()
            return event
        }
        guard flags == .maskCommand, key == 7 || key == 9 else { return event }
        if protectText && !fileContext(app.pid) {
            record("保留原快捷键：文字编辑保护未确认文件焦点")
            return event
        }

        if key == 7 {
            if owner == "com.apple.finder", finderCommand != nil {
                session.begin(changeCount: pasteboard.changeCount, owner: owner, now: uptime())
                suppressedKeys.insert(key)
                queueFinderCommand(.copy, app: app)
                return nil
            }
            guard let copy = remap(event, 8, false) else {
                record("剪切失败：无法创建复制事件")
                return nil
            }
            session.begin(changeCount: pasteboard.changeCount, owner: owner, now: uptime())
            mappedKeys[key] = (8, false)
            record("已将 ⌘X 转为复制，等待文件剪贴板")
            onChange?()
            return copy // X → C; Finder remains responsible for copying.
        } else {
            refreshClipboard()
            // Do not paste an older clipboard if the user presses V before Finder
            // has completed the copy. A new press after capture performs the move.
            if case .awaitingCopy = session.state { suppressedKeys.insert(key); return nil }
            if pendingFinderCommand != nil { suppressedKeys.insert(key); return nil }
            if owner == "com.apple.finder", finderCommand != nil,
               session.canMove(changeCount: pasteboard.changeCount, owner: owner) {
                suppressedKeys.insert(key)
                queueFinderCommand(.move, app: app)
                return nil
            }
            if session.consumeMove(changeCount: pasteboard.changeCount, owner: owner) {
                updateCutFiles([])
                guard let move = remap(event, 9, true) else {
                    record("移动取消：无法创建移动事件")
                    onChange?()
                    return nil
                }
                mappedKeys[key] = (9, true)
                record("已将 ⌘V 转为系统移动")
                onChange?()
                return move // V → Option-V; Finder owns conflicts, undo, and transfer.
            }
        }
        return event
    }

    private func fail(_ detail: String) {
        cancel()
        lastFailure = detail
        record("操作未完成：\(detail)")
        onChange?()
    }

    private func queueFinderCommand(_ command: FinderMenuCommand.Command, app: ApplicationContext) {
        pendingFinderCommand = command
        let generation = commandGeneration
        let baseline = pasteboard.changeCount
        record("正在调用 Finder 的\(command.name)菜单命令")
        onChange?()
        // Return from the event tap before asking Finder to run an AX action.
        // Otherwise Finder may be waiting for the very key event we intercepted.
        scheduleCommand { [weak self] in
            guard let self, generation == self.commandGeneration, let execute = self.finderCommand else { return }
            let baseValid = {
                guard generation == self.commandGeneration, self.enabled,
                      let front = self.currentApplication(), front.pid == app.pid, front.bundleID == app.bundleID,
                      self.pasteboard.changeCount == baseline else { return false }
                if command == .move { return self.session.canMove(changeCount: baseline, owner: app.bundleID) }
                guard case let .awaitingCopy(_, _, deadline) = self.session.state else { return false }
                return self.uptime() <= deadline
            }
            let valid = { baseValid() && (!self.protectText || self.fileContext(app.pid)) }
            guard valid() else { self.fail("执行前焦点或剪贴板已变化，请重新按 ⌘X。"); return }
            if command == .move {
                switch self.finderDestination(app.pid, self.cutFileURLs) {
                case .currentDirectory:
                    self.finishFinderCommand(command, generation: generation,
                        result: execute(command, app.pid, {
                            valid() && self.finderDestination(app.pid, self.cutFileURLs) == .currentDirectory
                        }))
                case let .unavailable(reason): self.fail(reason)
                case let .folder(folder):
                    self.record("正在原地移动到选中文件夹")
                    self.finderContextMove(app.pid, {
                        valid() && self.finderDestination(app.pid, self.cutFileURLs) == .folder(folder)
                    }, {
                        // Finder's context menu takes focus and can obscure
                        // AX selection. Preserve the snapshot checked above,
                        // while still rejecting changes to the cut session,
                        // clipboard or frontmost application.
                        baseValid()
                    }, { [weak self] result in
                        self?.finishFinderCommand(.move, generation: generation, result: result)
                    })
                }
                return
            }
            let result = execute(command, app.pid, valid)
            self.finishFinderCommand(command, generation: generation, result: result)
        }
    }

    private func finishFinderCommand(_ command: FinderMenuCommand.Command, generation: Int,
                                     result: FinderMenuCommand.Outcome) {
        guard generation == commandGeneration else { return }
        pendingFinderCommand = nil
        switch result {
            case .performed:
                self.record("Finder 已接受\(command.name)菜单命令")
                if command == .move {
                    // Finder may update the pasteboard synchronously during the
                    // move. Acceptance consumes the intent regardless of that.
                    self.session.cancel()
                    self.updateCutFiles([])
                } else { self.refreshClipboard() }
                self.onChange?()
            case let .failed(detail): self.fail(detail)
        }
    }

    private func remap(_ event: CGEvent, _ key: Int64, _ option: Bool) -> CGEvent? {
        // Mutating a received event leaves AppKit's cached characters and
        // charactersIgnoringModifiers untouched, even after setting its Unicode
        // string. Build a fresh event so Finder receives C, not an X with a C keycode.
        var flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if option { flags.insert(.option) }
        let character = key == 8 ? "c" : "v"
        // Construct AppKit's shortcut character fields directly instead of
        // relying on a Quartz Unicode text override to update them.
        guard let native = NSEvent.keyEvent(with: event.type == .keyDown ? .keyDown : .keyUp,
            location: .zero, modifierFlags: flags, timestamp: Double(event.timestamp) / 1_000_000_000,
            windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: UInt16(key)), let replacement = native.cgEvent else { return nil }
        replacement.timestamp = event.timestamp
        replacement.location = event.location
        replacement.setIntegerValueField(.eventSourceUserData, value: Self.replacementMarker)
        return replacement
    }

    private func startForwardingCheck() {
        // Observe only our marked replacement events at the later annotated
        // stage. This separates event creation from actual stream forwarding.
        guard let port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: { _, type, event, context in
                guard type == .keyDown, let context,
                      event.getIntegerValueField(.eventSourceUserData) == KeyboardService.replacementMarker
                else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<KeyboardService>.fromOpaque(context).takeUnretainedValue()
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                let expected = key == 8 ? "c" : "v"
                let consistent = NSEvent(cgEvent: event)?.charactersIgnoringModifiers == expected
                service.record("转发检查：\(key == 8 ? "复制" : "粘贴")事件已进入后续阶段，字符\(consistent ? "一致" : "不一致")")
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                record("转发检查不可用；主快捷键监听仍可运行")
                return
            }
        forwardingTap = port
        forwardingSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), forwardingSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private static func isFileContext(_ pid: pid_t) -> Bool {
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
