import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var statusText = "就绪(按一下右 Command 开始/结束)"

    private let hotKey = HotKey()
    private let recorder = AudioRecorder()
    private let localEngine = Transcriber(localeID: "zh-CN")   // 第二层:Apple SpeechTranscriber
    private let cloudEngine = AliyunCloudTranscriber()         // 第一层:阿里云在线
    private let network = NetworkMonitor()
    private let hud = RecorderHUD()
    private var busy = false          // 转写/润色中
    private var isRecording = false   // 正在录音

    // 联网优先:有网+配了 key 时优先用阿里云在线;失败/断网自动降级本地 Apple
    private var preferCloud: Bool {
        get { UserDefaults.standard.object(forKey: "preferCloud") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "preferCloud") }
    }

    // 熔断:云端连续失败就暂停一段时间直接走本地,避免每句白等超时
    private var cloudFails = 0
    private var cloudCooldownUntil: Date?
    private let cloudFailThreshold = 2          // 连续失败几次触发熔断
    private let cloudCooldownSeconds = 120.0    // 熔断后暂停多久再试云端

    /// 此刻是否该尝试云端(考虑开关/网络/key/熔断冷却)
    private var cloudUsable: Bool {
        guard preferCloud, AliyunConfig.isConfigured, network.isOnline else { return false }
        if let until = cloudCooldownUntil, Date() < until { return false }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotKey()
        requestMicPermission()
        promptAccessibilityIfNeeded()
        network.start()
        AliyunConfig.ensureTemplate()
        // 后台预热本地 Apple 模型,避免首次降级时冷下载卡住
        Task { await localEngine.prepare() }
        if ProcessInfo.processInfo.environment["VK_HUD_TEST"] != nil { runHUDSelfTest() }
    }

    // 临时自测:不触发录音,循环演示悬浮控件各状态(VK_HUD_TEST=1 时)
    private func runHUDSelfTest() {
        Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
            MainActor.assumeIsolated { self.hud.pushLevel(Float.random(in: 0.15...0.95)) }
        }
        hud.engineText = "阿里云"
        func cycle() {
            hud.show(.recording)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.hud.show(.transcribing) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.hud.show(.polishing) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { self.hud.show(.done("已输入 ✓")) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { cycle() }
        }
        cycle()
    }

    /// 全局快捷键与自动粘贴都需要「辅助功能」权限,首次启动弹窗引导授权。
    private func promptAccessibilityIfNeeded() {
        // 等价于 kAXTrustedCheckOptionPrompt,直接用字符串避免 Swift6 并发告警
        let options = ["AXTrustedCheckOptionPrompt": true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSLog("VoiceKey 辅助功能授权(AXIsProcessTrusted)= \(trusted)")
        if !trusted {
            setStatus("请在「辅助功能」中勾选 VoiceKey 后重启本应用")
        }
    }

    // MARK: - 菜单栏
    // 只创建一次状态栏图标;菜单内容每次打开时重建(menuNeedsUpdate),保证勾选与"当前生效"实时准确
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    // NSMenuDelegate:每次打开菜单前重建,刷新状态/勾选/当前生效
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "VoiceKey — 语音输入", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        statusMenuItem = NSMenuItem(title: "状态:\(statusText)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let current = NSMenuItem(title: "当前生效:\(currentEngineLabel())", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)

        // —— 转写引擎(两层:在线阿里云 → 断网降级本地 Apple)——
        menu.addItem(.sectionHeader(title: "转写引擎(语音 → 文字)"))

        let cloudItem = NSMenuItem(title: "在线优先 · 阿里云(转写+润色,最准)", action: #selector(toggleCloud), keyEquivalent: "")
        cloudItem.state = preferCloud ? .on : .off
        menu.addItem(cloudItem)

        let fallbackHint = NSMenuItem(title: "断网 / 在线失败时:本地 Apple + 系统润色", action: nil, keyEquivalent: "")
        fallbackHint.isEnabled = false
        fallbackHint.indentationLevel = 1
        menu.addItem(fallbackHint)

        // —— 设置 ——
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AliyunConfig.isConfigured ? "阿里云 API Key(已填,点此重填)…" : "填写阿里云 API Key…", action: #selector(editAliyunKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "编辑自定义词表…", action: #selector(editVocabulary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「辅助功能」设置…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「麦克风」设置…", action: #selector(openMic), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
    }

    // 当前这一刻实际会用哪条链路(直接告诉用户)
    private func currentEngineLabel() -> String {
        if preferCloud {
            if !AliyunConfig.isConfigured { return "本地 Apple(在线未配置 Key)" }
            if !network.isOnline { return "本地 Apple(当前无网)" }
            if let until = cloudCooldownUntil, Date() < until {
                let s = Int(until.timeIntervalSinceNow)
                return "本地 Apple(云端不稳,暂停 \(s)s 后再试)"
            }
            return "在线 阿里云(转写+润色)"
        }
        return "本地 Apple"
    }

    private func updateIcon(recording: Bool) {
        let symbol = recording ? "mic.fill" : "mic"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceKey")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func setStatus(_ text: String) {
        statusText = text
        statusMenuItem?.title = "状态:\(text)"
    }

    // 计时埋点:写入 /tmp/voicekey-timing.log(诊断速度用)
    private func ms(_ start: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
    }
    private func timeLog(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/voicekey-timing.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - 快捷键(点按右 Command 开始/结束录音)
    private func setupHotKey() {
        hotKey.onToggle = { [weak self] in self?.toggleRecording() }
        hotKey.start()
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.hud.pushLevel(level) }
        }
    }

    // 点按右 Command:在 开始录音 / 停止并处理 之间切换
    private func toggleRecording() {
        if busy { return } // 转写/润色中,忽略
        if isRecording { stopAndProcess() } else { startRecording() }
    }

    // MARK: - 麦克风权限
    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: - 录音 → 转写 → 润色 → 粘贴
    // 当前这次会用的转写引擎短名(给悬浮条显示)
    private func intendedEngineShort() -> String {
        cloudUsable ? "阿里云" : "Apple"
    }

    private func startRecording() {
        guard !busy, !isRecording else { return }
        do {
            try recorder.start()
            isRecording = true
            updateIcon(recording: true)
            setStatus("录音中…(再按一下右 Command 结束)")
            hud.engineText = intendedEngineShort()
            hud.show(.recording)
        } catch {
            setStatus("录音失败:\(error.localizedDescription)")
            hud.show(.message("录音失败")); hud.hide(after: 1.5)
        }
    }

    private func stopAndProcess() {
        guard isRecording, let url = recorder.stop() else { return }
        isRecording = false
        updateIcon(recording: false)
        busy = true
        setStatus("转写中…")
        hud.show(.transcribing)

        let tryCloud = cloudUsable
        timeLog("--- 开始 (tryCloud=\(tryCloud), online=\(network.isOnline), keyConfigured=\(AliyunConfig.isConfigured), cloudFails=\(cloudFails)) ---")
        Task {
            defer { busy = false }
            do {
                let raw: String
                var usedCloud = false   // 在线转写是否真的成功了
                let tT = Date()
                if tryCloud {
                    setStatus("在线转写中…")
                    do {
                        raw = try await cloudEngine.transcribe(fileURL: url)
                        usedCloud = true
                        cloudFails = 0; cloudCooldownUntil = nil   // 成功:重置熔断
                        timeLog("转写 [云 阿里云] \(ms(tT))")
                    } catch {
                        // 在线失败 → 计入熔断,自动降级本地
                        cloudFails += 1
                        if cloudFails >= cloudFailThreshold {
                            cloudCooldownUntil = Date().addingTimeInterval(cloudCooldownSeconds)
                            timeLog("云端连续 \(cloudFails) 次失败 → 熔断,暂停 \(Int(cloudCooldownSeconds))s 直接走本地")
                        }
                        timeLog("云端转写失败(\(ms(tT))):\(error.localizedDescription) → 降级本地")
                        NSLog("VoiceKey 在线转写失败,降级本地:\(error.localizedDescription)")
                        setStatus("在线失败,改用本地…")
                        hud.engineText = "Apple"
                        hud.show(.transcribing)
                        let tL = Date()
                        raw = try await withTimeout(20) { [localEngine] in try await localEngine.transcribe(fileURL: url) }
                        timeLog("转写 [本地 Apple,降级] \(ms(tL))")
                    }
                } else {
                    raw = try await withTimeout(20) { [localEngine] in try await localEngine.transcribe(fileURL: url) }
                    timeLog("转写 [本地 Apple] \(ms(tT))")
                }
                try? FileManager.default.removeItem(at: url)
                guard !raw.isEmpty else {
                    setStatus("没听清,请重试")
                    hud.show(.message("没听清,请重试")); hud.hide(after: 1.5)
                    return
                }

                // 润色跟着转写走:云端转写→qwen-plus 润色;本地/降级→本地 Foundation Models 润色
                setStatus("润色中…")
                hud.show(.polishing)
                let tP = Date()
                let polished = usedCloud ? await CloudPolisher.polish(raw) : await Polisher.polish(raw)
                timeLog("润色 [\(usedCloud ? "云 qwen-plus" : "本地 FM")] \(ms(tP))")

                TextInserter.insert(polished)
                setStatus("已插入 ✓")
                hud.show(.done("已输入 ✓")); hud.hide(after: 1.0)
            } catch {
                setStatus("失败:\(error.localizedDescription)")
                hud.show(.message("失败,请重试")); hud.hide(after: 2)
            }
        }
    }

    @objc private func toggleCloud() {
        if !preferCloud && !AliyunConfig.isConfigured {
            setStatus("请先填写阿里云 API Key")
            editAliyunKey()
            return
        }
        preferCloud.toggle()
        setStatus(preferCloud ? "已开启在线优先" : "已关闭在线优先(用本地)")
    }

    @objc private func editAliyunKey() {
        AliyunConfig.ensureTemplate()
        NSWorkspace.shared.open(AliyunConfig.fileURL)
    }

    @objc private func editVocabulary() {
        let url = Vocabulary.fileURL
        _ = Vocabulary.load() // 确保模板已生成
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMic() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
