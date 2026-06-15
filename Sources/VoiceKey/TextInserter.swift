import AppKit

/// 把文字插入到当前焦点输入框:用剪贴板 + 合成 ⌘V,完事后还原剪贴板。
/// 这样对所有 App 的输入框都通用(无需各 App 适配)。
enum TextInserter {
    @MainActor
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        // 备份原剪贴板内容
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        pasteV()

        // 稍后还原剪贴板,避免覆盖用户原有内容
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
    }

    /// 合成 Cmd+V 按键
    private static func pasteV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
