import AppKit

/// 計測は1〜2秒おきのまま、グラフとバーの動きを Core Animation で補間する。
/// スライドやバーの伸び縮みはアプリの再描画なしで進むので、CPUをほとんど増やさない。
final class SmoothOverlay {
    private final class GraphItem {
        let host = CALayer()
        let slide = CALayer()
        let gradient = CAGradientLayer()
        let mask = CAShapeLayer()
        let line = CAShapeLayer()
        var values: [Double] = []
        var signature = ""
        var updatedAt: CFTimeInterval = 0
    }
    private final class BarItem {
        let layer = CALayer()
        var track = CGRect.null
    }

    private var graphs: [String: GraphItem] = [:]
    private var bars: [String: BarItem] = [:]
    private var usedGraphs = Set<String>()
    private var usedBars = Set<String>()
    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(),
        "strokeColor": NSNull(), "fillColor": NSNull(), "colors": NSNull(), "transform": NSNull(),
    ]

    func begin() {
        usedGraphs.removeAll(keepingCapacity: true)
        usedBars.removeAll(keepingCapacity: true)
    }

    func end() {
        for (k, g) in graphs where !usedGraphs.contains(k) {
            g.host.removeFromSuperlayer()
            graphs[k] = nil
        }
        for (k, b) in bars where !usedBars.contains(k) {
            b.layer.removeFromSuperlayer()
            bars[k] = nil
        }
    }

    func removeAll() {
        begin()
        end()
    }

    private func makeGraph(parent: CALayer, scale: CGFloat) -> GraphItem {
        let g = GraphItem()
        for l in [g.host, g.slide, g.gradient, g.mask, g.line] as [CALayer] {
            l.actions = SmoothOverlay.noActions
            l.contentsScale = scale
        }
        g.host.masksToBounds = true
        g.gradient.mask = g.mask
        g.gradient.startPoint = CGPoint(x: 0.5, y: 0)
        g.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        g.line.fillColor = nil
        g.line.lineJoin = .round
        g.line.lineCap = .round
        g.slide.addSublayer(g.gradient)
        g.slide.addSublayer(g.line)
        g.host.addSublayer(g.slide)
        parent.addSublayer(g.host)
        return g
    }

    func graph(key: String, rect: CGRect, clip: CGRect?, values: [Double], color: NSColor, style: GraphStyle,
               capacity: Int, glow: CGFloat, lineWidth: CGFloat, fillAlpha: CGFloat, fill: Bool = false,
               parent: CALayer, scale: CGFloat, duration: TimeInterval) {
        guard capacity > 1, rect.width > 3, rect.height > 3 else { return }
        usedGraphs.insert(key)
        let g = graphs[key] ?? makeGraph(parent: parent, scale: scale)
        graphs[key] = g

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let pad = max(lineWidth, glow) + 1
        var hostRect = rect.insetBy(dx: 0, dy: -pad)
        if let clip { hostRect = hostRect.intersection(clip) }
        if hostRect.isNull || hostRect.isEmpty {
            g.host.isHidden = true
            return
        }
        g.host.isHidden = false
        g.host.frame = hostRect
        g.slide.frame = CGRect(x: rect.minX - hostRect.minX, y: rect.minY - hostRect.minY, width: rect.width, height: rect.height)

        let step = rect.width / CGFloat(capacity - 1)
        let c = color.cg()
        let signature = "\(Int(rect.width))-\(Int(rect.height))-\(style.rawValue)-\(capacity)-\(glow)-\(lineWidth)-\(fillAlpha)-\(fill)-\(c.components ?? [])"
        let shapeChanged = signature != g.signature
        let valuesChanged = values != g.values
        guard shapeChanged || valuesChanged else { return }

        rebuild(g, rect: rect, values: values, color: color, style: style, capacity: capacity, step: step,
                glow: glow, lineWidth: lineWidth, fillAlpha: fillAlpha, fill: fill, pad: pad)

        // 新しい点を右の外に置き、次の計測までに滑り込ませる
        let now = CACurrentMediaTime()
        if !shapeChanged, !g.values.isEmpty, now - g.updatedAt < duration * 3 {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = step
            a.toValue = 0
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            g.slide.add(a, forKey: "slide")
        }
        g.values = values
        g.signature = signature
        g.updatedAt = now
    }

    private func rebuild(_ g: GraphItem, rect: CGRect, values: [Double], color: NSColor, style: GraphStyle, capacity: Int,
                         step: CGFloat, glow: CGFloat, lineWidth: CGFloat, fillAlpha: CGFloat, fill: Bool, pad: CGFloat) {
        let vals = Array(values.suffix(capacity + 1))
        let w = rect.width, h = rect.height
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: w - CGFloat(vals.count - 1 - i) * step, y: h - CGFloat(min(max(vals[i], 0), 1)) * h)
        }
        let margin = step + 2
        g.gradient.frame = CGRect(x: -margin, y: -pad, width: w + margin * 2, height: h + pad * 2)
        g.mask.frame = g.gradient.bounds
        g.line.frame = CGRect(x: 0, y: 0, width: w, height: h)
        var shift = CGAffineTransform(translationX: margin, y: pad)

        guard !vals.isEmpty else {
            g.line.path = nil
            g.mask.path = nil
            return
        }

        switch style {
        case .bars:
            let barW = max(1, floor(step - 1))
            let path = CGMutablePath()
            for i in 0..<vals.count {
                let p = point(i)
                let height = max(1, h - p.y)
                let r = CGRect(x: floor(p.x - barW / 2), y: h - height, width: barW, height: height)
                let c = min(barW / 2, 1.5)
                path.addRoundedRect(in: r, cornerWidth: c, cornerHeight: c, transform: shift)
            }
            g.mask.path = path
            g.gradient.colors = [color.cg(0.85), color.cg(0.85)]
            g.line.path = nil
            g.gradient.isHidden = false
        case .area, .line, .pixel:
            let line = CGMutablePath()
            line.move(to: point(0))
            if vals.count > 1 {
                for i in 1..<vals.count {
                    let a = point(i - 1), b = point(i)
                    if style == .area {
                        line.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                    } else {
                        line.addLine(to: b)
                    }
                }
                line.addLine(to: point(vals.count - 1))
            }
            g.line.path = line
            g.line.lineWidth = lineWidth
            g.line.strokeColor = color.cg()
            if glow > 0 {
                g.line.shadowColor = color.cg()
                g.line.shadowOpacity = 0.9
                g.line.shadowRadius = glow / 2
                g.line.shadowOffset = .zero
            } else {
                g.line.shadowOpacity = 0
            }
            if style == .area || fill {
                let area = CGMutablePath()
                area.addPath(line, transform: shift)
                area.addLine(to: CGPoint(x: w, y: h).applying(shift))
                area.addLine(to: CGPoint(x: point(0).x, y: h).applying(shift))
                area.closeSubpath()
                g.mask.path = area
                g.gradient.colors = [color.cg(fillAlpha), color.cg(0.02)]
                g.gradient.isHidden = false
            } else {
                g.mask.path = nil
                g.gradient.isHidden = true
            }
        }
        shift = .identity
    }

    func bar(key: String, track: CGRect, filled: CGRect, clip: CGRect?, color: NSColor, radius: CGFloat,
             parent: CALayer, scale: CGFloat, duration: TimeInterval) {
        usedBars.insert(key)
        let b: BarItem
        if let found = bars[key] {
            b = found
        } else {
            b = BarItem()
            b.layer.contentsScale = scale
            parent.addSublayer(b.layer)
            bars[key] = b
        }
        CATransaction.begin()
        defer { CATransaction.commit() }
        if let clip, !clip.contains(track) {
            CATransaction.setDisableActions(true)
            b.layer.isHidden = true
            b.track = .null
            return
        }
        b.layer.isHidden = false
        if b.track == track {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        b.layer.cornerRadius = radius
        b.layer.backgroundColor = color.cg()
        b.layer.frame = filled
        b.track = track
    }
}

