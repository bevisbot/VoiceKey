import AppKit

// 生成 1024x1024 的 App 图标(C 方案:紫→粉渐变 + 白色声波均衡器)
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

// 透明背景
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// macOS 风格圆角方块(留边距,占约 80%)
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: CGFloat(size) - margin * 2, height: CGFloat(size) - margin * 2)
let corner = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

// 渐变填充(紫 → 粉,左上 → 右下)
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let violet = CGColor(red: 0.545, green: 0.361, blue: 1.0, alpha: 1)   // #8b5cff
let pink   = CGColor(red: 1.0, green: 0.373, blue: 0.635, alpha: 1)   // #ff5fa2
let gradient = CGGradient(colorsSpace: cs, colors: [violet, pink] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: margin, y: CGFloat(size) - margin),         // 左上
    end: CGPoint(x: CGFloat(size) - margin, y: margin),          // 右下
    options: [])
ctx.restoreGState()

// 白色声波均衡器:5 根圆角竖条
let center = CGFloat(size) / 2
let barW: CGFloat = 70
let gap: CGFloat = 38
let heights: [CGFloat] = [170, 320, 470, 320, 170]
let totalW = barW * 5 + gap * 4
var x = center - totalW / 2
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
for h in heights {
    let bar = CGRect(x: x, y: center - h / 2, width: barW, height: h)
    let r = barW / 2
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
    x += barW + gap
}

// 输出 PNG
guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let out = URL(fileURLWithPath: "icon_1024.png")
try! png.write(to: out)
print("已生成 \(out.path)")
