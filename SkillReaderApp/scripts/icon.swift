import AppKit
import Foundation
import CoreText

/// 程序化生成 SkillReader 1024x1024 PNG 图标（文字版，多方案）
///
/// 用法：swift icon.swift <output_path> [模式]
///   模式：pure（纯文字，默认）| bookmark（文字+书签丝带）| card（文档卡片）
///
/// 设计语义（skill 阅读器定位）：
///  - 靛蓝→紫罗兰渐变 squircle（macOS Big Sur+ 风格）
///  - 超大粗体 "Skill" 为主视觉，字母 "i" 的点替换为金色四芒星火花
///  - pure    ：干净纯文字，右上角一枚小火花点缀
///  - bookmark：金色书签丝带垂在文字后方（阅读/收藏暗示）
///  - card    ：白色圆角"文档卡片"+ 页角微卷，Skill 深色字，卡片下沿金色细线

let size = 1024
let bytesPerRow = size * 4
var pixels = [UInt8](repeating: 0, count: size * size * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: &pixels,
    width: size, height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let s = Double(size)
func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1.0) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}
let MODE = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "pure"

// MARK: - 工具函数

func fillLinearGradient(_ path: CGPath, colors: [CGColor], locations: [CGFloat], start: CGPoint, end: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(grad, start: start, end: end, options: [])
    ctx.restoreGState()
}

func fillRadialGradient(_ path: CGPath, center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat, colors: [CGColor], locations: [CGFloat]) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: innerRadius, endCenter: center, endRadius: outerRadius, options: [])
    ctx.restoreGState()
}

func roundedRect(_ rect: CGRect, r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, width: Double, color: CGColor, cap: CGLineCap = .round) {
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.move(to: P(x1, y1))
    ctx.addLine(to: P(x2, y2))
    ctx.strokePath()
    ctx.restoreGState()
}

/// 四芒星（技能火花）
func sparkle(center: CGPoint, radius: Double, color: CGColor, glow: Bool = true) {
    let r = radius
    let k = r * 0.30
    let pts = [P(0, r), P(k, k), P(r, 0), P(k, -k), P(0, -r), P(-k, -k), P(-r, 0), P(-k, k)]
    let path = CGMutablePath()
    path.move(to: P(center.x + pts[0].x, center.y + pts[0].y))
    for i in 1..<pts.count { path.addLine(to: P(center.x + pts[i].x, center.y + pts[i].y)) }
    path.closeSubpath()
    if glow {
        for (scale, alpha) in [(2.4, 0.10), (1.7, 0.16)] {
            let g = CGMutablePath()
            let pts2 = pts.map { P(center.x + $0.x * scale, center.y + $0.y * scale) }
            g.move(to: pts2[0])
            for i in 1..<pts2.count { g.addLine(to: pts2[i]) }
            g.closeSubpath()
            ctx.saveGState(); ctx.addPath(g); ctx.setFillColor(rgba(1.0, 0.85, 0.35, alpha)); ctx.fillPath(); ctx.restoreGState()
        }
    }
    ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath(); ctx.restoreGState()
}

// MARK: - CoreText 文本辅助

func makeLine(_ text: String, font: NSFont, color: CGColor) -> CTLine {
    let attr: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color
    ]
    let astr = CFAttributedStringCreate(nil, text as CFString, attr as CFDictionary)!
    return CTLineCreateWithAttributedString(astr)
}

func lineMetrics(_ line: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
    var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
    return (w, a, d)
}

func drawLineCentered(_ line: CTLine, center: CGPoint, baselineOffset: CGFloat = 0) -> CGFloat {
    let m = lineMetrics(line)
    let x = center.x - m.width / 2
    let baselineY = center.y - (m.ascent - m.descent) / 2 + baselineOffset
    ctx.textPosition = CGPoint(x: x, y: baselineY)
    CTLineDraw(line, ctx)
    return baselineY
}