extension DashboardView {
    /// なめらか表示なら補間レイヤーへ、そうでなければ通常の描画へ。ドット絵のグラフはコマ送りのまま。
    func plotGraph(rect: CGRect, values: [Double], color: NSColor, style: GraphStyle, capacity: Int,
                   glow: CGFloat = 0, lineWidth: CGFloat = 1.5, fillAlpha: CGFloat = 0.32, fillable: Bool = true) {
        // 線だけのスキンでも、設定がオンなら線の下を薄く塗る（重ねて描く補助線は除く）
        let fill = fillable && style == .line && store.graphFill
        let alpha = style == .line ? min(fillAlpha, 0.26) : fillAlpha
        guard smoothActive, style != .pixel, let parent = layer else {
            drawGraph(ctx, rect: rect, values: values, color: color, style: style, capacity: capacity,
                      glow: glow, lineWidth: lineWidth, fillAlpha: alpha, fill: fill)
            return
        }
        graphIndex += 1
        overlay.graph(key: "\(tab.rawValue)-\(perfPage.rawValue)-g\(graphIndex)", rect: rect, clip: clip, values: values, color: color, style: style,
                      capacity: capacity, glow: glow, lineWidth: lineWidth, fillAlpha: alpha, fill: fill,
                      parent: parent, scale: window?.backingScaleFactor ?? 2, duration: store.interval * 1.02)
    }

    /// 伸び縮みするバー。track は全長の枠、filled は今の値の分。
    func plotBar(track: CGRect, filled: CGRect, color: NSColor, radius: CGFloat) {
        guard smoothActive, let parent = layer else {
            ctx.addPath(rounded(filled, radius))
            ctx.setFillColor(color.cg())
            ctx.fillPath()
            return
        }
        barIndex += 1
        overlay.bar(key: "\(tab.rawValue)-\(perfPage.rawValue)-b\(barIndex)", track: track, filled: filled, clip: clip, color: color,
                    radius: min(radius, min(filled.width, filled.height) / 2),
                    parent: parent, scale: window?.backingScaleFactor ?? 2, duration: store.interval * 0.9)
    }
}
