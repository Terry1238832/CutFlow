import AppKit
import ApplicationServices

enum FinderFileView: Equatable {
    case icon, list, column, gallery

    init?(identifier: String) {
        switch identifier.lowercased() {
        case "iconview": self = .icon
        case "listview": self = .list
        case "columnview": self = .column
        case "galleryview": self = .gallery
        default: return nil
        }
    }
}

/// Conservative identity rules: a filename is useful only after the window's
/// directory has been established. An explicit, conflicting URL always wins.
enum FinderDimOverlayIdentity {
    static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    static func sourceDirectory(for urls: [URL]) -> URL? {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return nil }
        let parents = Set(urls.map { path($0.deletingLastPathComponent()) })
        guard parents.count == 1, let parent = parents.first else { return nil }
        return URL(fileURLWithPath: parent, isDirectory: true)
    }

    static func match(nodeURL: URL?, names: [String], directory: URL, cutURLs: [URL]) -> URL? {
        if let nodeURL {
            guard nodeURL.isFileURL else { return nil }
            // An expanded Finder list can display files from subfolders while
            // the window itself remains at an ancestor directory. A verified
            // AXURL is sufficient; only filename guesses need the source
            // directory to match the open directory.
            return cutURLs.first { path($0) == path(nodeURL) }
        }
        guard let parent = sourceDirectory(for: cutURLs), path(parent) == path(directory) else { return nil }
        let matches = cutURLs.filter { names.contains($0.lastPathComponent) }
        let paths = Set(matches.map(path))
        return paths.count == 1 ? matches.first : nil
    }

    static func pathBarConfirms(_ components: [URL], directory: URL, cutURLs: [URL]) -> Bool {
        guard !components.isEmpty, components.allSatisfy(\.isFileURL),
              let terminal = components.max(by: { $0.pathComponents.count < $1.pathComponents.count }) else { return false }
        let terminalPath = path(terminal)
        // A breadcrumb trail must be one ancestry chain, not unrelated URLs.
        guard components.allSatisfy({
            let component = path($0)
            return component == "/" || terminalPath == component || terminalPath.hasPrefix(component + "/")
        }) else { return false }
        if terminalPath == path(directory) { return true }
        return path(terminal.deletingLastPathComponent()) == path(directory)
            && cutURLs.contains { path($0) == terminalPath }
    }
}

enum FinderDimOverlayGeometry {
    struct WindowCandidate {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let frame: CGRect
        let title: String?
    }

    static func sourceWindow(pid: pid_t, frame: CGRect, title: String?,
                             candidates: [WindowCandidate]) -> CGWindowID? {
        let matches = candidates.filter { candidate in
            guard candidate.pid == pid, candidate.layer == 0,
                  valid(candidate.frame), valid(frame) else { return false }
            let overlap = candidate.frame.intersection(frame)
            return valid(overlap)
                && overlap.width * overlap.height / max(candidate.frame.width * candidate.frame.height,
                                                        frame.width * frame.height) > 0.90
        }
        // Window Server returns front-to-back order. Finder can have two
        // same-sized windows; refusing all duplicates made dimming disappear.
        if let title, !title.isEmpty, matches.contains(where: { $0.title != nil }) {
            return matches.first(where: { $0.title == title })?.id
        }
        return matches.first?.id
    }

    /// Row containers may include expanded descendants. Only use a container
    /// that is a single line; otherwise shade the verified filename and icon.
    static func fileRow(label: CGRect, container: CGRect?, viewport: CGRect) -> CGRect {
        if let container, valid(container), container.contains(label),
           container.height <= max(32, label.height + 12),
           container.width <= viewport.width + 2 {
            return container
        }
        return CGRect(x: label.minX - 24, y: label.minY - 1,
                      width: label.width + 28, height: label.height + 2)
    }

    /// Window Server lists visible windows front-to-back. Both must be present
    /// before the UI can claim that the overlay is actually above its source.
    static func isInFront(window: CGWindowID, of source: CGWindowID,
                          orderedWindows: [CGWindowID]) -> Bool {
        guard let overlayIndex = orderedWindows.firstIndex(of: window),
              let sourceIndex = orderedWindows.firstIndex(of: source) else { return false }
        return overlayIndex < sourceIndex
    }

