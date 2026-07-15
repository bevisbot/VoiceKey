import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var statusText = "就绪(按一下右 Command 开始/结束)"

    private let hotKey = HotKey()
    private let recorder = AudioRecorder()
    private let network = NetworkMonitor()
    private let hud = RecorderHUD()
    private var session: VolcanoStreamingSession?   // 当前流式会话
    private var busy = false          // 转写中
    private var isRecording = false   // 正在录音

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotKey()
        requestMicPermission()
        promptAccessibilityIfNeeded()
        network.start()
        VolcanoConfig.ensureTemplate()
        AliyunConfig.ensureTemplate()
        HotWords.ensureTemplate()
        if ProcessInfo.processInfo.environment["VK_HUD_TEST"] != nil { runHUDSelfTest() }
    }

    // 临时自测:循环演示悬浮控件各状态(VK_HUD_TEST=1 时)
    private func runHUDSelfTest() {
        Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
            MainActor.assumeIsolated { self.hud.pushLevel(Float.random(in: 0.15...0.95)) }
        }
        hud.engineText = "火山"
        func cycle() {
            hud.show(.recording)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { self.hud.show(.transcribing) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { self.hud.show(.done("已输入 ✓")) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { cycle() }
        }
        cycle()
    }

    /// 全局快捷键与自动粘贴都需要「辅助功能」权限,首次启动弹窗引导授权。
    private func promptAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted { setStatus("请在「辅助功能」中勾选 VoiceKey 后重启本应用") }
    }

    // MARK: - 菜单栏
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        populateMenu(menu)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populateMenu(menu) }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "VoiceKey — 语音输入", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        statusMenuItem = NSMenuItem(title: "状态:\(statusText)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let engine = NSMenuItem(title: "引擎:火山实时流式 + qwen-plus 润色", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: VolcanoConfig.isConfigured ? "火山 API 凭据(已填,点此重填)…" : "填写火山 API 凭据…", action: #selector(editVolcanoKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: AliyunConfig.isConfigured ? "阿里云 Key·润色(已填,点此重填)…" : "填写阿里云 Key(qwen-plus 润色)…", action: #selector(editAliyunKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "编辑高频词表(纠错优先靠拢)…", action: #selector(editHotWords), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「辅助功能」设置…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「麦克风」设置…", action: #selector(openMic), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
    }

    private func updateIcon(recording: Bool) {
        statusItem.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: "VoiceKey")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func setStatus(_ text: String) {
        statusText = text
        statusMenuItem?.title = "状态:\(text)"
    }

    // 计时埋点:/tmp/voicekey-timing.log
    private func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }
    private func timeLog(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/voicekey-timing.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    // MARK: - 快捷键(点按右 Command 开始/结束)
    private func setupHotKey() {
        hotKey.onToggle = { [weak self] in self?.toggleRecording() }
        hotKey.start()
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.hud.pushLevel(level) }
        }
    }

    private func toggleRecording() {
        if busy { return }
        if isRecording { stopAndProcess() } else { startRecording() }
    }

    private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: - 录音(边录边推流)→ 松手出结果 → qwen-plus 润色(带高频词表)→ 粘贴。无降级。
    private func startRecording() {
        guard !busy, !isRecording else { return }
        guard VolcanoConfig.isConfigured else {
            setStatus("请先填写火山 API 凭据")
            hud.show(.message("未配置火山凭据")); hud.hide(after: 1.8)
            editVolcanoKey()
            return
        }
        guard network.isOnline else {
            setStatus("无网络,无法转写")
            hud.show(.message("无网络,无法转写")); hud.hide(after: 1.8)
            return
        }

        let s = VolcanoStreamingSession()
        do {
            try s.start()
        } catch {
            setStatus("火山连接失败:\(error.localizedDescription)")
            hud.show(.message("连接失败,请重试")); hud.hide(after: 1.8)
            return
        }
        session = s
        recorder.onPCM = { pcm in s.sendPCM(pcm) }   // 录音线程直接推流给本会话

        do {
            try recorder.start()
        } catch {
            s.cancel(); session = nil; recorder.onPCM = nil
            setStatus("录音失败:\(error.localizedDescription)")
            hud.show(.message("录音失败")); hud.hide(after: 1.5)
            return
        }
        isRecording = true
        updateIcon(recording: true)
        setStatus("录音中…(再按一下右 Command 结束)")
        hud.engineText = "火山"
        hud.show(.recording)
        timeLog("--- 开始录音(火山流式)---")
    }

    private func stopAndProcess() {
        guard isRecording, let s = session else { return }
        isRecording = false
        recorder.stop()   // 内部已清 onPCM 回调
        updateIcon(recording: false)
        busy = true
        setStatus("转写中…")
        hud.engineText = "火山"
        hud.show(.transcribing)

        Task {
            defer { busy = false; session = nil }
            do {
                let tT = Date()
                let raw = try await s.finish()
                timeLog("转写 [火山] \(ms(tT)) 原文:\(raw)")
                guard !raw.isEmpty else {
                    setStatus("没听清,请重试")
                    hud.show(.message("没听清,请重试")); hud.hide(after: 1.5)
                    return
                }

                setStatus("润色中…")
                hud.engineText = "qwen-plus"
                hud.show(.polishing)
                let tP = Date()
                let polished = await CloudPolisher.polish(raw)   // 配了阿里云 key 才润色,否则原样返回
                timeLog("润色 [qwen-plus] \(ms(tP))")

                TextInserter.insert(polished)
                setStatus("已插入 ✓")
                hud.show(.done("已输入 ✓")); hud.hide(after: 1.0)
            } catch {
                timeLog("失败:\(error.localizedDescription)")
                setStatus("失败:\(error.localizedDescription)")
                hud.show(.message("失败,请重试")); hud.hide(after: 2)
            }
        }
    }

    // MARK: - 菜单动作
    @objc private func editVolcanoKey() {
        VolcanoConfig.ensureTemplate()
        NSWorkspace.shared.open(VolcanoConfig.fileURL)
    }
    @objc private func editAliyunKey() {
        AliyunConfig.ensureTemplate()
        NSWorkspace.shared.open(AliyunConfig.fileURL)
    }
    @objc private func editHotWords() {
        HotWords.ensureTemplate()
        NSWorkspace.shared.open(HotWords.fileURL)
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
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
