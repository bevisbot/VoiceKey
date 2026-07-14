import AppKit

/// 底部悬浮控件(类似 Typeless):录音时显示实时声波,处理时显示状态,完成淡出。
/// 关键:不抢焦点(nonactivating + 忽略鼠标),不影响往当前输入框粘贴。
@MainActor
final class RecorderHUD {
    enum State {
        case recording
        case transcribing
        case done(String)
        case message(String)
    }

    private let pillSize = NSSize(width: 240, height: 42)

    private var panel: NSPanel?
    private let waveform = WaveformView(frame: NSRect(x: 38, y: 11, width: 184, height: 20))
    private let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 13, width: 16, height: 16))
    private let dot = NSView(frame: NSRect(x: 18, y: 16, width: 9, height: 9))
    private let label = NSTextField(labelWithString: "")
    private let engineLabel = NSTextField(labelWithString: "")  // 录音时右侧显示当前引擎
    private var hideWork: DispatchWorkItem?

    /// 当前转写引擎短名(阿里云 / Whisper / Apple),由外部设置
    var engineText = ""

    // MARK: - 对外接口
    func pushLevel(_ level: Float) { waveform.push(CGFloat(level)) }

    func show(_ state: State) {
        hideWork?.cancel()
        ensurePanel()
        apply(state)
        guard let panel else { return }
        positionAtBottomCenter(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless() // 不夺取焦点
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 状态切换
    private func apply(_ state: State) {
        // 处理态/完成态:文字在药丸内整体居中(竖直方向也居中)
        let centered = NSRect(x: 0, y: (pillSize.height - 18) / 2, width: pillSize.width, height: 18)
        switch state {
        case .recording:
            // 录音态:红点 + 满行波形(说话阶段模型未介入,不显示引擎名)
            dot.isHidden = false; startPulse(); dotColor(.systemRed)
            waveform.isHidden = false; waveform.reset()
            spinner.isHidden = true; spinner.stopAnimation(nil)
            label.isHidden = true
            engineLabel.isHidden = true
        case .transcribing:
            switchToProcessing("转写中…", centered)
        case .done(let t):
            dot.isHidden = false; stopPulse(); dotColor(.systemGreen)
            waveform.isHidden = true; spinner.isHidden = true; spinner.stopAnimation(nil)
            engineLabel.isHidden = true
            label.isHidden = false; label.stringValue = t; label.frame = centered
        case .message(let t):
            dot.isHidden = true; stopPulse()
            waveform.isHidden = true; spinner.isHidden = true; spinner.stopAnimation(nil)
            engineLabel.isHidden = true
            label.isHidden = false; label.stringValue = t; label.frame = centered
        }
    }

    private func switchToProcessing(_ text: String, _ centered: NSRect) {
        dot.isHidden = true; stopPulse()
        waveform.isHidden = true
        engineLabel.isHidden = true
        spinner.isHidden = false; spinner.startAnimation(nil)
        // 文字带上引擎名,如「阿里云 转写中…」
        let full = engineText.isEmpty ? text : "\(engineText) \(text)"
        label.isHidden = false; label.stringValue = full; label.frame = centered
    }

    // MARK: - 面板搭建
    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: pillSize))
        content.wantsLayer = true
        content.layer?.cornerRadius = pillSize.height / 2
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .vibrantDark)

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.alignment = .center
        label.cell?.lineBreakMode = .byTruncatingTail

        engineLabel.font = .systemFont(ofSize: 10, weight: .medium)
        engineLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        engineLabel.backgroundColor = .clear
        engineLabel.isBezeled = false
        engineLabel.isEditable = false
        engineLabel.alignment = .right
        engineLabel.frame = NSRect(x: pillSize.width - 78, y: (pillSize.height - 16) / 2, width: 64, height: 16)

        content.addSubview(dot)
        content.addSubview(spinner)
        content.addSubview(waveform)
        content.addSubview(label)
        content.addSubview(engineLabel)
        p.contentView = content
        panel = p
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let x = v.midX - pillSize.width / 2
        let y = v.minY + 90
        panel.setFrame(NSRect(x: x, y: y, width: pillSize.width, height: pillSize.height), display: true)
    }

    // MARK: - 小动画
    private func dotColor(_ color: NSColor) { dot.layer?.backgroundColor = color.cgColor }

    private func startPulse() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.3
        a.duration = 0.6; a.autoreverses = true
        a.repeatCount = .infinity
        dot.layer?.add(a, forKey: "pulse")
    }
    private func stopPulse() { dot.layer?.removeAnimation(forKey: "pulse") }
}

/// 声波视图:一排竖条,跟随最近的音量历史跳动。
final class WaveformView: NSView {
    private var levels: [CGFloat]
    private let barCount = 22

    override init(frame frameRect: NSRect) {
        levels = Array(repeating: 0.05, count: 22)
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() { levels = Array(repeating: 0.05, count: barCount); needsDisplay = true }

    func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(max(0.05, level))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        let barW: CGFloat = 3
        let gap = (w - CGFloat(barCount) * barW) / CGFloat(barCount - 1)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        for (i, lv) in levels.enumerated() {
            let bh = max(3, lv * h)
            let x = CGFloat(i) * (barW + gap)
            let y = (h - bh) / 2
            let rect = CGRect(x: x, y: y, width: barW, height: bh)
            let path = CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
            ctx.addPath(path); ctx.fillPath()
        }
    }
}
