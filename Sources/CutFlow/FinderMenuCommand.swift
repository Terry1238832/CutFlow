import AppKit
import ApplicationServices

/// Runs Finder's own commands, leaving transfers, conflicts and undo to Finder.
/// Menu shortcuts identify commands independently of the system's language.
enum FinderMenuCommand {
    enum Command: Equatable {
        case copy, move
        var name: String { self == .copy ? "复制" : "移动" }
        var character: String { self == .copy ? "c" : "v" }
        func matches(character: String?, modifiers: UInt32?) -> Bool {
            character?.lowercased() == self.character &&
                modifiers == (self == .move ? AXMenuItemModifiers.option.rawValue : 0)
        }
    }
    enum Outcome: Equatable {
        case performed
        case failed(String)
    }
    typealias Executor = (Command, pid_t, () -> Bool) -> Outcome

    static func perform(_ command: Command, pid: pid_t, stillValid: () -> Bool) -> Outcome {
        guard stillValid() else { return .failed("前台应用或剪切状态已变化") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        func withinDeadline() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard withinDeadline() else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        func children(_ item: AXUIElement) -> [AXUIElement] {
            (value(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        guard let menuBar = element(value(app, kAXMenuBarAttribute)),
              let window = element(value(app, kAXFocusedWindowAttribute)) else {
            return .failed("无法读取 Finder 的菜单或当前窗口")
        }
        // Only inspect top-level menu commands; never descend into Services or
        // other arbitrary submenus that may reuse a shortcut.
        for heading in children(menuBar).prefix(16) {
            for menu in children(heading).prefix(2) {
                for item in children(menu).prefix(100) {
                    guard withinDeadline() else { return .failed("读取 Finder 菜单超时") }
                    let character = value(item, kAXMenuItemCmdCharAttribute) as? String
                    guard character?.lowercased() == command.character else { continue }
                    let modifiers = (value(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.uint32Value
                    guard command.matches(character: character, modifiers: modifiers) else { continue }
                    guard (value(item, kAXEnabledAttribute) as? Bool) == true else {
                        return .failed("Finder 的\(command.name)命令当前不可用")
                    }
                    guard let currentWindow = element(value(app, kAXFocusedWindowAttribute)),
                          CFEqual(window, currentWindow), stillValid(), withinDeadline() else {
                        return .failed("执行前窗口、焦点或剪贴板已变化")
                    }
                    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return result == .success ? .performed : .failed("Finder 拒绝\(command.name)命令（\(result.rawValue)）")
                }
            }
        }
        return .failed(withinDeadline() ? "未找到 Finder 的\(command.name)菜单命令" : "读取 Finder 菜单超时")
    }
}
