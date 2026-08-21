import AppKit
import Foundation

/// 程序化生成 SkillReader 1024x1024 PNG 图标
/// 语义：圆角方块 + 展开的书页（skill 文档）+ 品牌红代码尖括号 <>（代码/脚本）
/// 用法：swift icon.swift <output_path>

let size = 1024
let bytesPerRow = size * 4
var pixels = [UInt8](repeating: 0, count: size * size * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: &pixels,
    width: size, height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let s = Double(size)

// 1. 背景：圆角矩形 + 深蓝渐变（macOS 图标风格）
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                    cornerWidth: 230, cornerHeight: 230, transform: nil)
context.saveGState()
context.addPath(bgPath)
context.clip()
let bg = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.13, green: 0.20, blue: 0.32, alpha: 1.0),   // #21354f
        CGColor(red: 0.06, green: 0.10, blue: 0.17, alpha: 1.0)    // #101a2b
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
context.restoreGState()

// 2. 书页（展开的文档，白色）
context.saveGState()
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
// 左页
let left = CGMutablePath()
left.move(to: CGPoint(x: s*0.18, y: s*0.20))
left.addLine(to: CGPoint(x: s*0.48, y: s*0.20))
left.addLine(to: CGPoint(x: s*0.50, y: s*0.78))
left.addLine(to: CGPoint(x: s*0.18, y: s*0.78))
left.closeSubpath()
// 右页
let right = CGMutablePath()
right.move(to: CGPoint(x: s*0.52, y: s*0.78))
right.addLine(to: CGPoint(x: s*0.50, y: s*0.20))
right.addLine(to: CGPoint(x: s*0.82, y: s*0.20))
right.addLine(to: CGPoint(x: s*0.82, y: s*0.78))
right.closeSubpath()
context.addPath(left)
context.addPath(right)
context.fillPath()
// 书脊阴影线
context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
context.setLineWidth(4)
context.move(to: CGPoint(x: s*0.50, y: s*0.20))
context.addLine(to: CGPoint(x: s*0.50, y: s*0.78))
context.strokePath()
context.restoreGState()

// 3. 左页文字行（浅灰，模拟 markdown 段落）
context.saveGState()
context.setFillColor(CGColor(red: 0.45, green: 0.52, blue: 0.62, alpha: 0.85))
for (i, w) in [0.24, 0.19, 0.22].enumerated() {
    let y = s * (0.70 - Double(i) * 0.09)
    context.fill(CGRect(x: s*0.24, y: y, width: s*w, height: s*0.028))
}
context.restoreGState()

// 4. 品牌红代码尖括号 < > 叠在右页中央
context.saveGState()
let red = CGColor(red: 0.83, green: 0.25, blue: 0.23, alpha: 1.0)  // #d43f3a
context.setStrokeColor(red)
context.setLineWidth(52)
context.setLineCap(.round)
context.setLineJoin(.round)
// <
context.move(to: CGPoint(x: s*0.60, y: s*0.62))
context.addLine(to: CGPoint(x: s*0.53, y: s*0.50))
context.addLine(to: CGPoint(x: s*0.60, y: s*0.38))
// >
context.move(to: CGPoint(x: s*0.74, y: s*0.62))
context.addLine(to: CGPoint(x: s*0.81, y: s*0.50))
context.addLine(to: CGPoint(x: s*0.74, y: s*0.38))
context.strokePath()
context.restoreGState()

// 5. 写 PNG
guard let img = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try data.write(to: URL(fileURLWithPath: out))
print("✓ \(out) (\(data.count) bytes)")
