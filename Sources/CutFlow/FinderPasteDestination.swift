import AppKit
import ApplicationServices

enum FinderPasteDestination {
    enum Decision: Equatable {
        case currentDirectory
        case folder(URL)
        case unavailable(String)
    }

    struct Selection {
        let urls: [URL]
        let directory: URL?
        let count: Int
    }

    static func decide(selection: Selection, cutFiles: [URL]) -> Decision {
        guard selection.count == 1 else { return .currentDirectory }
        guard selection.urls.count == 1 else { return .unavailable("无法确认所选项目的位置，请打开目标文件夹后重试。") }
        return decide(selected: selection.urls, cutFiles: cutFiles)
    }

    static func decide(selected: [URL], cutFiles: [URL],
                       isFolder: (URL) -> Bool = isOrdinaryFolder) -> Decision {
        let unique = Array(Set(selected.map { $0.standardizedFileURL }))
        guard unique.count == 1, let target = unique.first, isFolder(target) else { return .currentDirectory }
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard !cutFiles.contains(where: {
            let source = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == source || resolved.hasPrefix(source + "/")
        }) else { return .unavailable("目标不能是正在剪切的文件夹本身或它的子文件夹。") }
        return .folder(target)
    }

    static func read(pid: pid_t, cutFiles: [URL]) -> Decision {
        guard let selection = selection(pid: pid) else {
            return .unavailable("无法确认 Finder 选中的目标，请打开目标文件夹后重试。")
        }
        return decide(selection: selection, cutFiles: cutFiles)
    }

    static func isAt(pid: pid_t, folder: URL) -> Bool {
        guard let directory = selection(pid: pid)?.directory else { return false }
        return directory.standardizedFileURL.path == folder.standardizedFileURL.path
    }

