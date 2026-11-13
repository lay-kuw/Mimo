import AppKit

/// Overview のウィジェット1枚分の設定。12列のグリッドに置く。
struct WidgetConfig: Codable, Equatable {
    var kind: String
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var detail: Int      // 0 Compact, 1 Standard, 2 Detailed
    var visible: Bool

    static let columns = 12
    static let defaults: [WidgetConfig] = [
        WidgetConfig(kind: "cpu", x: 0, y: 0, w: 8, h: 6, detail: 1, visible: true),
        WidgetConfig(kind: "power", x: 8, y: 0, w: 4, h: 2, detail: 1, visible: true),
        WidgetConfig(kind: "top", x: 8, y: 2, w: 4, h: 10, detail: 1, visible: true),
        WidgetConfig(kind: "memory", x: 0, y: 6, w: 4, h: 3, detail: 1, visible: true),
        WidgetConfig(kind: "gpu", x: 4, y: 6, w: 4, h: 3, detail: 1, visible: true),
        WidgetConfig(kind: "network", x: 0, y: 9, w: 4, h: 3, detail: 1, visible: true),
        WidgetConfig(kind: "disk", x: 4, y: 9, w: 4, h: 3, detail: 1, visible: true),
    ]
    static func title(_ kind: String) -> String {
        switch kind {
        case "cpu": return "CPU"
        case "memory": return "Memory"
        case "gpu": return "GPU"
        case "network": return "Network"
        case "disk": return "Disk"
        case "power": return "Power"
        default: return "Top processes"
        }
    }
    static let detailNames = ["Compact", "Standard", "Detailed"]

    func collides(_ o: WidgetConfig) -> Bool {
        x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h
    }
}

/// 動かしたウィジェットを優先して、他を押しのけながら上に詰める
func reflowLayout(_ items: [WidgetConfig], moving: String?) -> [WidgetConfig] {
    let visible = items.filter { $0.visible }
    let hidden = items.filter { !$0.visible }
    var placed: [WidgetConfig] = []
    if let moving, let m = visible.first(where: { $0.kind == moving }) { placed.append(m) }
    let others = visible.filter { $0.kind != moving }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    for var o in others {
        o.y = 0
        while placed.contains(where: { $0.collides(o) }) { o.y += 1 }
        placed.append(o)
    }
    return placed + hidden
}

struct WidgetDrag {
    var kind: String
    var resizing: Bool
    var start: CGPoint
    var original: WidgetConfig
    var baseline: [WidgetConfig]
    var current: [WidgetConfig]
}

struct WidgetZone {
    var kind: String
    var rect: CGRect
    var handle: CGRect
}

extension DashboardView {
    func drawOverviewGrid(_ c: CGRect) {
        // 上のバー
        let barH: CGFloat = editingLayout ? 36 : 0
        if editingLayout {
            let doneR = chip("Done", x: c.maxX - 60, y: c.minY, w: 60, active: true) { [unowned self] in
                self.editingLayout = false
                self.dragState = nil
            }
            let resetW = chipWidth("Reset")
            chip("Reset", x: doneR.minX - resetW - 6, y: c.minY, w: resetW) { [unowned self] in
                self.store.layout = WidgetConfig.defaults
            }
            var x = c.minX
            let hiddenOnes = store.layout.filter { !$0.visible }
            if hiddenOnes.isEmpty {
                text("Drag to move. Drag the corner to resize.", x, c.minY + 6, t.font(11.5), t.textDim)
            }
            for w in hiddenOnes {
                let r = chip("+ " + WidgetConfig.title(w.kind), x: x, y: c.minY) { [unowned self] in
                    var all = self.store.layout
                    if let i = all.firstIndex(where: { $0.kind == w.kind }) {
                        all[i].visible = true
                        all[i].y = (all.filter { $0.visible }.map { $0.y + $0.h }.max() ?? 0)
                    }
                    self.store.layout = reflowLayout(all, moving: nil)
                }
                x = r.maxX + 5
            }
        }

        let items = (dragState?.current ?? store.layout).filter { $0.visible }
        let grid = CGRect(x: c.minX, y: c.minY + barH, width: c.width, height: c.height - barH)
        let gap: CGFloat = 12
        let rowsUsed = max(items.map { $0.y + $0.h }.max() ?? 1, 1)
        let colW = (grid.width + gap) / CGFloat(WidgetConfig.columns)
        // ドラッグ中は行の高さを固定して、手元の見た目が跳ねないようにする
        let rowH: CGFloat
        if dragState != nil {
            rowH = gridUnit.height
        } else {
            rowH = max((grid.height + gap) / CGFloat(rowsUsed), 40)
            gridUnit = CGSize(width: colW, height: rowH)
        }
        let contentH = CGFloat(rowsUsed) * rowH - gap
        let maxS = max(0, contentH - grid.height)
        maxScroll[.overview] = maxS
        let off = min(scroll[.overview] ?? 0, maxS)
        scroll[.overview] = off

        widgetZones.removeAll(keepingCapacity: true)
        ctx.saveGState()
        ctx.clip(to: grid.insetBy(dx: -2, dy: -2))
        clip = grid.insetBy(dx: -2, dy: -2)
        for w in items {
            let r = CGRect(x: grid.minX + CGFloat(w.x) * colW,
                           y: grid.minY + CGFloat(w.y) * rowH - off,
                           width: CGFloat(w.w) * colW - gap,
                           height: CGFloat(w.h) * rowH - gap)
            // レイアウト編集中はカードを押しても画面を移らない（ドラッグや編集の操作を優先する）
            if !editingLayout { addCardHit(r, kind: w.kind) }
            ctx.saveGState()
            ctx.clip(to: r.insetBy(dx: -1, dy: -1))
            drawWidget(w.kind, r, detail: WidgetDetail(rawValue: w.detail) ?? .standard)
            ctx.restoreGState()
            if editingLayout {
                drawWidgetEditor(w, r)
            } else {
                drawCardHover(r)
            }
        }
        clip = nil
        ctx.restoreGState()
    }

