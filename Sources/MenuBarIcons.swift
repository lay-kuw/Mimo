import AppKit

/// メニューバーのアイコン。すべてコードで描いたオリジナルの図形。
struct MenuIconStyle {
    let id: String
    let name: String
    let frames: Int      // 1 は動かないアイコン
    let cycle: TimeInterval   // 負荷0%のときの1周の秒数
    static let all: [MenuIconStyle] = [
        MenuIconStyle(id: "heart", name: "Heart", frames: 44, cycle: 1.76),
        MenuIconStyle(id: "gauge", name: "Gauge", frames: 1, cycle: 1),
        MenuIconStyle(id: "graphs", name: "Graphs", frames: 1, cycle: 1),
    ]
    static func find(_ id: String) -> MenuIconStyle { all.first { $0.id == id } ?? all[0] }
}

enum MenuIconArt {
    static let size = CGSize(width: 28, height: 18)

    /// 28×18 の設計サイズに描く。座標は上が0。
    static func draw(_ id: String, cg: CGContext, rect: CGRect, phase: Double, load: Double, color: CGColor) {
        cg.saveGState()
        defer { cg.restoreGState() }
        let scale = min(rect.width / size.width, rect.height / size.height)
        cg.translateBy(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2)
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(color)
        cg.setStrokeColor(color)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        switch id {
        case "gauge": gauge(cg, load)
        default: heart(cg, phase)
        }
    }

    private static func line(_ cg: CGContext, _ a: CGPoint, _ b: CGPoint, _ width: CGFloat) {
        cg.setLineWidth(width)
        cg.move(to: a)
        cg.addLine(to: b)
        cg.strokePath()
    }

    /// 心拍の波形。u は 0〜1、戻り値は基準線からの高さ。
    private static func pulseShape(_ u: CGFloat) -> CGFloat {
        let keys: [(CGFloat, CGFloat)] = [(0, 0), (0.18, 0), (0.24, -0.6), (0.30, 0), (0.38, 0), (0.42, 0.7),
                                          (0.50, -3.6), (0.59, 2.5), (0.65, 0), (0.74, 0), (0.82, -1.0), (0.90, 0), (1, 0)]
        for i in 1..<keys.count where u <= keys[i].0 {
            let (x0, y0) = keys[i - 1], (x1, y1) = keys[i]
            return y0 + (y1 - y0) * (u - x0) / max(x1 - x0, 0.001)
        }
        return 0
    }

    /// ハートの中を、尾を引いた心拍の線が左から右へ流れる。線はくり抜きで描く。
    private static func heart(_ cg: CGContext, _ phase: Double) {
        let tail: CGFloat = 0.62
        let head = CGFloat(phase) * (1 + tail + 0.1) - 0.05
        // 波の山がハートの真ん中を通る瞬間に少しふくらむ
        let near = max(0, 1 - abs(head - 0.5) / 0.2)
        let s = 0.92 + 0.12 * near * near
        cg.translateBy(x: 14, y: 9.4)
        cg.scaleBy(x: s, y: s)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.move(to: CGPoint(x: 0, y: 7.6))
        cg.addCurve(to: CGPoint(x: -7.8, y: -2.2), control1: CGPoint(x: -3.2, y: 4.8), control2: CGPoint(x: -7.8, y: 1.6))
        cg.addCurve(to: CGPoint(x: 0, y: -3.2), control1: CGPoint(x: -7.8, y: -7.2), control2: CGPoint(x: -1.8, y: -7.6))
        cg.addCurve(to: CGPoint(x: 7.8, y: -2.2), control1: CGPoint(x: 1.8, y: -7.6), control2: CGPoint(x: 7.8, y: -7.2))
        cg.addCurve(to: CGPoint(x: 0, y: 7.6), control1: CGPoint(x: 7.8, y: 1.6), control2: CGPoint(x: 3.2, y: 4.8))
        cg.closePath()
        cg.fillPath()
        // 線全体を1本の太さで切り抜き、尾に向かって左右のグラデーションで薄くする
        let count = 96
        func at(_ u: CGFloat) -> CGPoint { CGPoint(x: -7.6 + 15.2 * u, y: 1.0 + pulseShape(u)) }
        let from = max(head - tail, 0), to = min(head, 1)
        if to > from {
            let line = CGMutablePath()
            line.move(to: at(from))
            var i = Int(from * CGFloat(count)) + 1
            while CGFloat(i) / CGFloat(count) < to {
                line.addLine(to: at(CGFloat(i) / CGFloat(count)))
                i += 1
            }
            line.addLine(to: at(to))
            cg.saveGState()
            cg.addPath(line.copy(strokingWithWidth: 1.25, lineCap: .round, lineJoin: .round, miterLimit: 2))
            cg.clip()
            cg.setBlendMode(.destinationOut)
            let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 0.45, 1]) {
                cg.drawLinearGradient(g, start: at(max(head - tail, -0.2)), end: at(head), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            cg.restoreGState()
        }
        cg.endTransparencyLayer()
    }

