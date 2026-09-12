import AppKit
import Combine
import ServiceManagement
import CutFlowCore

final class AppModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var running = false
    @Published var pendingCount = 0
    @Published var waiting = false
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var errorMessage: String?
    @Published var detectionMessage: String?
    @Published var accessDiagnostic = ""
    @Published var dimStatus = "等待 Finder 中的剪切"
    @Published var previewResult = ""
    @Published var isPreviewing = false
    @Published var dimCutFiles = UserDefaults.standard.object(forKey: "dimCutFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dimCutFiles, forKey: "dimCutFiles"); updateDimming() }
    }
    let applicationPath = Bundle.main.bundleURL.path
    @Published var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); keyboard.enabled = enabled }
    }
    @Published var forkLift = UserDefaults.standard.object(forKey: "forkLift") as? Bool ?? true {
        didSet { UserDefaults.standard.set(forkLift, forKey: "forkLift"); keyboard.forkLift = forkLift; keyboard.cancel() }
    }
    @Published var protectText = UserDefaults.standard.object(forKey: "protectText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(protectText, forKey: "protectText"); keyboard.protectText = protectText }
    }
    let keyboard = KeyboardService()
    private let dimOverlay = FinderDimOverlay()
    private let previewOverlay = FinderDimOverlay()
    private var previewGeneration = 0
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    var onStatusChange: (() -> Void)?

    init() {
        keyboard.enabled = enabled
        keyboard.forkLift = forkLift
        keyboard.protectText = protectText
        keyboard.onChange = { [weak self] in self?.synchronize() }
        keyboard.onCutFilesChanged = { [weak self] _ in self?.updateDimming() }
        keyboard.onVisualInterruption = { [weak self] in self?.dimOverlay.suspendBriefly() }
        dimOverlay.onStatus = { [weak self] message in self?.dimStatus = message }
        previewOverlay.onStatus = { [weak self] message in
            guard let self, self.isPreviewing else { return }
            self.previewResult = message
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    var status: String {
        if !trusted { return "需要辅助功能权限" }
        if !enabled { return "已暂停" }
        if !running { return "快捷键监听尚未启动" }
        if pendingCount > 0 { return "已剪切 \(pendingCount) 个项目" }
        if waiting { return "正在获取所选文件…" }
        return "已就绪，等待剪切"
    }

    var statusDetail: String {
        if !trusted { return "系统尚未认可当前运行的这份 CutFlow。若开关已开启，请查看下方修复步骤。" }
        if !enabled { return "重新启用后，快捷键会恢复工作。" }
        if !running { return "请检查辅助功能权限，然后退出并重新打开 CutFlow。" }
        if pendingCount > 0 { return "前往目标文件夹，按 ⌘V 移动。按 Esc 取消剪切。" }
        return "文件移动及同名冲突由 Finder 或 ForkLift 处理。"
    }

    func refresh(forceRetry: Bool = false) {
        let check = AccessibilityCheck.read()
        let evidence = AccessEvidence(reportedTrust: check.reportedTrust, accessibility: check.probe,
                                      eventTapActive: keyboard.tapIsActive)
        if evidence.hasAccess || forceRetry { keyboard.start() }
        else if keyboard.running { keyboard.stop() }
        trusted = AccessEvidence(reportedTrust: check.reportedTrust, accessibility: check.probe,
                                 eventTapActive: keyboard.tapIsActive).hasAccess
        accessDiagnostic = "系统权限标志：\(check.reportedTrust ? "已认可" : "未认可")\n辅助功能：\(check.detail)\n快捷键监听：\(keyboard.tapIsActive ? "已启动" : "未启动")\n进程：\(ProcessInfo.processInfo.processIdentifier)"
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        synchronize()
        if trusted && running { detectionMessage = nil }
    }

    private func updateDimming() {
        stopPreview()
        if dimCutFiles && !keyboard.cutFileURLs.isEmpty {
            dimOverlay.begin(urls: keyboard.cutFileURLs)
        } else {
            dimOverlay.stop()
            dimStatus = dimCutFiles ? "等待 Finder 中的剪切" : "已关闭淡化效果"
        }
    }

    func previewDimming() {
        guard trusted, enabled, dimCutFiles, !waiting, pendingCount == 0 else { return }
        let picker = NSOpenPanel()
        picker.title = "选择文件测试淡化"
        picker.message = "将在 Finder 中预览 12 秒，并保留检测结果。"
        picker.prompt = "开始测试"
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.begin { [weak self] response in
            guard let self, response == .OK, !picker.urls.isEmpty,
                  self.trusted, self.enabled, self.dimCutFiles,
                  !self.waiting, self.pendingCount == 0 else { return }
            self.stopPreview()
            self.isPreviewing = true
            self.previewResult = "正在 Finder 中打开测试项目…"
            let token = self.previewGeneration
            let urls = picker.urls
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, token == self.previewGeneration, self.isPreviewing else { return }
                // Explicit previews keep querying when returning to settings.
                // Occlusion checks still prevent painting over other windows.
                self.previewOverlay.begin(urls: urls, requiresFinderForeground: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, token == self.previewGeneration else { return }
                    self.stopPreview()
                }
            }
        }
    }

    func stopPreview() {
        previewGeneration += 1
        isPreviewing = false
        previewOverlay.stop()
    }

    func recheck() {
        refresh(forceRetry: true)
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        detectionMessage = trusted && running
            ? "\(time) 检测通过，快捷键监听已启动。"
            : "\(time) 已重新尝试；当前应用仍未获得可用授权。请按下方步骤重新添加当前这一份应用。"
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func synchronize() {
        running = keyboard.running
        switch keyboard.session.state {
        case .idle: pendingCount = 0; waiting = false
        case .awaitingCopy: pendingCount = 0; waiting = true
        case let .ready(_, _, count): pendingCount = count; waiting = false
        }
        if isPreviewing && (waiting || pendingCount > 0 || !trusted || !enabled) { stopPreview() }
        onStatusChange?()
    }

    func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
            if loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            errorMessage = "无法修改登录项：\(error.localizedDescription)。请先将 CutFlow 放入“应用程序”文件夹。"
            refresh()
        }
    }
}
