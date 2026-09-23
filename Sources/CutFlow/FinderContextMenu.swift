import AppKit
import ApplicationServices

/// Finder's file-item context menu targets the selected folder. Its toolbar
/// and Edit menus target the open directory, even with a folder selected.
enum FinderContextMenu {
    typealias Executor = (pid_t, @escaping () -> Bool, @escaping () -> Bool,
                          @escaping (FinderMenuCommand.Outcome) -> Void) -> Void
    static let eventMarker: Int64 = 0x435546435458

    static func isMoveItem(identifier: String?, enabled: Bool) -> Bool {
        identifier == "cmdMoveItemsHere:" && enabled
    }

    static func canOpenMenu(physicalFlags: CGEventFlags) -> Bool {
        !physicalFlags.contains(.maskCommand)
    }

    static func menuKey(down: Bool) -> CGEvent? {
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
            location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)?.cgEvent else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        return event
    }

    static func dismissKey(down: Bool) -> CGEvent? {
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
            location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)?.cgEvent else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        return event
    }

    static func perform(pid: pid_t, preflight: @escaping () -> Bool,
                        transactionValid: @escaping () -> Bool,
                        completion: @escaping (FinderMenuCommand.Outcome) -> Void) {
        let releaseDeadline = ProcessInfo.processInfo.systemUptime + 1.5
        func waitForCommandRelease() {
            guard preflight() else {
                completion(.failed("松开 ⌘ 前目标选择或剪贴板已变化，未执行移动。")); return
            }
            // The intercepted ⌘V key-down runs before the user's Command
            // key-up. Opening the context menu with Command physically held
            // can make Finder omit its Paste/Move items.
            guard canOpenMenu(physicalFlags: CGEventSource.flagsState(.hidSystemState)) else {
                guard ProcessInfo.processInfo.systemUptime <= releaseDeadline else {
                    completion(.failed("等待 ⌘ 松开超时，未执行移动。")); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: waitForCommandRelease)
                return
            }
            performAfterRelease(pid: pid, preflight: preflight,
                                transactionValid: transactionValid, completion: completion)
        }
        waitForCommandRelease()
    }

    private static func performAfterRelease(pid: pid_t, preflight: @escaping () -> Bool,
                                            transactionValid: @escaping () -> Bool,
                                            completion: @escaping (FinderMenuCommand.Outcome) -> Void) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        guard preflight(), let window = element(value(app, kAXFocusedWindowAttribute)),
              let view = fileView(window), let focus = element(value(app, kAXFocusedUIElementAttribute)) else {
            completion(.failed("无法确认 Finder 的文件视图，未执行移动。")); return
        }
        guard contextMenu(view) == nil else {
            completion(.failed("请先关闭 Finder 中已打开的快捷菜单，再按 ⌘V。")); return
        }
        // Once Finder opens a native menu, AXFocusedWindow may briefly be nil
        // or refer to the menu itself. The verified file-view element remains
        // tied to the original window. Input and clipboard changes invalidate
        // the transaction in KeyboardService, so do not re-read menu focus.
        let valid = transactionValid
        guard preflight() else {
            completion(.failed("执行前目标选择已变化，未执行移动。")); return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        var shownMenu: AXUIElement?
        func finish(_ result: FinderMenuCommand.Outcome) {
            if case .failed = result, let shownMenu {
                // Cancel only the menu we located, never send a global Escape.
                let cancelled = AXUIElementPerformAction(shownMenu, kAXCancelAction as CFString)
                if cancelled != .success, valid(),
                   let down = dismissKey(down: true), let up = dismissKey(down: false) {
                    // Finder does not always expose AXCancel on its file menu.
                    // These tagged events go only to the original Finder PID.
                    down.postToPid(pid)
                    up.postToPid(pid)
                }
            }
            completion(result)
        }
        func poll() {
            guard valid() else { finish(.failed("剪贴板、应用或剪切状态已变化，已取消移动。")); return }
            guard ProcessInfo.processInfo.systemUptime <= deadline else {
                finish(.failed(shownMenu == nil
                    ? "未能打开文件夹快捷菜单。请打开目标文件夹后再粘贴。"
                    : "Finder 菜单没有可用的移动命令。请先对文件按 ⌘X，再选中文件夹按 ⌘V。"))
                return
            }
            if let menu = contextMenu(view) {
                shownMenu = menu
                // Direct children only: never execute Services or plug-in items.
                let items = children(menu).prefix(100)
                if let move = items.first(where: {
                    isMoveItem(identifier: value($0, kAXIdentifierAttribute) as? String,
                               enabled: (value($0, kAXEnabledAttribute) as? Bool) == true)
                }) {
                    guard valid() else { finish(.failed("执行前目标已变化，未执行移动。")); return }
                    let result = AXUIElementPerformAction(move, kAXPressAction as CFString)
                    finish(result == .success ? .performed : .failed("Finder 拒绝文件夹移动命令（\(result.rawValue)）。"))
                    return
                }
                // Finder can publish the menu before its commands become
                // available. Allow the bounded poll to observe the final menu.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: poll)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: poll)
        }
        var actions: CFArray?
        AXUIElementCopyActionNames(focus, &actions)
        if (actions as? [String] ?? []).contains(kAXShowMenuAction) {
            guard valid() else { finish(.failed("执行前选择已变化。")); return }
            let result = AXUIElementPerformAction(focus, kAXShowMenuAction as CFString)
            guard result == .success || result == .cannotComplete else {
                finish(.failed("Finder 无法显示文件夹快捷菜单（\(result.rawValue)）。")); return
            }
        } else {
            // macOS 15 added Control-Return for the selected item's context
            // menu. Post only to Finder, after the original V tap has returned.
            guard #available(macOS 15, *), let down = menuKey(down: true), let up = menuKey(down: false), valid() else {
                finish(.failed("当前系统未提供原地粘贴菜单，请打开目标文件夹后再粘贴。")); return
            }
            down.postToPid(pid)
            up.postToPid(pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: poll)
    }

    private static func fileView(_ window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while index < queue.count, index < 100, ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[index]; index += 1
            if FinderFileView(identifier: value(node, kAXIdentifierAttribute) as? String ?? "") != nil { return node }
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            if ["AXToolbar", "AXMenuBar", "AXMenu", "AXOutline"].contains(role) { continue }
            queue += children(node).prefix(max(0, 100 - queue.count))
        }
        return nil
    }

    private static func contextMenu(_ view: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(view, 0)]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while index < queue.count, index < 120, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = queue[index]; index += 1
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            if role == kAXMenuRole { return node }
            if depth >= 4 || ["AXRow", "AXCell", "AXImage", "AXTextField", "AXToolbar"].contains(role) { continue }
            // Finder appends the contextual menu after its file items. Start
            // from that end so large directories cannot hide the menu behind
            // hundreds of filename rows.
            queue += children(node).reversed().prefix(max(0, 120 - queue.count)).map { ($0, depth + 1) }
        }
        return nil
    }

    private static func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.035)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        (value(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
