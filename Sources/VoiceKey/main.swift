import AppKit

// 菜单栏常驻 App 入口(无 Dock 图标)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不在 Dock 显示,纯菜单栏
app.run()
