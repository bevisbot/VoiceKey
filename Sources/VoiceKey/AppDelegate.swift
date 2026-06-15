import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!

    private let hotKey = HotKey()
    private let recorder = AudioRecorder()
    private let appleEngine = Transcriber(localeID: "zh-CN")
    private let whisperEngine = WhisperTranscriber()
    private let whisperServer = WhisperServer()
    private let hud = RecorderHUD()
    private var busy = false          // 转写/润色中
    private var isRecording = false   // 正在录音

    // 是否用 Whisper(默认是,装了才生效);持久化到 UserDefaults
    private var useWhisper: Bool {
        get { UserDefaults.standard.object(forKey: "useWhisper") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useWhisper") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotKey()
        requestMicPermission()
        promptAccessibilityIfNeeded()
        if whisperServer.isInstalled && useWhisper { whisperServer.start() }
        if ProcessInfo.processInfo.environment["VK_HUD_TEST"] != nil { runHUDSelfTest() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisperServer.stop()
    }

    // 临时自测:不触发录音,循环演示悬浮控件各状态(VK_HUD_TEST=1 时)
    private func runHUDSelfTest() {
        Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
            MainActor.assumeIsolated { self.hud.pushLevel(Float.random(in: 0.15...0.95)) }
        }
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
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VoiceKey — 语音输入", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(title: "状态:就绪(按一下右 Command 开始/结束)", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        // 转写引擎切换
        let whisperItem = NSMenuItem(title: "引擎:Whisper turbo(中英混排更好)", action: #selector(pickWhisper), keyEquivalent: "")
        whisperItem.state = useWhisper ? .on : .off
        if !whisperServer.isInstalled { whisperItem.isEnabled = false; whisperItem.title += "(未安装)" }
        let appleItem = NSMenuItem(title: "引擎:Apple 系统(更快)", action: #selector(pickApple), keyEquivalent: "")
        appleItem.state = useWhisper ? .off : .on
        menu.addItem(whisperItem)
        menu.addItem(appleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "编辑自定义词表…", action: #selector(editVocabulary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「辅助功能」设置…", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开「麦克风」设置…", action: #selector(openMic), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateIcon(recording: Bool) {
        let symbol = recording ? "mic.fill" : "mic"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceKey")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func setStatus(_ text: String) {
        statusMenuItem.title = "状态:\(text)"
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
    private func startRecording() {
        guard !busy, !isRecording else { return }
        do {
            try recorder.start()
            isRecording = true
            updateIcon(recording: true)
            setStatus("录音中…(再按一下右 Command 结束)")
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

        let engine: TranscribeEngine = (useWhisper && whisperServer.isInstalled) ? whisperEngine : appleEngine
        Task {
            defer { busy = false }
            do {
                let raw = try await engine.transcribe(fileURL: url)
                try? FileManager.default.removeItem(at: url)
                guard !raw.isEmpty else {
                    setStatus("没听清,请重试")
                    hud.show(.message("没听清,请重试")); hud.hide(after: 1.5)
                    return
                }

                setStatus("润色中…")
                hud.show(.polishing)
                let polished = await Polisher.polish(raw)

                TextInserter.insert(polished)
                setStatus("已插入 ✓")
                hud.show(.done("已输入 ✓")); hud.hide(after: 1.0)
            } catch {
                setStatus("失败:\(error.localizedDescription)")
                hud.show(.message("失败,请重试")); hud.hide(after: 2)
            }
        }
    }

    @objc private func pickWhisper() {
        guard whisperServer.isInstalled else { return }
        useWhisper = true
        whisperServer.start()
        setupMenuBar() // 刷新勾选
        setStatus("已切换到 Whisper turbo")
    }

    @objc private func pickApple() {
        useWhisper = false
        setupMenuBar()
        setStatus("已切换到 Apple 系统引擎")
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
