import AppKit
import ApplicationServices

/// Finder's file-item context menu targets the selected folder. Its toolbar
/// and Edit menus target the open directory, even with a folder selected.
enum FinderContextMenu {
    typealias Executor = (pid_t, @escaping () -> Bool, @escaping (FinderMenuCommand.Outcome) -> Void) -> Void
    static let eventMarker: Int64 = 0x435546435458

    static func isMoveItem(identifier: String?, enabled: Bool) -> Bool {
        identifier == "cmdMoveItemsHere:" && enabled
    }

    static func menuKey(down: Bool) -> CGEvent? {
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
            location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)?.cgEvent else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        return event
    }

    static func perform(pid: pid_t, stillValid: @escaping () -> Bool,
                        completion: @escaping (FinderMenuCommand.Outcome) -> Void) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.06)
        guard stillValid(), let window = element(value(app, kAXFocusedWindowAttribute)),
              let view = fileView(window), let focus = element(value(app, kAXFocusedUIElementAttribute)) else {
            completion(.failed("无法确认 Finder 的文件视图，未执行移动。")); return
        }
        guard contextMenu(view) == nil else {
            completion(.failed("请先关闭 Finder 中已打开的快捷菜单，再按 ⌘V。")); return
        }
        let valid = {
            guard stillValid(), let current = element(value(app, kAXFocusedWindowAttribute)) else { return false }
            return CFEqual(window, current)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var shownMenu: AXUIElement?
        func finish(_ result: FinderMenuCommand.Outcome) {
            if case .failed = result, let shownMenu {
                // Cancel only the menu we located, never send a global Escape.
                _ = AXUIElementPerformAction(shownMenu, kAXCancelAction as CFString)
            }
            completion(result)
        }
        func poll() {
            guard valid() else { finish(.failed("目标选择、窗口或剪贴板已变化，已取消移动。")); return }
            guard ProcessInfo.processInfo.systemUptime <= deadline else {
                finish(.failed("未能打开文件夹快捷菜单。请打开目标文件夹后再粘贴。")); return
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
                finish(.failed("Finder 的文件夹快捷菜单没有可用的移动命令。"))
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