    static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0 && !rect.isNull && !rect.isInfinite
    }

    static func clip(_ rect: CGRect, viewport: CGRect, window: CGRect) -> CGRect? {
        guard valid(rect), valid(viewport), valid(window) else { return nil }
        let result = rect.intersection(viewport).intersection(window)
        return valid(result) && result.width >= 2 && result.height >= 2 ? result : nil
    }
}

enum FinderDimAppearance {
    static func wash(isDark: Bool) -> NSColor {
        // Match Finder's light or dark canvas instead of laying a bright
        // system-control color over a dark file list.
        NSColor(calibratedWhite: isDark ? 0.16 : 0.97, alpha: isDark ? 0.60 : 0.66)
    }
}

/// This draws a temporary wash over verified Finder file cells. It never edits
/// a file or Finder's UI attributes, and never captures the screen.
final class FinderDimOverlay {
    var onStatus: ((String) -> Void)?

    private let queryQueue = DispatchQueue(label: "CutFlow.FinderDimOverlay.AX", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var queryInFlight = false
    private var urls: [URL] = []
    private var directory: URL?
    private var sourcePID: pid_t?
    private var sourceWindowID: CGWindowID?
    private var timer: Timer?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var panel: DimPanel?
    private var lastLayout: Layout?
    private var suspendedUntil: TimeInterval = 0
    private var lastStatus = ""
    private var lastSourceStatus: String?
    private var requiresFinderForeground = true

    func begin(urls: [URL], requiresFinderForeground: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.begin(urls: urls, requiresFinderForeground: requiresFinderForeground) }
            return
        }
        stop()
        self.requiresFinderForeground = requiresFinderForeground
        self.urls = urls
        guard let directory = FinderDimOverlayIdentity.sourceDirectory(for: urls) else {
            status("多来源文件暂不支持淡化；剪切和移动仍可正常使用")
            return
        }
        self.directory = directory
        let sourceApp = requiresFinderForeground ? NSWorkspace.shared.frontmostApplication
            : NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        guard let app = sourceApp, app.bundleIdentifier == "com.apple.finder" else {
            status("未确认来源 Finder 窗口，本次仅保留剪切功能")
            return
        }
        sourcePID = app.processIdentifier
        // The first validated AX layout locks the source window in apply().
        // Finder can have other normal-level windows ahead of its focused file
        // window in the Window Server list. Picking the first PID match would
        // permanently reject the actual source even with correct permission.
        // Subsequent queries must still match the locked window ID.
        observeWorkspace()
        status("正在定位已剪切文件…")
        let newTimer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        tick()
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        generation &+= 1
        timer?.invalidate()
        timer = nil
        queryInFlight = false
        urls = []
        directory = nil
        sourcePID = nil
        sourceWindowID = nil
        lastLayout = nil
        lastSourceStatus = nil
        suspendedUntil = 0
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        status("等待剪切文件")
    }

    func suspendBriefly() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.suspendBriefly() }
            return
        }
        guard timer != nil else { return }
        // Invalidate a query which may have sampled the position before a scroll.
        generation &+= 1
        queryInFlight = false
        suspendedUntil = ProcessInfo.processInfo.systemUptime + 0.36
        lastLayout = nil
        panel?.orderOut(nil)
    }

    private func status(_ value: String) {
        guard value != lastStatus else { return }
        lastStatus = value
        onStatus?(value)
    }

    private func sourceStatus(_ value: String) {
        lastSourceStatus = value
        status(value)
    }

    private func statusAwayFromSource() {
        let detail = lastSourceStatus.map { "；上次检测：\($0)" } ?? ""
        status("返回来源 Finder 窗口后显示淡化\(detail)")
    }

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.suspendBriefly()
            }
            observations.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                       object: nil, queue: .main) { [weak self] _ in self?.suspendBriefly() }
        observations.append((center, token))
    }

    private func tick() {
        guard !queryInFlight, let directory, let sourcePID, !urls.isEmpty else { return }
        guard ProcessInfo.processInfo.systemUptime >= suspendedUntil else { return }
        if requiresFinderForeground && NSWorkspace.shared.frontmostApplication?.processIdentifier != sourcePID {
            panel?.orderOut(nil)
            lastLayout = nil
            statusAwayFromSource()
            return
        }
        queryInFlight = true
        let token = generation
        let files = urls
        let expectedWindow = sourceWindowID
        queryQueue.async { [weak self] in
            let result = Self.query(pid: sourcePID, directory: directory, urls: files,
                                    expectedWindow: expectedWindow)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.timer != nil else { return }
                self.queryInFlight = false
                self.apply(result, pid: sourcePID)
            }
        }
    }

    private func apply(_ result: QueryResult, pid: pid_t) {
        guard (!requiresFinderForeground || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid),
              ProcessInfo.processInfo.systemUptime >= suspendedUntil else {
            panel?.orderOut(nil)
            lastLayout = nil
            return
        }
        guard case let .layout(layout) = result else {
            panel?.orderOut(nil)
            lastLayout = nil
            if case let .unavailable(reason) = result { sourceStatus(reason) }
            return
        }
        // Repeat the inexpensive Window Server check immediately before drawing.
        // This also rejects a window that moved while the AX query was in flight.
        guard let windows = Self.windowList(),
              Self.findWindow(pid: pid, frame: layout.windowFrame,
                              title: layout.windowTitle, in: windows) == layout.windowID,
              !Self.isObscured(layout, in: windows) else {
            panel?.orderOut(nil)
            lastLayout = nil
            sourceStatus("窗口变化或被遮挡，暂时隐藏淡化")
            return
        }
        if let sourceWindowID, sourceWindowID != layout.windowID {
            panel?.orderOut(nil)
            lastLayout = nil
            statusAwayFromSource()
            return
        }
        sourceWindowID = layout.windowID
        // Require two identical readings. Never drag an old rectangle across a
        // scrolling, resizing, rearranging, or newly navigated Finder view.
        guard lastLayout == layout else {
            panel?.orderOut(nil)
            lastLayout = layout
            sourceStatus("正在确认文件位置…")
            return
        }
        guard !layout.items.isEmpty else {
            panel?.orderOut(nil)
            sourceStatus("当前视图中未找到可确认的剪切项目；项目可能不可见或名称无法匹配")
            return
        }
        let frame = Self.cocoaFrame(layout.windowFrame)
        let overlay = panel ?? DimPanel(frame: frame)
        panel = overlay
        overlay.setFrame(frame, display: false)
        let local = layout.items.map { item -> CGRect in
            let screen = Self.cocoaFrame(item.frame)
            return screen.offsetBy(dx: -frame.minX, dy: -frame.minY)
        }
        (overlay.contentView as? DimView)?.rectangles = local
        // Finder stays active. Ordinary ordering can leave an inactive app's
        // normal-level window behind Finder, especially in a full-screen Space.
        overlay.orderFrontRegardless()
        guard overlay.isOnActiveSpace, let displayedWindows = Self.windowList(),
              FinderDimOverlayGeometry.isInFront(window: CGWindowID(overlay.windowNumber),
                                                 of: layout.windowID,
                                                 orderedWindows: displayedWindows.compactMap {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
              }) else {
            sourceStatus("覆盖层尚未进入来源窗口，正在重试显示")
            return
        }
        sourceStatus("已淡化 \(layout.items.count) 个可见项目（实验）")
    }

    private struct Item: Equatable {
        let path: String
        let frame: CGRect
    }

    private struct Layout: Equatable {
        let windowID: CGWindowID
        let windowFrame: CGRect
        let windowTitle: String?
        let items: [Item]
    }

    private enum QueryResult {
        case layout(Layout)
        case unavailable(String)
    }

    private struct Node {
        let element: AXUIElement
        let depth: Int
        let view: FinderFileView?
        let clip: CGRect
        let rowFrame: CGRect?
        let rowElement: AXUIElement?
        let parentFrame: CGRect?
        let prioritized: Bool
    }

    private static func query(pid: pid_t, directory: URL, urls: [URL],
                              expectedWindow: CGWindowID?) -> QueryResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let window = element(app, kAXFocusedWindowAttribute) else {
            return .unavailable("无法读取 Finder 窗口；剪切功能不受影响")
        }
        AXUIElementSetMessagingTimeout(window, 0.04)
        // Some Finder versions omit AXDocument. Read actual breadcrumb URLs,
        // never reconstruct a filesystem path from localized display labels.
        let document = fileURL(attribute(window, kAXDocumentAttribute))
        let breadcrumbURLs = document == nil ? pathBarURLs(window) : []
        // A column view may keep the cut file visible in an ancestor column.
        // Exact file URLs remain valid there; filename fallback still requires
        // the current directory to match the source.
        let directoryConfirmed = document.map { FinderDimOverlayIdentity.path($0) == FinderDimOverlayIdentity.path(directory) }
            ?? FinderDimOverlayIdentity.pathBarConfirms(breadcrumbURLs, directory: directory, cutURLs: urls)
        let windowTitle = attribute(window, kAXTitleAttribute) as? String
        guard let windowFrame = frame(window), let windows = windowList(),
              let windowID = findWindow(pid: pid, frame: windowFrame,
                                        title: windowTitle, in: windows) else {
            return .unavailable("无法唯一确认来源窗口，暂不显示淡化")
        }
        guard expectedWindow == nil || expectedWindow == windowID else {
            return .unavailable("返回来源 Finder 窗口后显示淡化")
        }

        // Expanded list hierarchies expose many more AX cells than icon view.
        // This query runs off the event-tap thread; give Finder enough time to
        // return the visible rows while retaining a strict upper bound.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.6
        let maxNodes = 1200
        let wantedPaths = Set(urls.map(FinderDimOverlayIdentity.path))
        var nodes = [Node(element: window, depth: 0, view: nil, clip: windowFrame,
                          rowFrame: nil, rowElement: nil, parentFrame: nil, prioritized: false)]
        var index = 0
        var foundFileView = false
        var exactMatchesComplete = false
        var matches: [String: [CGRect]] = [:]
        while index < nodes.count && index < maxNodes && ProcessInfo.processInfo.systemUptime < deadline {
            let node = nodes[index]
            index += 1
            guard node.depth < 14 else { continue }
            AXUIElementSetMessagingTimeout(node.element, 0.035)
            let values = attributes(node.element, [kAXRoleAttribute, kAXIdentifierAttribute, kAXURLAttribute,
                                                   kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                                                   kAXPositionAttribute, kAXSizeAttribute])
            let role = values[safe: 0] as? String ?? ""
            let identifier = values[safe: 1] as? String ?? ""
            if ["AXToolbar", "AXMenuBar", "AXMenu"].contains(role) { continue }
            let rootView = FinderFileView(identifier: identifier)
            let view = rootView ?? node.view
            foundFileView = foundFileView || rootView != nil
            // The sidebar also uses AXOutline; it is not a file view.
            if role == "AXOutline", view == nil { continue }
            var clip = node.clip
            let nodeFrame = frame(position: values[safe: 6], size: values[safe: 7])
            if role == "AXScrollArea" || rootView != nil, let nodeFrame {
                clip = clip.intersection(nodeFrame)
                if !FinderDimOverlayGeometry.valid(clip) { continue }
            }
            let rowFrame = role == "AXRow" ? nodeFrame : (rootView == nil ? node.rowFrame : nil)
            let rowElement = role == "AXRow" ? node.element : (rootView == nil ? node.rowElement : nil)
            let isImage = (view == .icon || view == .gallery) && role == "AXImage"
            let isFilename = (view == .list || view == .column) && role == "AXTextField"
            if isImage || isFilename, let nodeFrame {
                let names = [values[safe: 3], values[safe: 4], values[safe: 5]].compactMap { $0 as? String }
                let rawURL = values[safe: 2]
                // Finder commonly puts AXURL on the list row or its icon,
                // while the filename text field supplies only AXValue.
                let explicitURL = fileURL(rawURL) ?? ((isFilename && names.contains(where: { name in
                    urls.contains { $0.lastPathComponent == name }
                })) ? rowElement.flatMap(verifiedRowURL) : nil)
                // Do not reinterpret a non-file AXURL as a filename-only match.
                let hasOtherURL = (rawURL is URL || rawURL is String) && explicitURL == nil
                // List rows may be expanded into other directories and column
                // views show multiple directories. Require the file URL there.
                let identityConfirmed = explicitURL != nil || (isImage && directoryConfirmed)
                let itemFrame = isFilename
                    ? FinderDimOverlayGeometry.fileRow(label: nodeFrame, container: rowFrame ?? node.parentFrame, viewport: clip)
                    : nodeFrame
                if !hasOtherURL, identityConfirmed,
                   let file = FinderDimOverlayIdentity.match(nodeURL: explicitURL, names: names,
                                                            directory: directory, cutURLs: urls),
                   let rect = FinderDimOverlayGeometry.clip(itemFrame, viewport: clip, window: windowFrame) {
                    matches[FinderDimOverlayIdentity.path(file), default: []].append(rect)
                    if explicitURL != nil && Set(matches.keys) == wantedPaths {
                        exactMatchesComplete = true
                        break
                    }
                }
                continue
            }
            if view != nil && (rootView != nil || role == "AXList"),
               let selected = elements(node.element, kAXSelectedRowsAttribute)
                    ?? elements(node.element, kAXSelectedChildrenAttribute), !selected.isEmpty {
                // A selected cut item may be near the end of a huge expanded
                // list. Inspect its verified AX row first, then fall back to
                // the visible tree if it is not the cut source.
                let prioritized = selected.prefix(max(0, maxNodes - nodes.count)).map {
                    Node(element: $0, depth: node.depth + 1, view: view, clip: clip,
                         rowFrame: nil, rowElement: nil, parentFrame: nodeFrame,
                         prioritized: true)
                }
                nodes.insert(contentsOf: prioritized, at: index)
            }
            // Prefer the visible subset where Finder exposes it. For fallback
            // AXChildren, drawing is still clipped to every ancestor scroll area.
            let children = elements(node.element, kAXVisibleChildrenAttribute)
                ?? elements(node.element, kAXChildrenAttribute) ?? []
            let next = children.prefix(maxNodes - min(nodes.count, maxNodes)).map {
                Node(element: $0, depth: node.depth + 1, view: view, clip: clip,
                     rowFrame: rowFrame, rowElement: rowElement, parentFrame: nodeFrame,
                     prioritized: node.prioritized)
            }
            if node.prioritized { nodes.insert(contentsOf: next, at: index) }
            else { nodes.append(contentsOf: next) }
        }
        guard exactMatchesComplete || index >= nodes.count else {
            return .unavailable("Finder 项目较多或响应较慢，暂不显示淡化")
        }
        guard foundFileView else {
            return .unavailable("未识别当前 Finder 文件视图，暂不显示淡化")
        }
        if !directoryConfirmed && matches.isEmpty {
            return .unavailable("无法确认文件位置；请在 Finder 的“显示”菜单开启“显示路径栏”后重试")
        }
        // Duplicate filename matches mean we cannot establish an unambiguous
        // cell identity. In that case omit the file instead of guessing.
        let items = matches.compactMap { path, frames -> Item? in
            let unique = frames.reduce(into: [CGRect]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.count == 1 ? Item(path: path, frame: unique[0]) : nil
        }.sorted { $0.path < $1.path }

        // Re-read the directory and window after traversal to catch navigation
        // and cell reuse during a batch. Element identity by itself is insufficient.
        guard let finalWindow = element(app, kAXFocusedWindowAttribute), CFEqual(window, finalWindow),
              fileURL(attribute(finalWindow, kAXDocumentAttribute)) == document,
              (document != nil || pathBarURLs(finalWindow) == breadcrumbURLs),
              frame(finalWindow) == windowFrame else {
            return .unavailable("窗口正在变化，暂时隐藏淡化")
        }
        let layout = Layout(windowID: windowID, windowFrame: windowFrame,
                            windowTitle: windowTitle, items: items)
        if let blocker = obscuringOwner(layout, in: windows) {
            return .unavailable("来源文件被“\(blocker)”窗口遮挡，暂时隐藏淡化")
        }
        return .layout(layout)
    }

    /// Inspect one candidate file row only. Expanded descendant rows are
    /// excluded so their URLs cannot make a parent filename look like a cut file.
    private static func verifiedRowURL(_ row: AXUIElement) -> URL? {
        var queue = [row]
        var index = 0
        var urls = Set<URL>()
        while index < queue.count && index < 48 {
            let node = queue[index]; index += 1
            if index > 1, (attribute(node, kAXRoleAttribute) as? String) == "AXRow" { continue }
            if let url = fileURL(attribute(node, kAXURLAttribute)) { urls.insert(url) }
            if urls.count > 1 { return nil }
            queue += (elements(node, kAXChildrenAttribute) ?? []).prefix(48 - min(queue.count, 48))
        }
        return index >= queue.count ? urls.first : nil
    }

    static func pathBarURLs(_ window: AXUIElement) -> [URL] {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var queue: [(AXUIElement, Bool, Int)] = [(window, false, 0)]
        var index = 0
        var result: [URL] = []
        while index < queue.count && index < 160 && ProcessInfo.processInfo.systemUptime < deadline {
            let (node, insidePath, depth) = queue[index]
            index += 1
            guard depth < 10 else { continue }
            AXUIElementSetMessagingTimeout(node, 0.025)
            let values = attributes(node, [kAXRoleAttribute, kAXIdentifierAttribute,
                                           kAXDescriptionAttribute, kAXURLAttribute,
                                           kAXTitleAttribute, kAXValueAttribute])
            let role = values[safe: 0] as? String ?? ""
            let identifier = (values[safe: 1] as? String ?? "").lowercased()
            let labels = [values[safe: 2], values[safe: 4], values[safe: 5]]
                .compactMap { ($0 as? String)?.lowercased() }
            if ["AXOutline", "AXToolbar", "AXMenuBar"].contains(role) || FinderFileView(identifier: identifier) != nil { continue }
            let isPath = insidePath || (role == "AXList"
                && (labels.contains(where: { ["路径", "path", "path bar"].contains($0) })
                    || identifier.contains("pathbar")))
            if isPath, let url = fileURL(values[safe: 3]) { result.append(url) }
            for child in (elements(node, kAXChildrenAttribute) ?? []).prefix(max(0, 160 - queue.count)) {
                queue.append((child, isPath, depth + 1))
            }
        }
        return index >= queue.count ? result : []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [AnyObject] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray,
                                                    AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let values else { return [] }
        return values as [AnyObject]
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func elements(_ parent: AXUIElement, _ name: String) -> [AXUIElement]? {
        guard let values = attribute(parent, name) as? [AnyObject] else { return nil }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private static func fileURL(_ value: AnyObject?) -> URL? {
        if let url = value as? URL, url.isFileURL { return url.standardizedFileURL }
        if let string = value as? String, let url = URL(string: string), url.isFileURL {
            return url.standardizedFileURL
        }
        return nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        frame(position: attribute(element, kAXPositionAttribute), size: attribute(element, kAXSizeAttribute))
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue = unsafeBitCast(size, to: AXValue.self)
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &extent) else { return nil }
        let result = CGRect(origin: point, size: extent)
        return FinderDimOverlayGeometry.valid(result) ? result : nil
    }

    private static func windowList() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    private static func cgFrame(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private static func findWindow(pid: pid_t, frame: CGRect, title: String?,
                                   in windows: [[String: Any]]) -> CGWindowID? {
        let candidates = windows.compactMap { info -> FinderDimOverlayGeometry.WindowCandidate? in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = cgFrame(info) else { return nil }
            return .init(id: id, pid: owner, layer: layer, frame: bounds,
                         title: info[kCGWindowName as String] as? String)
        }
        return FinderDimOverlayGeometry.sourceWindow(pid: pid, frame: frame,
                                                      title: title, candidates: candidates)
    }

    private static func isObscured(_ layout: Layout, in windows: [[String: Any]]) -> Bool {
        obscuringOwner(layout, in: windows) != nil
    }

    private static func obscuringOwner(_ layout: Layout, in windows: [[String: Any]]) -> String? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in windows {
            if (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == layout.windowID { return nil }
            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID { continue }
            // Higher-level HUDs stay above our floating panel through normal
            // Window Server compositing. Transparent full-screen HUD windows
            // must not make every Finder icon appear completely occluded.
            if (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 > NSWindow.Level.floating.rawValue { continue }
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let bounds = cgFrame(info) else { continue }
            if layout.items.contains(where: { $0.frame.intersects(bounds) }) {
                return info[kCGWindowOwnerName as String] as? String ?? "其他应用"
            }
        }
        return "不可见的来源"
    }

    private static func cocoaFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - frame.maxY,
               width: frame.width, height: frame.height)
    }
}

private final class DimPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces,
                              .fullScreenAuxiliary, .canJoinAllApplications]
        animationBehavior = .none
        contentView = DimView(frame: CGRect(origin: .zero, size: frame.size))
        contentView?.setAccessibilityElement(false)
    }
}

private final class DimView: NSView {
    var rectangles: [CGRect] = [] { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        FinderDimAppearance.wash(isDark: isDark).setFill()
        for rect in rectangles { NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill() }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