    static func isOrdinaryFolder(_ url: URL) -> Bool {
        guard url.isFileURL,
              let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isAliasFileKey]) else { return false }
        return info.isDirectory == true && info.isPackage != true && info.isAliasFile != true
    }

    /// Path-bar URLs describe the selected leaf as well as the directory. Never
    /// mistake a merely selected folder in list/icon view for the open folder.
    static func currentDirectory(document: URL?, breadcrumbs: [URL], selected: [URL],
                                 view: FinderFileView, isFolder: (URL) -> Bool = isOrdinaryFolder) -> URL? {
        if let document { return document.standardizedFileURL }
        guard let terminal = breadcrumbs.max(by: { $0.pathComponents.count < $1.pathComponents.count }),
              breadcrumbs.allSatisfy({ $0.path == "/" || terminal.path == $0.path || terminal.path.hasPrefix($0.path + "/") }) else { return nil }
        if selected.contains(where: { $0.standardizedFileURL.path == terminal.standardizedFileURL.path }) {
            if view == .column && isFolder(terminal) { return terminal.standardizedFileURL }
            return terminal.deletingLastPathComponent().standardizedFileURL
        }
        return terminal.standardizedFileURL
    }

    private static func selection(pid: pid_t) -> Selection? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let window = element(attribute(app, kAXFocusedWindowAttribute)) else { return nil }
        let document = fileURL(attribute(window, kAXDocumentAttribute))
        let breadcrumbs = FinderDimOverlay.pathBarURLs(window)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        var queue: [(AXUIElement, FinderFileView?, Int)] = [(window, nil, 0)]
        var index = 0
        var foundView: FinderFileView?
        var selectedRoots: [AXUIElement] = []
        while index < queue.count, index < 700, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, inherited, depth) = queue[index]; index += 1
            guard depth < 14 else { continue }
            AXUIElementSetMessagingTimeout(node, 0.025)
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            let identifier = attribute(node, kAXIdentifierAttribute) as? String ?? ""
            if ["AXToolbar", "AXMenuBar", "AXMenu"].contains(role) { continue }
            let rootView = FinderFileView(identifier: identifier)
            let view = rootView ?? inherited
            if let rootView { foundView = rootView }
            if role == "AXOutline", view == nil { continue }
            if view != nil {
                // Prefer direct selection attributes; avoid inspecting every
                // filename in a large directory whenever Finder supplies them.
                if let roots = elements(attribute(node, kAXSelectedRowsAttribute))
                    ?? elements(attribute(node, kAXSelectedChildrenAttribute)) {
                    selectedRoots.append(contentsOf: roots)
                    if view != .column || role == "AXList" { continue }
                }
                if (attribute(node, kAXSelectedAttribute) as? Bool) == true,
                   rootView == nil, !["AXScrollArea", "AXList"].contains(role) {
                    selectedRoots.append(node)
                    continue
                }
            }
            for child in (elements(attribute(node, kAXChildrenAttribute)) ?? []).prefix(max(0, 700 - queue.count)) {
                queue.append((child, view, depth + 1))
            }
        }
        guard index >= queue.count, let view = foundView else { return nil }
        var roots: [AXUIElement] = []
        for root in selectedRoots where !roots.contains(where: { CFEqual($0, root) }) { roots.append(root) }
        var urls: [URL] = []
        var unresolved = false
        for root in roots {
            guard let selected = selectedURL(root, document: document, breadcrumbs: breadcrumbs) else {
                unresolved = true
                continue
            }
            if !urls.contains(selected) { urls.append(selected) }
        }
        // In column view ancestors can remain selected in earlier columns.
        // If one column cannot be resolved, do not treat its ancestor selection
        // as a multi-selection and accidentally paste into that ancestor.
        if view == .column && unresolved { return nil }
        if view == .column {
            urls = urls.filter { candidate in !urls.contains { $0 != candidate && $0.path.hasPrefix(candidate.path + "/") } }
        }
        guard let finalWindow = element(attribute(app, kAXFocusedWindowAttribute)), CFEqual(window, finalWindow),
              fileURL(attribute(finalWindow, kAXDocumentAttribute)) == document,
              FinderDimOverlay.pathBarURLs(finalWindow) == breadcrumbs else { return nil }
        let directory = unresolved ? document : currentDirectory(document: document, breadcrumbs: breadcrumbs,
                                                                 selected: urls, view: view)
        // Multiple selected files need no guessed URL to preserve ordinary
        // current-directory paste. A single unresolved target remains blocked.
        return Selection(urls: urls, directory: directory,
                         count: view == .column && !unresolved ? urls.count : roots.count)
    }

    private static func selectedURL(_ root: AXUIElement, document: URL?, breadcrumbs: [URL]) -> URL? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var urls: Set<URL> = []
        var names: [String] = []
        while index < queue.count, index < 48 {
            let (node, depth) = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(node, 0.025)
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            // An expanded selected folder's descendants are not selected files.
            if depth > 0 && role == "AXRow" { continue }
            if let url = fileURL(attribute(node, kAXURLAttribute)) { urls.insert(url); continue }
            if role == "AXImage" {
                names += [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(node, $0) as? String }
            }
            if depth < 4 {
                queue += (elements(attribute(node, kAXChildrenAttribute)) ?? []).prefix(48 - min(queue.count, 48)).map { ($0, depth + 1) }
            }
        }
        if urls.count == 1 { return urls.first }
        guard urls.isEmpty, index >= queue.count else { return nil }
        // Icon/gallery items omit AXURL. Resolve their exact label against a
        // real path-bar URL, or the explicitly reported window directory.
        let matches = breadcrumbs.filter { names.contains($0.lastPathComponent) }
        if Set(matches).count == 1 { return matches.first }
        let uniqueNames = Set(names)
        if let document, isOrdinaryFolder(document), uniqueNames.count == 1,
           let name = uniqueNames.first, !name.isEmpty, !name.contains("/"), name != ".", name != ".." {
            let candidate = document.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func elements(_ value: CFTypeRef?) -> [AXUIElement]? { value as? [AXUIElement] }
    private static func fileURL(_ value: CFTypeRef?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        return url?.isFileURL == true ? url?.standardizedFileURL : nil
    }
}