/// 计算适配目标宽度的字体，返回 (font, mainLine, metrics, baselineX)
func fitText(_ text: String, targetWidth: Double, weight: NSFont.Weight, color: CGColor) -> (NSFont, CTLine, (width: CGFloat, ascent: CGFloat, descent: CGFloat), CGFloat) {
    var fontSize: Double = 300
    var font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    var ln = makeLine(text, font: font, color: color)
    var m = lineMetrics(ln)
    fontSize *= targetWidth / Double(m.width)
    font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    ln = makeLine(text, font: font, color: color)
    m = lineMetrics(ln)
    return (font, ln, m, 0)   // baselineX 由调用方按 center.x 计算
}

/// 在文字上把字母 "i" 的点替换为金色火花，返回火花中心
func sparkOnIDot(_ mainLine: CTLine, font: NSFont, baselineX: CGFloat, baselineY: CGFloat, textCenterX: Double, radiusScale: Double = 0.075) -> CGPoint {
    let m = lineMetrics(mainLine)
    let bx = textCenterX - Double(m.width) / 2
    let ctFont = font as CTFont
    let chars: [UniChar] = Array("i".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: 1)
    CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, 1)
    var bbox = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, nil, 1)
    let iStart = CGFloat(CTLineGetOffsetForStringIndex(mainLine, 2, nil))
    let iCenterX = bx + Double(iStart) + Double(bbox.width) * 0.5
    let dotH = bbox.height * 0.30
    let dotCenterY = baselineY + bbox.maxY - dotH * 0.5
    let r = Double(font.pointSize) * radiusScale
    let c = P(iCenterX, Double(dotCenterY))
    sparkle(center: c, radius: r, color: rgba(1.0, 0.83, 0.36, 1.0))
    return c
}

// MARK: - 1. 背景 squircle + 渐变

let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = roundedRect(bgRect, r: 232)
fillLinearGradient(
    bgPath,
    colors: [rgba(0.30, 0.29, 0.78), rgba(0.47, 0.27, 0.85), rgba(0.63, 0.22, 0.72)],
    locations: [0.0, 0.55, 1.0],
    start: P(0, s), end: P(s, 0)
)
fillRadialGradient(bgPath, center: P(s * 0.32, s * 1.02), innerRadius: 0, outerRadius: 900,
                   colors: [rgba(1, 1, 1, 0.16), rgba(1, 1, 1, 0.0)], locations: [0.0, 1.0])
fillRadialGradient(bgPath, center: P(s * 0.5, s * 0.55), innerRadius: 0, outerRadius: 480,
                   colors: [rgba(0.85, 0.80, 1.0, 0.28), rgba(0.85, 0.80, 1.0, 0.0)], locations: [0.0, 1.0])
fillRadialGradient(bgPath, center: P(s * 0.5, s * 0.05), innerRadius: 0, outerRadius: 620,
                   colors: [rgba(0.10, 0.08, 0.25, 0.26), rgba(0.10, 0.08, 0.25, 0.0)], locations: [0.0, 1.0])

// MARK: - 2. 按模式绘制主体