    private static func gauge(_ cg: CGContext, _ load: Double) {
        let c = CGPoint(x: 14, y: 9)
        let start = CGFloat.pi * 0.75
        let sweep = CGFloat.pi * 1.5
        cg.saveGState()
        cg.setAlpha(0.3)
        cg.setLineWidth(2.6)
        cg.addArc(center: c, radius: 7.2, startAngle: start, endAngle: start + sweep, clockwise: false)
        cg.strokePath()
        cg.restoreGState()
        let v = CGFloat(min(max(load, 0), 1))
        cg.setLineWidth(2.6)
        cg.addArc(center: c, radius: 7.2, startAngle: start, endAngle: start + max(v, 0.01) * sweep, clockwise: false)
        cg.strokePath()
        cg.fillEllipse(in: CGRect(x: c.x - 1.9, y: c.y - 1.9, width: 3.8, height: 3.8))
    }
}

/// 上が0の座標で描いて、高解像度のビットマップにする
func renderIconBitmap(size: CGSize, template: Bool = false, draw: (CGContext) -> Void) -> NSImage {
    let scale = 2
    let image = NSImage(size: size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return image }
    NSGraphicsContext.saveGraphicsState()
    let cg = gc.cgContext
    cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    rep.size = size
    image.addRepresentation(rep)
    image.isTemplate = template
    return image
}

