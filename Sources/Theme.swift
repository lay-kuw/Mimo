import AppKit
import CoreText

enum GraphStyle: String { case area, line, bars, pixel }

/// スキンのJSON定義。id と name 以外はすべて省略できる。
struct SkinDef: Codable {
    var id: String
    var name: String
    var order: Int?
    var appearance: String?   // light / dark / auto
    var bgTop: String?
    var bgBottom: String?
    var bgAlpha: Double?
    var surface: String?
    var surfaceAlpha: Double?
    var border: String?
    var text: String?
    var textDim: String?
    var accent: String?
    var cpu: String?
    var memory: String?
    var gpu: String?
    var network: String?
    var disk: String?
    var battery: String?
    var danger: String?
    var font: String?         // rounded / mono / pixel / serif / system
    var corner: Double?
    var graph: String?        // area / line / bars / pixel
    var glow: Double?
    var scanlines: Bool?
    var material: String?     // glass
}

extension NSColor {
    static func skin(_ s: String?, _ fallback: NSColor) -> NSColor {
        guard let s else { return fallback }
        switch s {
        case "label": return .labelColor
        case "secondaryLabel": return .secondaryLabelColor
        case "separator": return .separatorColor
        default: break
        }
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255,
                       green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(alpha).cgColor
    }
}

final class Theme {
    let def: SkinDef
    let bgTop, bgBottom, surface, border, text, textDim, accent: NSColor
    let cpu, memory, gpu, network, disk, battery, danger: NSColor
    let bgAlpha, surfaceAlpha, corner, glow: CGFloat
    let graph: GraphStyle
    let scanlines, isGlass: Bool
    let appearance: NSAppearance?
    private var fontCache: [String: NSFont] = [:]

    init(_ d: SkinDef) {
        def = d
        let dark = d.appearance == "dark"
        let fgFallback: NSColor = dark ? .white : .black
        bgTop = .skin(d.bgTop, dark ? .black : .white)
        bgBottom = .skin(d.bgBottom ?? d.bgTop, dark ? .black : .white)
        surface = .skin(d.surface, dark ? .white : .black)
        border = .skin(d.border, fgFallback)
        text = .skin(d.text, fgFallback)
        textDim = .skin(d.textDim, .gray)
        accent = .skin(d.accent, .systemPink)
        cpu = .skin(d.cpu, accent)
        memory = .skin(d.memory, .systemBlue)
        gpu = .skin(d.gpu, .systemPurple)
        network = .skin(d.network, .systemGreen)
        disk = .skin(d.disk, .systemOrange)
        battery = .skin(d.battery, network)
        danger = .skin(d.danger, .systemRed)
        bgAlpha = CGFloat(d.bgAlpha ?? 1)
        surfaceAlpha = CGFloat(d.surfaceAlpha ?? 0.08)
        corner = CGFloat(d.corner ?? 14)
        glow = CGFloat(d.glow ?? 0)
        graph = GraphStyle(rawValue: d.graph ?? "area") ?? .area
        scanlines = d.scanlines ?? false
        isGlass = d.material == "glass"
        switch d.appearance {
        case "dark": appearance = NSAppearance(named: .darkAqua)
        case "light": appearance = NSAppearance(named: .aqua)
        default: appearance = nil
        }
    }

    private static var pixelFontRegistered = false
    private static func registerPixelFont() {
        guard !pixelFontRegistered else { return }
        pixelFontRegistered = true
        if let url = Bundle.main.url(forResource: "DotGothic16-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let key = "\(size)-\(weight.rawValue)"
        if let f = fontCache[key] { return f }
        let f = makeFont(size, weight)
        fontCache[key] = f
        return f
    }

    private func cascade(_ base: NSFont, _ names: [String], _ size: CGFloat, tabular: Bool) -> NSFont {
        var attrs: [NSFontDescriptor.AttributeName: Any] = [
            .cascadeList: names.map { NSFontDescriptor(name: $0, size: size) }
        ]
        if tabular {
            // kNumberSpacingType / kMonospacedNumbersSelector：数字の幅を揃えて表示のガタつきを防ぐ
            attrs[.featureSettings] = [[NSFontDescriptor.FeatureKey.typeIdentifier: 6,
                                        NSFontDescriptor.FeatureKey.selectorIdentifier: 0]]
        }
        return NSFont(descriptor: base.fontDescriptor.addingAttributes(attrs), size: size) ?? base
    }

    private func makeFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        switch def.font ?? "system" {
        case "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            let r = NSFont(descriptor: desc, size: size) ?? base
            return cascade(r, ["HiraMaruProN-W4"], size, tabular: true)
        case "mono":
            return cascade(.monospacedSystemFont(ofSize: size, weight: weight), ["HiraginoSans-W4"], size, tabular: false)
        case "pixel":
            Theme.registerPixelFont()
            if let p = NSFont(name: "DotGothic16-Regular", size: size + 1) { return p }
            if let s = NSFont(name: "Silom", size: size) { return cascade(s, ["Osaka-Mono"], size, tabular: false) }
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case "serif", "mincho":
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return cascade(NSFont(descriptor: desc, size: size) ?? base, ["HiraMinProN-W3"], size, tabular: true)
        default:
            return cascade(.systemFont(ofSize: size, weight: weight), ["HiraginoSans-W4"], size, tabular: true)
        }
    }
}