if MODE == "bookmark" {
    // ── 书签丝带（金色，垂在文字后方）──
    let ribbon = CGMutablePath()
    ribbon.move(to: P(458, 938))
    ribbon.addLine(to: P(566, 938))
    ribbon.addLine(to: P(556, 478))
    ribbon.addLine(to: P(512, 428))
    ribbon.addLine(to: P(468, 478))
    ribbon.closeSubpath()
    fillLinearGradient(ribbon,
        colors: [rgba(1.0, 0.80, 0.32, 1.0), rgba(0.94, 0.60, 0.16, 1.0)],
        locations: [0.0, 1.0], start: P(0, 938), end: P(0, 428))
    // 丝带侧缘细线（立体）
    line(458, 938, 468, 478, width: 4, color: rgba(0.72, 0.42, 0.08, 0.30))
    line(566, 938, 556, 478, width: 4, color: rgba(0.72, 0.42, 0.08, 0.30))
    // 丝带底部两角
    line(468, 478, 512, 428, width: 4, color: rgba(0.72, 0.42, 0.08, 0.30))
    line(556, 478, 512, 428, width: 4, color: rgba(0.72, 0.42, 0.08, 0.30))

    let white = rgba(1, 1, 1, 1.0)
    let (font, mainLine, m, _) = fitText("Skill", targetWidth: s * 0.80, weight: .heavy, color: white)
    let textCenter = P(s * 0.5, s * 0.55)
    let shadowLine = makeLine("Skill", font: font, color: rgba(0.05, 0.04, 0.15, 0.30))
    drawLineCentered(shadowLine, center: P(textCenter.x, textCenter.y - 14))
    let baselineY = drawLineCentered(mainLine, center: textCenter)
    let baselineX = textCenter.x - Double(m.width) / 2
    _ = sparkOnIDot(mainLine, font: font, baselineX: baselineX, baselineY: baselineY, textCenterX: textCenter.x)

} else if MODE == "card" {
    // ── 文档卡片（白色圆角 + 页角微卷）──
    let cardRect = CGRect(x: 142, y: 300, width: 740, height: 460)
    // 卡片投影
    for (dx, dy, alpha) in [(0.0, -12.0, 0.16), (0.0, -26.0, 0.10)] {
        ctx.saveGState()
        ctx.setFillColor(rgba(0.05, 0.04, 0.15, alpha))
        ctx.addPath(roundedRect(cardRect.offsetBy(dx: dx, dy: dy), r: 56))
        ctx.fillPath()
        ctx.restoreGState()
    }
    // 卡片主体
    fillLinearGradient(roundedRect(cardRect, r: 56),
        colors: [rgba(1.0, 1.0, 1.0, 1.0), rgba(0.96, 0.97, 0.99, 1.0)],
        locations: [0.0, 1.0], start: P(0, cardRect.maxY), end: P(0, cardRect.minY))
    // 页角微卷（右上角）
    let curl = CGMutablePath()
    curl.move(to: P(772, 760))
    curl.addLine(to: P(882, 648))
    curl.addLine(to: P(882, 760))
    curl.closeSubpath()
    ctx.saveGState(); ctx.addPath(curl); ctx.setFillColor(rgba(0.90, 0.92, 0.97, 1.0)); ctx.fillPath(); ctx.restoreGState()
    // 卷角折痕阴影
    line(772, 760, 882, 648, width: 5, color: rgba(0.35, 0.38, 0.55, 0.20))

    // 文字（深靛墨色）
    let ink = rgba(0.20, 0.18, 0.44, 1.0)
    let (font, mainLine, m, _) = fitText("Skill", targetWidth: 610, weight: .heavy, color: ink)
    let textCenter = P(s * 0.5, s * 0.55)
    let shadowLine = makeLine("Skill", font: font, color: rgba(0.90, 0.90, 0.96, 0.6))
    drawLineCentered(shadowLine, center: P(textCenter.x, textCenter.y - 10))
    let baselineY = drawLineCentered(mainLine, center: textCenter)
    let baselineX = textCenter.x - Double(m.width) / 2
    _ = sparkOnIDot(mainLine, font: font, baselineX: baselineX, baselineY: baselineY, textCenterX: textCenter.x)
    // 卡片下沿金色细线（markdown 分隔感，克制的一笔）
    let gy = cardRect.minY + 56
    line(462, gy, 562, gy, width: 10, color: rgba(0.96, 0.62, 0.16, 0.9), cap: .round)

} else {
    // ── 默认 pure：纯文字 ──
    let white = rgba(1, 1, 1, 1.0)
    let (font, mainLine, m, _) = fitText("Skill", targetWidth: s * 0.84, weight: .heavy, color: white)
    let textCenter = P(s * 0.5, s * 0.55)
    let shadowLine = makeLine("Skill", font: font, color: rgba(0.05, 0.04, 0.15, 0.30))
    drawLineCentered(shadowLine, center: P(textCenter.x, textCenter.y - 14))
    let baselineY = drawLineCentered(mainLine, center: textCenter)
    let baselineX = textCenter.x - Double(m.width) / 2
    _ = sparkOnIDot(mainLine, font: font, baselineX: baselineX, baselineY: baselineY, textCenterX: textCenter.x)
    // 右上角小火花点缀（呼应 i 点）
    sparkle(center: P(s * 0.72, s * 0.86), radius: 34, color: rgba(1.0, 0.88, 0.50, 0.95))
}

// MARK: - 3. 写 PNG

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try data.write(to: URL(fileURLWithPath: out))
print("✓ \(out) (\(data.count) bytes) mode=\(MODE)")