/// 「Graphs」アイコン：SF Symbols の小さなアイコンとミニグラフ
func renderStatusGraphs(store: Store) -> NSImage {
    let t = store.theme
    let s = store.sampler
    let metrics = store.metrics.isEmpty ? ["cpu"] : store.metrics
    let cellW: CGFloat = 44, cellH: CGFloat = 18, gap: CGFloat = 3
    let width = CGFloat(metrics.count) * cellW + CGFloat(metrics.count - 1) * gap
    let netScale = max(s.downS.values.max() ?? 0, s.upS.values.max() ?? 0, 512 * 1024)
    return renderIconBitmap(size: CGSize(width: width, height: cellH)) { cg in
        for (i, m) in metrics.enumerated() {
            let r = CGRect(x: CGFloat(i) * (cellW + gap), y: 0, width: cellW, height: cellH)
            let values: [Double], color: NSColor, symbol: String
            switch m {
            case "mem": values = s.memS.last(24); color = t.memory; symbol = "memorychip"
            case "gpu": values = s.gpuS.last(24); color = t.gpu; symbol = "cube"
            case "net": values = s.downS.last(24).map { $0 / netScale }; color = t.network; symbol = "arrow.up.arrow.down"
            default: values = s.cpuS.last(24); color = t.cpu; symbol = "cpu"
            }
            let corner = min(t.corner, 5)
            let pill = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: corner, cornerHeight: corner, transform: nil)
            cg.saveGState()
            cg.addPath(pill)
            cg.setFillColor(t.isGlass ? NSColor.labelColor.cg(0.1) : t.bgTop.cg())
            cg.fillPath()
            cg.addPath(pill)
            cg.clip()
            drawGraph(cg, rect: CGRect(x: r.minX + 16, y: r.minY + 2, width: r.width - 18, height: r.height - 4), values: values, color: color, style: t.graph,
                      capacity: 24, glow: min(t.glow, 3), lineWidth: 1.2, fillAlpha: 0.55)
            cg.restoreGState()
            if !t.isGlass {
                cg.addPath(pill)
                cg.setStrokeColor(t.border.cg(0.9))
                cg.setLineWidth(0.5)
                cg.strokePath()
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let sz = img.size
                img.draw(in: CGRect(x: r.minX + 8.5 - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

/// メニューバーのアイコンを負荷に合わせた速さで動かす。
/// コマの差し替えは Core Animation に任せるので、動いている間もアプリ自身はほとんどCPUを使わない。
final class MenuBarAnimator {
    private let store: Store
    private let button: () -> NSStatusBarButton?
    private var layer: CALayer?
    private var frameKey = ""
    private var speed: Float = 1
    private var smoothedLoad = 0.0
    private var frames: [CGImage] = []
    private var cycle: TimeInterval = 1
    private var phase = 0.0
    private var phaseTime: CFTimeInterval = 0
    private var paused = false
    private let blank = NSImage(size: MenuIconArt.size)
    private static let idleFrame: TimeInterval = 0.22

    init(store: Store, button: @escaping () -> NSStatusBarButton?) {
        self.store = store
        self.button = button
    }

    private func isDark(_ b: NSStatusBarButton) -> Bool {
        b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 「Match menu bar」はメニューバーの明暗に合わせた白か黒
    private func iconColor(_ b: NSStatusBarButton) -> CGColor {
        if store.menuColor == "skin" { return store.theme.accent.cg() }
        return isDark(b) ? NSColor(white: 1, alpha: 0.92).cgColor : NSColor(white: 0, alpha: 0.82).cgColor
    }

    func invalidate() { frameKey = "" }

    /// 計測のたびに呼ばれる
    func refresh() {
        guard let b = button() else { return }
        let style = MenuIconStyle.find(store.menuIcon)
        if store.menuShowValue && style.id != "graphs" {
            b.imagePosition = .imageLeading
            b.attributedTitle = NSAttributedString(string: " " + store.menuValueText,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
        } else {
            b.imagePosition = .imageOnly
            b.title = ""
        }
        switch style.id {
        case "graphs":
            removeLayer()
            b.image = renderStatusGraphs(store: store)
        case "gauge":
            removeLayer()
            let load = store.menuLoad
            let color = iconColor(b)
            b.image = renderIconBitmap(size: MenuIconArt.size) { cg in
                MenuIconArt.draw("gauge", cg: cg, rect: CGRect(origin: .zero, size: MenuIconArt.size), phase: 0, load: load, color: color)
            }
        default:
            if b.image !== blank { b.image = blank }
            prepare(style, b)
            placeLayer(b)
            applySpeed()
        }
    }

    private func prepare(_ style: MenuIconStyle, _ b: NSStatusBarButton) {
        let key = "\(style.id)-\(store.menuColor)-\(store.theme.def.id)-\(isDark(b))"
        guard key != frameKey || layer == nil else { return }
        let color = iconColor(b)
        let images: [CGImage] = (0..<style.frames).compactMap { i in
            let img = renderIconBitmap(size: MenuIconArt.size) { cg in
                MenuIconArt.draw(style.id, cg: cg, rect: CGRect(origin: .zero, size: MenuIconArt.size),
                                 phase: Double(i) / Double(style.frames), load: 0, color: color)
            }
            return (img.representations.first as? NSBitmapImageRep)?.cgImage
        }
        removeLayer()
        frameKey = key   // removeLayer が空にするので、この後で覚える
        b.wantsLayer = true
        let l = CALayer()
        l.contentsScale = 2
        l.contentsGravity = .resizeAspect
        l.contents = images.first
        l.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        frames = images
        cycle = style.cycle
        b.layer?.addSublayer(l)
        layer = l
        speed = 1
        phase = 0
        phaseTime = CACurrentMediaTime()
        if !paused { MenuBarAnimator.run(on: l, images: images, cycle: cycle, speed: speed, phase: 0) }
    }

    private func placeLayer(_ b: NSStatusBarButton) {
        guard let l = layer else { return }
        var r = CGRect(x: (b.bounds.width - MenuIconArt.size.width) / 2, y: (b.bounds.height - MenuIconArt.size.height) / 2,
                       width: MenuIconArt.size.width, height: MenuIconArt.size.height)
        if b.imagePosition == .imageLeading, let cell = b.cell as? NSButtonCell {
            r.origin.x = cell.imageRect(forBounds: b.bounds).midX - r.width / 2
        }
        if l.frame != r {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.frame = r
            CATransaction.commit()
        }
    }

    /// 負荷0%で0.22秒/コマ、100%で0.05秒/コマ
    static func frameDuration(load: Double) -> TimeInterval {
        let l = min(max(load, 0), 1)
        return idleFrame - (idleFrame - 0.05) * pow(l, 0.7)
    }

    private func applySpeed() {
        guard let l = layer, !paused else { return }
        // 負荷の揺れで走る速さがガクッと変わらないよう、なだらかに追いかける
        smoothedLoad += (store.menuLoad - smoothedLoad) * 0.4
        let target = Float(MenuBarAnimator.idleFrame / MenuBarAnimator.frameDuration(load: smoothedLoad))
        guard abs(target - speed) / speed > 0.04 else { return }
        // 今の位置を自分で計算し、同じ位置から新しい速さで続ける
        let now = CACurrentMediaTime()
        let current = MenuBarAnimator.advance(phase: phase, from: phaseTime, to: now, speed: speed, cycle: cycle)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        MenuBarAnimator.run(on: l, images: frames, cycle: cycle, speed: target, phase: current)
        CATransaction.commit()
        phase = current
        phaseTime = now
        speed = target
    }

    static func advance(phase: Double, from: CFTimeInterval, to: CFTimeInterval, speed: Float, cycle: TimeInterval) -> Double {
        (phase + (to - from) * Double(speed) / cycle).truncatingRemainder(dividingBy: 1)
    }

    /// コマ送りのアニメーションを、1周のどこ（phase: 0〜1）からでも始められる
    static func run(on layer: CALayer, images: [Any], keyPath: String = "contents", cycle: TimeInterval, speed: Float, phase: Double) {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = images
        a.calculationMode = .discrete
        a.keyTimes = (0...images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
        a.duration = cycle / Double(speed)
        a.timeOffset = phase * a.duration
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "run")
    }

    private func removeLayer() {
        layer?.removeFromSuperlayer()
        layer = nil
        frameKey = ""
    }

    func pause() {
        paused = true
        removeLayer()
    }

    func resume() {
        paused = false
        refresh()
    }
}