/// パネル、メニューバー、スキン見本で共用するグラフ描画。座標系はすべて上が0のフリップ前提。
func drawGraph(_ cg: CGContext, rect: CGRect, values: [Double], color: NSColor, style: GraphStyle,
               capacity: Int, glow: CGFloat = 0, lineWidth: CGFloat = 1.5, fillAlpha: CGFloat = 0.32, fill: Bool = false) {
    guard capacity > 1, !values.isEmpty, rect.height > 3, rect.width > 3 else { return }
    let vals = Array(values.suffix(capacity))
    let step = rect.width / CGFloat(capacity - 1)
    func pt(_ i: Int) -> CGPoint {
        let x = rect.maxX - CGFloat(vals.count - 1 - i) * step
        let v = CGFloat(min(max(vals[i], 0), 1))
        return CGPoint(x: x, y: rect.maxY - v * rect.height)
    }
    cg.saveGState()
    defer { cg.restoreGState() }
    cg.clip(to: rect)

    switch style {
    case .area, .line:
        let line = CGMutablePath()
        line.move(to: pt(0))
        if vals.count > 1 {
            for i in 1..<vals.count {
                let a = pt(i - 1), b = pt(i)
                if style == .area {
                    line.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                } else {
                    line.addLine(to: b)
                }
            }
            line.addLine(to: pt(vals.count - 1))
        }
        if style == .area || fill {
            let fill = line.mutableCopy()!
            fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            fill.addLine(to: CGPoint(x: pt(0).x, y: rect.maxY))
            fill.closeSubpath()
            cg.saveGState()
            cg.addPath(fill)
            cg.clip()
            let sp = CGColorSpace(name: CGColorSpace.sRGB)
            if let g = CGGradient(colorsSpace: sp, colors: [color.cg(fillAlpha), color.cg(0.02)] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            }
            cg.restoreGState()
        }
        if glow > 0 { cg.setShadow(offset: .zero, blur: glow, color: color.cg(0.9)) }
        cg.addPath(line)
        cg.setStrokeColor(color.cg())
        cg.setLineWidth(lineWidth)
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        cg.strokePath()
    case .bars:
        let w = max(1, floor(step - 1))
        if glow > 0 { cg.setShadow(offset: .zero, blur: glow, color: color.cg(0.7)) }
        cg.setFillColor(color.cg(0.85))
        for i in 0..<vals.count {
            let p = pt(i)
            let h = max(1, rect.maxY - p.y)
            let r = CGRect(x: floor(p.x - w / 2), y: rect.maxY - h, width: w, height: h)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: min(w / 2, 1.5), cornerHeight: min(w / 2, 1.5), transform: nil))
        }
        cg.fillPath()
    case .pixel:
        let block: CGFloat = rect.height < 24 ? 2 : 3
        let gap: CGFloat = 1
        let unit = block + gap
        let cols = Int(rect.width / unit)
        let rowsMax = Int(rect.height / unit)
        guard cols > 0, rowsMax > 0 else { return }
        if glow > 0 { cg.setShadow(offset: .zero, blur: glow, color: color.cg(0.8)) }
        cg.setFillColor(color.cg())
        let blocks = CGMutablePath()
        for c in 0..<cols {
            let idx = vals.count - 1 - Int(Double(c) * Double(capacity) / Double(cols))
            guard idx >= 0 else { break }
            let v = min(max(vals[idx], 0), 1)
            let rows = max(1, Int((v * Double(rowsMax)).rounded()))
            let x = rect.maxX - CGFloat(c + 1) * unit
            for r in 0..<rows {
                blocks.addRect(CGRect(x: x, y: rect.maxY - CGFloat(r + 1) * unit, width: block, height: block))
            }
        }
        cg.addPath(blocks)
        cg.fillPath()
    }
}
