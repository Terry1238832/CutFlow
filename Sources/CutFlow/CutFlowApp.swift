import SwiftUI
import AppKit

@main
struct CutFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second launch should reveal the existing instance, not install a second event tap.
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.onStatusChange = { [weak self] in self?.updateMenu() }
        updateMenu()
        if !UserDefaults.standard.bool(forKey: "didLaunch") || !model.trusted {
            showSettings()
            UserDefaults.standard.set(true, forKey: "didLaunch")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { model?.keyboard.stop() }

    private func updateMenu() {
        guard statusItem != nil else { return }
        let symbol = model.pendingCount > 0 ? "scissors.badge.ellipsis" : "scissors"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "CutFlow")
            ?? NSImage(systemSymbolName: "scissors", accessibilityDescription: "CutFlow")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "CutFlow · \(model.status)"
        statusItem.button?.appearsDisabled = !model.enabled || !model.running
        let menu = NSMenu()
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add(menu, model.enabled ? "暂停 CutFlow" : "启用 CutFlow", #selector(toggleEnabled))
        let cancel = add(menu, "取消当前剪切", #selector(cancelCut))
        cancel.isEnabled = model.pendingCount > 0 || model.waiting
        menu.addItem(.separator())
        add(menu, "设置与使用说明…", #selector(showSettings), key: ",")
        add(menu, "退出 CutFlow", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleEnabled() { model.enabled.toggle(); updateMenu() }
    @objc private func cancelCut() { model.keyboard.cancel() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "CutFlow"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    private let accent = Color(red: 0.39, green: 0.31, blue: 0.89)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 15) {
                    Image(systemName: "scissors")
                        .font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(LinearGradient(colors: [accent, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CutFlow").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("让文件剪切，顺手一点。").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("MAC 工具").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                }

                HStack(spacing: 0) {
                    step("01", "选择文件", "在 Finder 中选中项目", symbol: "cursorarrow.click")
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    step("02", "⌘ X", "剪切，文件暂留原处", symbol: nil)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    step("03", "⌘ V", "到目标文件夹粘贴", symbol: nil)
                }
                .padding(.vertical, 21)
                .frame(maxWidth: .infinity)
                .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: model.trusted && model.running ? "checkmark.circle.fill" : "lock.circle.fill")
                            .font(.system(size: 23)).foregroundStyle(model.trusted && model.running ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.status).font(.system(size: 14, weight: .semibold))
                            Text(model.statusDetail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    if !model.trusted || !model.running {
                        HStack {
                            Button("打开辅助功能设置") { model.openAccessibility() }.buttonStyle(.borderedProminent)
                            Button("重新检测") { model.recheck() }
                            Button("定位当前应用") { model.revealApplication() }
                        }
                        Text("开关已开启却无效：先在辅助功能列表中选中旧 CutFlow，点击 − 移除；再点击 +，添加“定位当前应用”显示的这份应用并开启，然后返回重新检测。更新后的临时签名或另一份同名应用可能与旧授权不匹配。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if model.pendingCount > 0 {
                        Button("取消当前剪切") { model.keyboard.cancel() }
                    }
                    if let message = model.detectionMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("授权诊断与应用位置") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.accessDiagnostic)
                            Text("当前应用：\(model.applicationPath)").textSelection(.enabled)
                        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.font(.system(size: 11))
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

                VStack(spacing: 0) {
                    setting("启用快捷键", detail: "在 Finder 中使用 ⌘X 剪切、⌘V 移动", binding: $model.enabled)
                    Divider().padding(.leading, 15)
                    setting("剪切后淡化（实验）", detail: "用覆盖层模拟半透明，仅用于可识别的 Finder 项目", binding: $model.dimCutFiles)
                    if model.dimCutFiles {
                        Text(model.dimStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                        HStack {
                            Button("选择文件测试淡化…") { model.previewDimming() }
                                .disabled(!model.trusted || !model.enabled || model.waiting || model.pendingCount > 0 || model.isPreviewing)
                            if model.isPreviewing {
                                Button("结束测试") { model.stopPreview() }
                            }
                            Spacer()
                        }.padding(.horizontal, 16).padding(.bottom, 8)
                        if !model.previewResult.isEmpty {
                            Text("上次测试：\(model.previewResult)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.bottom, 12)
                        }
                    }
                    Divider().padding(.leading, 15)
                    setting("登录时启动", detail: "建议先将应用放入“应用程序”文件夹", binding: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    Divider().padding(.leading, 15)
                    setting("支持 ForkLift", detail: "同时处理 ForkLift 的本地文件快捷键", binding: $model.forkLift)
                    Divider().padding(.leading, 15)
                    setting("保护文字编辑", detail: "检测到重命名或搜索输入框时，保留原有快捷键", binding: $model.protectText)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 5) {
                    Text("只改变快捷键，移动交给系统。")
                        .font(.system(size: 12, weight: .medium))
                    Text("⌘C 保持普通复制。Esc 取消剪切标记，剪贴板仍可普通粘贴。关闭窗口后继续在菜单栏运行。文字检测无法识别焦点时会保留原有快捷键；可关闭此保护以使用兼容模式。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.loginNeedsApproval {
                        Text("登录项需要在系统设置中批准。").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Text("CutFlow \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · 本地运行 · 无网络请求")
                    Spacer()
                    Button("退出应用") { NSApp.terminate(nil) }.buttonStyle(.plain)
                }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(28)
        }
        .frame(width: 640, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .alert("设置未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func step(_ number: String, _ title: String, _ caption: String, symbol: String?) -> some View {
        VStack(spacing: 9) {
            Text(number).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(accent.opacity(0.65))
            Group {
                if let symbol { Label(title, systemImage: symbol).font(.system(size: 17, weight: .semibold)) }
                else { Text(title).font(.system(size: 26, weight: .semibold, design: .rounded)) }
            }.frame(height: 30)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func setting(_ title: String, detail: String, binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}