    func drawWidgetEditor(_ w: WidgetConfig, _ r: CGRect) {
        let moving = dragState?.kind == w.kind
        let path = rounded(r, max(t.corner - 6, 2))
        ctx.addPath(path)
        ctx.setFillColor(t.accent.cg(moving ? 0.22 : 0.08))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(t.accent.cg())
        ctx.setLineWidth(moving ? 2.5 : 1.5)
        ctx.setLineDash(phase: 0, lengths: moving ? [] : [5, 4])
        ctx.strokePath()
        ctx.restoreGState()

        // 上の帯：名前、詳細度、非表示。下の内容と重ならないよう帯で隠す
        let radius = max(t.corner - 6, 2)
        let strip = CGRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: min(33, r.height - 2))
        ctx.saveGState()
        ctx.addPath(rounded(r.insetBy(dx: 1, dy: 1), radius))
        ctx.clip()
        ctx.setFillColor(t.isGlass ? NSColor.windowBackgroundColor.cg() : t.bgTop.cg())
        ctx.fill(strip)
        ctx.setFillColor(t.accent.cg(0.14))
        ctx.fill(strip)
        ctx.restoreGState()
        text(WidgetConfig.title(w.kind), r.minX + 12, r.minY + 9, t.font(11.5, .medium), t.text, maxW: max(r.width - 150, 20))
        let closeR = CGRect(x: r.maxX - 28, y: r.minY + 6, width: 22, height: 22)
        let closeOn = isHover(closeR)
        ctx.addPath(rounded(closeR, 11))
        ctx.setFillColor(closeOn ? t.danger.cg() : t.bgTop.cg(0.95))
        ctx.fillPath()
        ctx.setStrokeColor((closeOn ? onAccent : t.danger).cg())
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: closeR.midX - 3.5, y: closeR.midY - 3.5))
        ctx.addLine(to: CGPoint(x: closeR.midX + 3.5, y: closeR.midY + 3.5))
        ctx.move(to: CGPoint(x: closeR.midX + 3.5, y: closeR.midY - 3.5))
        ctx.addLine(to: CGPoint(x: closeR.midX - 3.5, y: closeR.midY + 3.5))
        ctx.strokePath()
        addHit(closeR, label: "Hide \(WidgetConfig.title(w.kind))") { [unowned self] in
            var all = self.store.layout
            if let i = all.firstIndex(where: { $0.kind == w.kind }) { all[i].visible = false }
            self.store.layout = reflowLayout(all, moving: nil)
        }
        let label = WidgetConfig.detailNames[min(max(w.detail, 0), 2)]
        let lw = chipWidth(label)
        let chipR = CGRect(x: closeR.minX - lw - 5, y: r.minY + 6, width: lw, height: 22)
        chip(label, x: chipR.minX, y: chipR.minY, w: lw, h: 22, color: t.accent) { [unowned self] in
            var all = self.store.layout
            if let i = all.firstIndex(where: { $0.kind == w.kind }) { all[i].detail = (all[i].detail + 1) % 3 }
            self.store.layout = all
        }

        // 右下：サイズ変更のつまみ
        let handle = CGRect(x: r.maxX - 22, y: r.maxY - 22, width: 22, height: 22)
        ctx.setStrokeColor(t.accent.cg())
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        for d in [CGFloat(5), 10, 15] {
            ctx.move(to: CGPoint(x: r.maxX - 5, y: r.maxY - 5 - d))
            ctx.addLine(to: CGPoint(x: r.maxX - 5 - d, y: r.maxY - 5))
        }
        ctx.strokePath()
        widgetZones.append(WidgetZone(kind: w.kind, rect: r, handle: handle))
    }

    func beginWidgetDrag(at p: CGPoint) {
        guard let z = widgetZones.last(where: { $0.rect.contains(p) }) else { return }
        let all = store.layout
        guard let w = all.first(where: { $0.kind == z.kind }) else { return }
        dragState = WidgetDrag(kind: z.kind, resizing: z.handle.contains(p), start: p, original: w, baseline: all, current: all)
        needsDisplay = true
    }

    func updateWidgetDrag(to p: CGPoint) {
        guard var d = dragState else { return }
        let dx = Int(((p.x - d.start.x) / gridUnit.width).rounded())
        let dy = Int(((p.y - d.start.y) / gridUnit.height).rounded())
        var m = d.original
        if d.resizing {
            m.w = min(max(m.w + dx, 2), WidgetConfig.columns - m.x)
            m.h = max(m.h + dy, 2)
        } else {
            m.x = min(max(m.x + dx, 0), WidgetConfig.columns - m.w)
            m.y = max(m.y + dy, 0)
        }
        var all = d.baseline
        if let i = all.firstIndex(where: { $0.kind == m.kind }) { all[i] = m }
        d.current = reflowLayout(all, moving: m.kind)
        dragState = d
        needsDisplay = true
    }

    func endWidgetDrag() {
        guard let d = dragState else { return }
        // 動かした後の隙間を上に詰める
        store.layout = reflowLayout(d.current, moving: nil)
        dragState = nil
        needsDisplay = true
    }

    // MARK: - サイドバー

    func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let comps = color.usingColorSpace(.sRGB).map { "\($0.redComponent)-\($0.greenComponent)-\($0.blueComponent)" } ?? "x"
        let key = "\(name)-\(size)-\(comps)"
        if let img = symbolCache[key] { return img }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        if let img { symbolCache[key] = img }
        return img
    }

    func drawSymbol(_ name: String, center: CGPoint, size: CGFloat, color: NSColor) {
        guard let img = symbol(name, size: size, color: color) else { return }
        let s = img.size
        img.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    func drawSidebar() {
        let side = sideWidth
        let collapsed = store.sidebarCollapsed
        let barH = collapsed ? DashboardView.titleBarHeight : 0
        ctx.setFillColor(t.surface.cg(surfaceAlpha))
        ctx.fill(CGRect(x: 0, y: barH, width: side, height: bounds.height - barH))
        ctx.setFillColor(t.border.cg(0.7))
        ctx.fill(CGRect(x: side - 1, y: barH, width: 1, height: bounds.height - barH))
        if collapsed {
            // 信号機ボタンの段は、サイドバーとは別のバーにする
            ctx.fill(CGRect(x: 0, y: barH, width: bounds.width, height: 1))
            let titleFont = t.font(12, .medium)
            text("Mimo", 80, (barH - (titleFont.ascender - titleFont.descender)) / 2, titleFont, t.textDim)
        }


        let f = t.font(13, .medium)
        let lh = f.ascender - f.descender
        var y: CGFloat = collapsed ? barH + 12 : 46
        for tb in DashTab.allCases {
            let r = collapsed ? CGRect(x: (side - 38) / 2, y: y, width: 38, height: 36) : CGRect(x: 10, y: y, width: side - 20, height: 36)
            let active = tb == tab
            let on = isHover(r)
            if active || on {
                ctx.addPath(rounded(r, max(t.corner - 8, 2)))
                ctx.setFillColor(active ? t.accent.cg() : t.accent.cg(0.14))
                ctx.fillPath()
            }
            let color = active ? onAccent : t.text
            if collapsed {
                drawSymbol(tb.symbol, center: CGPoint(x: r.midX, y: r.midY), size: 15, color: color)
                if on { tooltip = (tb.label, r) }
            } else {
                drawSymbol(tb.symbol, center: CGPoint(x: r.minX + 20, y: r.midY), size: 14, color: color)
                text(tb.label, r.minX + 38, r.midY - lh / 2, f, color)
            }
            addHit(r, label: tb.label) { [unowned self] in self.tab = tb }
            y += 40
        }

        let s = store.sampler
        let memFrac = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        if collapsed {
            text(pct(s.cpu), side / 2, bounds.height - 50, t.font(10, .regular), t.cpu, align: .center)
            text(pct(memFrac), side / 2, bounds.height - 34, t.font(10, .regular), t.memory, align: .center)
        } else {
            text("CPU \(pct(s.cpu))", 22, bounds.height - 56, t.font(11, .regular), t.cpu)
            text("Memory \(pct(memFrac))", 22, bounds.height - 38, t.font(11, .regular), t.memory)
        }
    }

    func drawTooltip() {
        guard let tip = tooltip else { return }
        let f = t.font(11, .medium)
        let w = ceil(NSAttributedString(string: tip.text, attributes: [.font: f]).size().width) + 18
        let r = CGRect(x: tip.rect.maxX + 8, y: tip.rect.midY - 12, width: w, height: 24)
        ctx.addPath(rounded(r, 6))
        ctx.setFillColor(t.text.cg(0.95))
        ctx.fillPath()
        text(tip.text, r.midX, r.midY - (f.ascender - f.descender) / 2, f, t.isGlass ? NSColor.windowBackgroundColor : t.bgTop, align: .center)
    }

    // MARK: - 設定：メニューバー

    func drawMenuBarSettings(_ c: CGRect, y startY: CGFloat) -> CGFloat {
        var y = startY
        let gap: CGFloat = 10
        let cols = max(4, Int((c.width + gap) / 110))
        let w = (c.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let h: CGFloat = 74
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        let styles = MenuIconStyle.all
        for (i, st) in styles.enumerated() {
            let r = CGRect(x: c.minX + CGFloat(i % cols) * (w + gap), y: y + CGFloat(i / cols) * (h + gap), width: w, height: h)
            let active = store.menuIcon == st.id
            let path = rounded(r, max(t.corner - 8, 2))
            ctx.addPath(path)
            ctx.setFillColor(isHover(r) ? t.accent.cg(0.14) : t.surface.cg(surfaceAlpha))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(active ? t.accent.cg() : t.border.cg(0.7))
            ctx.setLineWidth(active ? 2.5 : 1)
            ctx.strokePath()
            let art = CGRect(x: r.midX - 28, y: r.minY + 8, width: 56, height: 36)
            let tint = active ? t.accent : t.text
            if st.id == "graphs" {
                drawGraph(ctx, rect: art.insetBy(dx: 6, dy: 8), values: DashboardView.previewWave, color: tint, style: .bars, capacity: 16)
            } else {
                MenuIconArt.draw(st.id, cg: ctx, rect: art, phase: st.frames > 1 ? phase : 0, load: store.menuLoad, color: tint.cg())
            }
            text(st.name, r.midX, r.maxY - 22, t.font(11, .medium), t.text, align: .center)
            addHit(r, label: "Menu bar icon \(st.name)") { [unowned self] in self.store.menuIcon = st.id }
        }
        y += CGFloat((styles.count + cols - 1) / cols) * (h + gap) + 6

        var x = c.minX
        if store.menuIcon == "graphs" {
            text("Show", x, y + 5, t.font(11.5, .medium), t.textDim)
            x += 42
            for (id, label) in [("cpu", "CPU"), ("mem", "Memory"), ("gpu", "GPU"), ("net", "Network")] {
                let on = store.metrics.contains(id)
                let r = chip(label, x: x, y: y, active: on) { [unowned self] in
                    var cur = self.store.metrics
                    if on {
                        if cur.count > 1 { cur.removeAll { $0 == id } }
                    } else {
                        cur = ["cpu", "mem", "gpu", "net"].filter { cur.contains($0) || $0 == id }
                    }
                    self.store.metrics = cur
                }
                x = r.maxX + 6
            }
        } else {
            let title = store.menuIcon == "gauge" ? "Shows" : "Speed follows"
            x += text(title, x, y + 5, t.font(11.5, .medium), t.textDim) + 10
            for (id, label) in [("cpu", "CPU"), ("mem", "Memory"), ("gpu", "GPU"), ("net", "Network")] {
                let r = chip(label, x: x, y: y, active: store.menuSource == id) { [unowned self] in self.store.menuSource = id }
                x = r.maxX + 6
            }
        }
        y += 36
        x = c.minX
        if store.menuIcon != "graphs" {
            x += text("Color", x, y + 5, t.font(11.5, .medium), t.textDim) + 10
            for (id, label) in [("system", "Match menu bar"), ("skin", "Skin color")] {
                let r = chip(label, x: x, y: y, active: store.menuColor == id) { [unowned self] in self.store.menuColor = id }
                x = r.maxX + 6
            }
            x += 14
            chip(store.menuShowValue ? "Show value: On" : "Show value: Off", x: x, y: y, active: store.menuShowValue) { [unowned self] in
                self.store.menuShowValue.toggle()
            }
            y += 36
        }
        return y + 8
    }
}
