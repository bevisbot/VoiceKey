import AppKit

/// 全局快捷键:点按一下「右 Command」开始/结束录音(toggle)。
/// 只识别"单独点按"(按下到抬起之间没按别的键),避免 ⌘C/⌘V 等组合键误触发。
/// 用 CGEventTap 监听(只需「辅助功能」权限,和粘贴所需权限一致)。
@MainActor
final class HotKey {
    /// 一次有效的单独点按,触发切换
    var onToggle: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // 右 Command=54,左 Command=55,左 Option=58
    private let triggerKeyCode: Int64 = 54

    private var cmdHeld = false           // 右 Command 是否正按住
    private var otherKeyDuringCmd = false // 按住期间是否按了别的键

    func start() {
        // 同时监听修饰键变化和普通按键(用于判断"是否纯点按")
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let me = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
                me.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("VoiceKey 创建事件 tap 失败(多半是未授权「辅助功能」),2 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.start()
            }
            return
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("VoiceKey 事件 tap 已启动")
    }

    // 在主 run loop 线程被调用
    nonisolated private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            // 按住 Command 期间按了普通键 → 视为组合键,不算点按
            MainActor.assumeIsolated {
                if self.cmdHeld { self.otherKeyDuringCmd = true }
            }
            return
        }

        // flagsChanged:只关心右 Command
        guard keyCode == triggerKeyCode else { return }
        let isDown = event.flags.contains(.maskCommand)

        MainActor.assumeIsolated {
            if isDown {
                self.cmdHeld = true
                self.otherKeyDuringCmd = false
            } else {
                // 抬起:按住期间没按别的键 → 一次有效点按
                if self.cmdHeld && !self.otherKeyDuringCmd {
                    self.onToggle?()
                }
                self.cmdHeld = false
            }
        }
    }
}
