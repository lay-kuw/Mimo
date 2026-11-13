import AppKit

enum SettingsPage: String, CaseIterable {
    case appearance, menuBar, panel, window, general
    var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .menuBar: return "Menu Bar"
        case .panel: return "Panel"
        case .window: return "Window"
        case .general: return "General"
        }
    }
}

enum DashTab: String, CaseIterable {
    case overview, performance, processes, settings
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .performance: return "waveform.path.ecg"
        case .processes: return "list.bullet"
        case .settings: return "gearshape"
        }
    }
    var label: String {
        switch self {
        case .overview: return "Overview"
        case .performance: return "Performance"
        case .processes: return "Processes"
        case .settings: return "Settings"
        }
    }
}

/// メニューバーのパネル、常に手前のパネル、アプリウィンドウを CoreGraphics で直接描く。
/// サブビューを持たないのでメモリが小さく、見えていない間は一切描画しない。
final class DashboardView: NSView {
    /// tray：メニューバーのパネル / float：常に手前に出すパネル / window：アプリウィンドウ
    enum Mode { case tray, float, window }
    static let trayWidth: CGFloat = 360
    static let floatWidth: CGFloat = 248
    static let trayHeight: CGFloat = 536
    var sideWidth: CGFloat { store.sidebarCollapsed ? 52 : 172 }
    /// サイドバーを閉じると、信号機ボタンは専用の細いバーに置く
    static let titleBarHeight: CGFloat = 34

    // Performance 画面
    var perfPage: PerfPage = .cpu
    /// % や温度の数字の太さ
    static var valueWeight: NSFont.Weight = .regular
    var settingsPage: SettingsPage = .appearance
    // Overview のカスタマイズ
    var editingLayout = false
    var dragState: WidgetDrag? = nil
    var widgetZones: [WidgetZone] = []
    var gridUnit = CGSize(width: 1, height: 1)
    var symbolCache: [String: NSImage] = [:]
    // スライダー（1つの画面に1つ）。sliderSet はつまみの位置（0〜1）を受け取る
    var sliderTrack: CGRect? = nil
    var sliderSet: ((Double) -> Void)? = nil
    var sliderDragging = false
    var surfaceAlpha: CGFloat { t.surfaceAlpha * CGFloat(1 - store.transparency) }
    // なめらか表示
    let overlay = SmoothOverlay()
    var smoothActive = false
    var graphIndex = 0
    var barIndex = 0
    var tooltip: (text: String, rect: CGRect)? = nil

    /// クリックできる場所。label は読み上げとキーボード操作で使う名前、pointer は指差しカーソルを出すかどうか
    struct Hit {
        var rect: CGRect
        var label: String
        var pointer: Bool
        var action: () -> Void
        /// スライダーなど値を持つ操作：読み上げる今の値と、1段階ずつ増減する処理
        var value: String? = nil
        var adjust: ((Int) -> Void)? = nil
    }
    enum KillState {
        case confirm
        /// 終了を頼んだ相手と時刻（強制終了の前に、同じプロセスか確かめる）。一部だけ頼めなかった時はその理由も持つ
        case sent(Date, [QuitTarget], String?)
        /// うまくいかなかった理由をしばらく出す
        case failed(String, Date)
    }
    enum Align { case left, right, center }

    let store: Store
    let mode: Mode
    var tab: DashTab = .overview {
        didSet {
            if oldValue != tab {
                killStates.removeAll()
                focusIndex = nil
            }
            if tab != .overview { editingLayout = false }
        }
    }
    /// メニューバーのパネルのカードが押された時の行き先（App がウィンドウを開いて表示する）
    var onNavigate: ((Destination) -> Void)?
    /// パネルで Esc が押された時
    var onDismiss: (() -> Void)?
    /// プロセスの終了に使う OS 操作（テストで差し替える）
    var processControl = ProcessControl.live
    /// キーボードで選んでいる場所（hits の番号）
    var focusIndex: Int? = nil
    private var pointerShown = false
    var hits: [Hit] = []
    var hover: CGPoint? = nil
    var lastHoverKey = -1
    var clip: CGRect? = nil
    var scroll: [DashTab: CGFloat] = [:]
    var maxScroll: [DashTab: CGFloat] = [:]
    var killStates: [String: KillState] = [:]
    var iconCache: [String: NSImage] = [:]
    var ctx: CGContext!
    var t: Theme { store.theme }

    init(store: Store, mode: Mode, frame: NSRect) {
        self.store = store
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        // マウスが動くたびに描き直すと重いので、見た目が変わる時だけ描き直す
        let key = hoverKey(p)
        if key != lastHoverKey {
            lastHoverKey = key
            needsDisplay = true
        }
        updateCursor(at: p)
    }
    /// 押すと画面が移るカードの上では指差しカーソルにする
    func updateCursor(at p: CGPoint?) {
        let want = p.flatMap { pt in hits.last(where: { $0.rect.contains(pt) }) }?.pointer ?? false
        guard want != pointerShown else { return }
        pointerShown = want
        (want ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    var wantsPointer: Bool { pointerShown }
    func hoverKey(_ p: CGPoint) -> Int {
        let hit = hits.lastIndex(where: { $0.rect.contains(p) }) ?? -1
        var extra = 0
        switch tab {
        case .processes: extra = Int(p.y / 8)
        default: break
        }
        return (hit + 1) * 100_000_000 + extra
    }
    override func mouseExited(with event: NSEvent) {
        hover = nil
        lastHoverKey = -1
        updateCursor(at: nil)
        needsDisplay = true
    }
    func setSlider(at p: CGPoint) {
        guard let track = sliderTrack else { return }
        sliderSet?(Double(min(max((p.x - track.minX) / track.width, 0), 1)))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if tab == .settings, mode == .window, let track = sliderTrack, track.insetBy(dx: -10, dy: -10).contains(p) {
            sliderDragging = true
            setSlider(at: p)
            needsDisplay = true
            return
        }
        if performClick(at: p) {
            return
        } else if editingLayout && tab == .overview && mode == .window {
            beginWidgetDrag(at: p)
        } else if mode == .window {
            window?.performDrag(with: event)
        }
    }

    /// その位置のいちばん上にあるクリック場所を押す。カードの中の個別の操作は、カード全体より後に登録するので優先される
    @discardableResult
    func performClick(at p: CGPoint) -> Bool {
        guard let h = hits.last(where: { $0.rect.contains(p) }) else { return false }
        h.action()
        needsDisplay = true
        return true
    }

    // MARK: - キーボード

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 48: // Tab
            moveFocus(by: shift ? -1 : 1)
        case 36, 76, 49: // Return / Enter / Space
            if let i = focusIndex, i < hits.count {
                hits[i].action()
                needsDisplay = true
            }
        case 123, 124, 125, 126: // ← → ↓ ↑
            let up = event.keyCode == 123 || event.keyCode == 126
            if let i = focusIndex, i < hits.count, let adjust = hits[i].adjust {
                adjust(up ? -1 : 1)
                needsDisplay = true
            } else if event.keyCode == 125 || event.keyCode == 126 {
                scrollBy(up ? -34 : 34)
            }
        case 116, 121: // Page Up / Page Down
            scrollBy(event.keyCode == 116 ? -bounds.height * 0.8 : bounds.height * 0.8)
        case 53: // Esc
            if editingLayout {
                editingLayout = false
                dragState = nil
                needsDisplay = true
            } else if mode == .tray {
                onDismiss?()
            } else if focusIndex != nil {
                focusIndex = nil
                needsDisplay = true
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// キーボードでの一覧のスクロール。見えている行の操作は Tab で選べる
    func scrollBy(_ dy: CGFloat) {
        let cur = scroll[tab] ?? 0
        scroll[tab] = min(max(cur + dy, 0), maxScroll[tab] ?? 0)
        focusIndex = nil
        needsDisplay = true
    }

    func moveFocus(by step: Int) {
        guard !hits.isEmpty else { return }
        let n = hits.count
        if let i = focusIndex {
            focusIndex = ((i + step) % n + n) % n
        } else {
            focusIndex = step > 0 ? 0 : n - 1
        }
        needsDisplay = true
    }

    /// ⌘1〜⌘4 で画面を切り替える
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard mode == .window, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= DashTab.allCases.count else {
            return super.performKeyEquivalent(with: event)
        }
        tab = DashTab.allCases[n - 1]
        needsDisplay = true
        return true
    }

    // MARK: - 読み上げ（VoiceOver）

    private final class HitElement: NSAccessibilityElement {
        var press: (() -> Void)?
        var adjust: ((Int) -> Void)?
        override func accessibilityPerformPress() -> Bool {
            press?()
            return true
        }
        override func accessibilityPerformIncrement() -> Bool {
            adjust?(1)
            return adjust != nil
        }
        override func accessibilityPerformDecrement() -> Bool {
            adjust?(-1)
            return adjust != nil
        }
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        switch mode {
        case .tray: return "Mimo panel"
        case .float: return "Mimo floating panel"
        case .window: return "Mimo \(tab.label)"
        }
    }
    override func accessibilityChildren() -> [Any]? {
        hits.map { h in
            let e = HitElement()
            e.setAccessibilityRole(h.adjust != nil ? .slider : .button)
            e.setAccessibilityLabel(h.label)
            if let v = h.value { e.setAccessibilityValue(v) }
            if let adjust = h.adjust {
                e.adjust = { [weak self] step in
                    adjust(step)
                    self?.needsDisplay = true
                }
            }
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(h.rect)
            e.press = { [weak self] in
                h.action()
                self?.needsDisplay = true
            }
            return e
        }
    }

    // MARK: - 画面の移動

    /// カードを押した時の移動。ウィンドウでは同じウィンドウの中で切り替え、パネルでは App に任せる
    func navigate(to d: Destination) {
        if isPanel {
            onNavigate?(d)
        } else {
            show(d)
        }
    }

    /// 行き先の画面を出して、その画面のスクロールを先頭に戻す
    func show(_ d: Destination) {
        editingLayout = false
        dragState = nil
        switch d {
        case .performance(let page):
            tab = .performance
            perfPage = page
            scroll[.performance] = 0
        case .processes:
            tab = .processes
            scroll[.processes] = 0
        }
        focusIndex = nil
        needsDisplay = true
    }

    /// カード全体を押せる場所にする。中の個別の操作はこの後に登録するので、そちらが優先される
    func addCardHit(_ r: CGRect, kind: String) {
        let d = Destination.forCard(kind)
        addHit(r, label: "\(WidgetConfig.title(kind)), open \(d.label)", pointer: true) { [unowned self] in self.navigate(to: d) }
    }

    /// カードの上にいる時（中の個別の操作の上ではない時）だけ、控えめに強調する
    func drawCardHover(_ r: CGRect) {
        guard let h = hover, isHover(r), let top = hits.last(where: { $0.rect.contains(h) }), top.pointer, top.rect == (clip.map { r.intersection($0) } ?? r) else { return }
        let path = rounded(r, max(t.corner - 6, 2))
        ctx.addPath(path)
        ctx.setFillColor(t.accent.cg(0.05))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(t.accent.cg(0.55))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }

    /// キーボードで選んでいる場所の枠
    func drawFocusRing() {
        guard let i = focusIndex, i < hits.count else { return }
        let r = hits[i].rect.insetBy(dx: -2, dy: -2)
        ctx.addPath(rounded(r, max(t.corner - 4, 4)))
        ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokePath()
    }
    override func mouseDragged(with event: NSEvent) {
        if sliderDragging {
            setSlider(at: convert(event.locationInWindow, from: nil))
            needsDisplay = true
            return
        }
        guard dragState != nil else { return }
        updateWidgetDrag(to: convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        sliderDragging = false
        if dragState != nil { endWidgetDrag() }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        let cur = scroll[tab] ?? 0
        scroll[tab] = min(max(cur - delta, 0), maxScroll[tab] ?? 0)
        needsDisplay = true
    }

    func releaseCaches() { iconCache.removeAll() }

    // MARK: - 描画の部品

    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor,
                      align: Align = .left, maxW: CGFloat? = nil, glow: Bool = false) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if t.def.font == "pixel" { attrs[.kern] = 0.8 } // ドット文字は字間を少し空けると読みやすい
        let a = NSAttributedString(string: s, attributes: attrs)
        let sz = a.size()
        let w = maxW.map { min($0, ceil(sz.width)) } ?? ceil(sz.width)
        var ox = x
        switch align {
        case .left: break
        case .right: ox = x - w
        case .center: ox = x - w / 2
        }
        ctx.saveGState()
        if glow && t.glow > 0 { ctx.setShadow(offset: .zero, blur: t.glow, color: color.cg(0.8)) }
        if maxW != nil {
            a.draw(with: CGRect(x: ox, y: y, width: w, height: ceil(sz.height) + 2),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        } else {
            a.draw(at: CGPoint(x: ox, y: y))
        }
        ctx.restoreGState()
        return w
    }

    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let c = min(radius, min(r.width, r.height) / 2)
        return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
    }

    /// メニューバーのパネルか、常に手前のパネル（どちらもカードを縦に並べる）
    var isPanel: Bool { mode != .window }
    var panelWidth: CGFloat { mode == .float ? DashboardView.floatWidth : DashboardView.trayWidth }
    var panelItems: [String] { mode == .float ? store.floatItems : store.trayItems }
    var panelFramed: Bool { mode == .float ? store.floatFrame : store.trayFrame }

    /// 枠なしのパネルでは、カードが背景の代わりになる
    var framelessTray: Bool { isPanel && !panelFramed }

    func card(_ r: CGRect) {
        let path = rounded(r, max(t.corner - 6, 2))
        if framelessTray {
            let a = (t.isGlass ? 0.85 : t.bgAlpha) * CGFloat(1 - store.transparency)
            ctx.addPath(path)
            ctx.setFillColor((t.isGlass ? NSColor.windowBackgroundColor : t.bgTop).cg(a))
            ctx.fillPath()
        }
        ctx.addPath(path)
        ctx.setFillColor(t.surface.cg(surfaceAlpha))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(t.border.cg(0.7))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    func addHit(_ r: CGRect, label: String = "Button", pointer: Bool = false, value: String? = nil,
                adjust: ((Int) -> Void)? = nil, _ action: @escaping () -> Void) {
        let rect = clip.map { r.intersection($0) } ?? r
        if !rect.isNull && !rect.isEmpty {
            hits.append(Hit(rect: rect, label: label, pointer: pointer, action: action, value: value, adjust: adjust))
        }
    }
    /// 次に登録する場所がキーボードで選ばれているか
    var nextHitFocused: Bool { focusIndex == hits.count }

    func isHover(_ r: CGRect) -> Bool {
        guard let h = hover, r.contains(h) else { return false }
        if let c = clip, !c.contains(h) { return false }
        return true
    }

    var onAccent: NSColor { t.isGlass ? .white : t.bgTop }

    func chipWidth(_ label: String) -> CGFloat {
        ceil(NSAttributedString(string: label, attributes: [.font: t.font(11.5, .medium)]).size().width) + 24
    }

    @discardableResult
    func chip(_ label: String, x: CGFloat, y: CGFloat, w: CGFloat? = nil, h: CGFloat = 26, active: Bool = false, color: NSColor? = nil, action: @escaping () -> Void) -> CGRect {
        let f = t.font(11.5, .medium)
        let r = CGRect(x: x, y: y, width: w ?? chipWidth(label), height: h)
        let tint = color ?? t.accent
        let path = rounded(r, max(t.corner - 8, 2))
        ctx.addPath(path)
        if active {
            ctx.setFillColor(tint.cg())
        } else {
            ctx.setFillColor(isHover(r) ? tint.cg(0.18) : t.surface.cg(surfaceAlpha))
        }
        ctx.fillPath()
        if !active {
            ctx.addPath(path)
            ctx.setStrokeColor((color ?? t.border).cg(0.7))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        let lh = f.ascender - f.descender
        text(label, r.midX, r.midY - lh / 2, f, active ? onAccent : (color ?? t.text), align: .center)
        addHit(r, label: label, action)
        return r
    }

    /// スライダー。0 から maxValue までを step 刻みで動かす。戻り値は溝の枠
    @discardableResult
    func slider(_ label: String, x: CGFloat, y: CGFloat, maxValue: Double, step: Double,
                read: @escaping () -> Double, write: @escaping (Double) -> Void) -> CGRect {
        let track = CGRect(x: x + 8, y: y + 7, width: 240, height: 6)
        let value = min(max(read(), 0), maxValue)
        let percent = Int((value * 100).rounded())
        let steps = (maxValue / step).rounded()
        sliderTrack = track
        sliderSet = { pos in
            let v = (pos * steps).rounded() * step
            if abs(v - read()) > 0.001 { write(v) }
        }
        addHit(track.insetBy(dx: -10, dy: -8), label: label, value: "\(percent)%",
               adjust: { n in write(min(max(read() + Double(n) * step, 0), maxValue)) }) { }
        let frac = CGFloat(value / maxValue)
        ctx.addPath(rounded(track, 3))
        ctx.setFillColor(t.textDim.cg(0.3))
        ctx.fillPath()
        ctx.addPath(rounded(CGRect(x: track.minX, y: track.minY, width: track.width * frac, height: 6), 3))
        ctx.setFillColor(t.accent.cg())
        ctx.fillPath()
        let knob = CGRect(x: track.minX + track.width * frac - 8, y: track.midY - 8, width: 16, height: 16)
        ctx.setFillColor(t.accent.cg())
        ctx.fillEllipse(in: knob)
        ctx.setStrokeColor(t.bgTop.cg())
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: knob.insetBy(dx: 2, dy: 2))
        text("\(percent)%", track.maxX + 18, y + 2, t.font(12, .regular), t.text)
        return track
    }

    /// チェックボックスとラベル。戻り値は押せる範囲
    @discardableResult
    func checkbox(_ label: String, x: CGFloat, y: CGFloat, on: Bool, action: @escaping () -> Void) -> CGRect {
        let f = t.font(12, .regular)
        let lh = f.ascender - f.descender
        let labelW = ceil(NSAttributedString(string: label, attributes: [.font: f]).size().width)
        let box = CGRect(x: x, y: y + 4, width: 16, height: 16)
        let r = CGRect(x: x, y: y, width: 16 + 8 + labelW + 12, height: 24)
        let path = rounded(box, min(max(t.corner / 4, 1), 4))
        ctx.addPath(path)
        if on {
            ctx.setFillColor(t.accent.cg())
        } else {
            ctx.setFillColor(isHover(r) ? t.accent.cg(0.18) : t.surface.cg(surfaceAlpha))
        }
        ctx.fillPath()
        if on {
            ctx.setStrokeColor(onAccent.cg())
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: box.minX + 4, y: box.midY + 0.5))
            ctx.addLine(to: CGPoint(x: box.minX + 7, y: box.maxY - 4.5))
            ctx.addLine(to: CGPoint(x: box.maxX - 4, y: box.minY + 4.5))
            ctx.strokePath()
        } else {
            ctx.addPath(path)
            ctx.setStrokeColor(t.border.cg(0.9))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        text(label, box.maxX + 8, box.midY - lh / 2, f, t.text)
        addHit(r, label: label, value: on ? "On" : "Off", action)
        return r
    }

    func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: - 全体

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        ctx = c
        hits.removeAll(keepingCapacity: true)
        clip = nil
        tooltip = nil
        // カスタマイズ中は編集用の帯をグラフの上に重ねるので、普通に描く
        smoothActive = store.smoothMotion && window != nil && !(editingLayout && tab == .overview)
        graphIndex = 0
        barIndex = 0
        overlay.begin()
        defer { overlay.end() }
        drawBackground()
        if isPanel {
            drawTray()
        } else {
            drawSidebar()
            let side = sideWidth
            let collapsed = store.sidebarCollapsed
            let top: CGFloat = collapsed ? DashboardView.titleBarHeight + 12 : 18
            let pad: CGFloat = collapsed ? 12 : 16
            let content = CGRect(x: side + pad, y: top, width: bounds.width - side - pad * 2, height: bounds.height - top - 16)
            switch tab {
            case .overview: drawOverviewGrid(content)
            case .performance: drawPerformance(content)
            case .processes: drawApps(content)
            case .settings: drawSettings(content)
            }
        }
        drawTooltip()
        if let i = focusIndex, i >= hits.count { focusIndex = hits.isEmpty ? nil : hits.count - 1 }
        drawFocusRing()
        if t.scanlines {
            ctx.setFillColor(NSColor.black.cg(0.14))
            var y: CGFloat = 0
            while y < bounds.height {
                ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: 1))
                y += 3
            }
        }
    }

    func drawBackground() {
        let isTray = isPanel
        let path = isTray ? rounded(bounds, t.corner) : CGPath(rect: bounds, transform: nil)
        if framelessTray { return }
        let bgAlpha = t.bgAlpha * CGFloat(1 - store.transparency)
        if bgAlpha > 0 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let sp = CGColorSpace(name: CGColorSpace.sRGB)
            if let g = CGGradient(colorsSpace: sp, colors: [t.bgTop.cg(bgAlpha), t.bgBottom.cg(bgAlpha)] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
            }
            ctx.restoreGState()
        }
        if isTray {
            ctx.addPath(rounded(bounds.insetBy(dx: 0.5, dy: 0.5), t.corner))
            ctx.setStrokeColor(t.border.cg(0.9))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    // MARK: - メニューバーのパネル

    /// パネルが画面からはみ出さないための上限（開く時に画面の高さから決める）
    static var trayMaxHeight: CGFloat = 10_000

    static func trayCoreRows(_ n: Int) -> Int { n == 0 || n > 24 ? 0 : Int(ceil(Double(n) / 8)) }
    /// Detailed のコアのマス目の列数（メニューバーでコアが多い時は細かくして縦に伸びすぎないようにする）
    static func coreColumns(_ n: Int, width: CGFloat, tray: Bool) -> Int {
        max(1, min(n, Int((width + 6) / (tray && n > 12 ? 50 : 66))))
    }

    func trayCardHeight(_ k: String, _ d: WidgetDetail) -> CGFloat {
        // 常に手前のパネルは、どのカードも「値 + 小さなグラフ」の同じ高さ
        if mode == .float { return k == "top" ? 100 : 70 }
        let n = store.sampler.coreLoads.count
        switch d {
        case .compact:
            return k == "top" ? 100 : (k == "power" ? 70 : (k == "cpu" ? 76 : 68))
        case .standard:
            if k == "cpu" {
                if n > 24 { return 42 + 46 + 6 + 24 + 10 }
                let rows = CGFloat(DashboardView.trayCoreRows(n))
                return 42 + 46 + 6 + rows * 32 + max(rows - 1, 0) * 5 + 10
            }
            return k == "power" ? 56 : (k == "top" ? 122 : 92)
        case .detailed:
            if k == "cpu" {
                let cols = DashboardView.coreColumns(n, width: panelWidth - 24 - 24, tray: true)
                let rows = n == 0 ? 0 : CGFloat(Int(ceil(Double(n) / Double(cols))))
                return 42 + 52 + rows * 46 + 33
            }
            if k == "power" {
                let b = store.sampler.battery
                let extra = (b?.charging == true && b?.chargeWatts != nil ? 1 : 0) + (b?.inputWatts != nil ? 1 : 0)
                return 136 + CGFloat(store.sampler.fans.count + extra) * 17
            }
            return k == "top" ? 150 : 168
        }
    }

    /// 選んだカードを上から並べる。メモリ、GPU、通信、ディスクは2つ続けば横に並べる
    func trayLayout() -> (items: [(kind: String, rect: CGRect, detail: WidgetDetail)], height: CGFloat) {
        // 常に手前のパネルは専用の小さなグラフ付きカードで描く（drawFloatCard）。詳しさの設定は使わない
        let base: WidgetDetail = mode == .float ? .compact : (WidgetDetail(rawValue: store.trayDetail) ?? .standard)
        let wanted = panelItems
        let chosen = Store.allTrayItems.filter { wanted.contains($0) }
        var details = Dictionary(uniqueKeysWithValues: chosen.map { ($0, base) })
        var result = trayLayout(chosen, details)
        if base == .detailed {
            for k in ["top", "power", "network", "disk", "gpu", "memory", "cpu"] where result.height > DashboardView.trayMaxHeight {
                guard details[k] != nil else { continue }
                details[k] = .standard
                result = trayLayout(chosen, details)
            }
        }
        return result
    }

    private func trayLayout(_ chosen: [String], _ details: [String: WidgetDetail]) -> (items: [(kind: String, rect: CGRect, detail: WidgetDetail)], height: CGFloat) {
        let m: CGFloat = 12, gap: CGFloat = 8
        let top: CGFloat = panelFramed ? 12 : 4
        let full = panelWidth - m * 2
        let half = (full - gap) / 2
        // 常に手前のパネルは幅が狭いので、横には並べず1枚ずつ縦に積む
        let halves: Set<String> = mode == .float ? [] : ["memory", "gpu", "network", "disk"]
        var out: [(kind: String, rect: CGRect, detail: WidgetDetail)] = []
        var y = top
        var i = 0
        while i < chosen.count {
            let k = chosen[i]
            let d = details[k] ?? .standard
            if halves.contains(k), i + 1 < chosen.count, halves.contains(chosen[i + 1]) {
                let k2 = chosen[i + 1]
                let d2 = details[k2] ?? .standard
                // 横に並ぶ2枚は高さを揃える
                let h = max(trayCardHeight(k, d), trayCardHeight(k2, d2))
                out.append((k, CGRect(x: m, y: y, width: half, height: h), d))
                out.append((k2, CGRect(x: m + half + gap, y: y, width: half, height: h), d2))
                y += h + gap
                i += 2
                continue
            }
            let h = trayCardHeight(k, d)
            out.append((k, CGRect(x: m, y: y, width: full, height: h), d))
            y += h + gap
            i += 1
        }
        return (out, y - gap + top)
    }

    func drawTray() {
        for item in trayLayout().items {
            addCardHit(item.rect, kind: item.kind)
            if mode == .float {
                drawFloatCard(item.kind, item.rect)
            } else if item.kind == "cpu" {
                if item.detail == .standard {
                    drawTrayCPU(item.rect)
                } else {
                    drawCPU(item.rect, capacity: 60, detail: item.detail)
                }
            } else {
                drawWidget(item.kind, item.rect, detail: item.detail)
            }
            drawCardHover(item.rect)
        }
    }

    /// 常に手前のパネル用の小さなカード。名前と今の値の下に、直近の動きをグラフで出す。
    /// グラフは plotGraph で描くので、なめらか表示の設定がそのまま効く
    func drawFloatCard(_ kind: String, _ r: CGRect) {
        if kind == "top" {
            drawTopApps(r, detail: .compact)
            return
        }
        let s = store.sampler
        let capacity = 45
        var value = "—"
        var color = t.cpu
        var values: [Double] = []
        var style = t.graph
        // 通信だけ、上りを細い線で重ねる
        var overlayValues: [Double]? = nil
        switch kind {
        case "cpu":
            value = pct(s.cpu)
            values = s.cpuS.last(capacity)
        case "memory":
            value = pct(s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0)
            color = t.memory
            values = s.memS.last(capacity)
        case "gpu":
            value = s.gpu.map(pct) ?? "—"
            color = t.gpu
            values = s.gpuS.last(capacity)
        case "network":
            let scale = max(s.downS.values.max() ?? 0, s.upS.values.max() ?? 0, 256 * 1024)
            value = "↓ \(formatRate(s.netDown))  ↑ \(formatRate(s.netUp))"
            color = t.network
            values = s.downS.last(capacity).map { $0 / scale }
            overlayValues = s.upS.last(capacity).map { $0 / scale }
            if style == .bars { style = .area }
        case "disk":
            let scale = max(s.diskS.values.max() ?? 0, 1_048_576)
            value = "\(formatBytes(UInt64(max(s.diskFree, 0)))) free"
            color = t.disk
            values = s.diskS.last(capacity).map { $0 / scale }
        default:
            // 電源：電池の残量と温度。グラフは温度の動き
            let temp = (s.socTemp ?? s.battery?.temperature).map { "\(Int($0.rounded()))°C" } ?? "—"
            let scale = max(s.tempS.values.max() ?? 0, 60)
            value = s.battery.map { "\(pct($0.percent)) · \(temp)" } ?? temp
            color = t.battery
            values = s.tempS.last(capacity).map { $0 / scale }
        }
        card(r)
        let labelW = text(WidgetConfig.title(kind), r.minX + 10, r.minY + 8, t.font(10.5, .regular), t.textDim)
        text(value, r.maxX - 10, r.minY + 6, t.font(12.5, DashboardView.valueWeight), color, align: .right,
             maxW: max(r.width - 20 - labelW - 6, 20), glow: true)
        let g = CGRect(x: r.minX + 10, y: r.minY + 28, width: r.width - 20, height: r.height - 28 - 8)
        plotGraph(rect: g, values: values, color: color, style: style, capacity: capacity, glow: t.glow)
        if let overlayValues, t.graph != .pixel {
            plotGraph(rect: g, values: overlayValues, color: t.disk, style: .line, capacity: capacity, glow: t.glow, lineWidth: 1, fillable: false)
        }
    }

    /// メニューバー用のCPU。全体のグラフの下に、コアごとの小さなグラフを並べる
    func drawTrayCPU(_ r: CGRect) {
        let s = store.sampler
        card(r)
        metricHeader(r, "CPU", value: pct(s.cpu), color: t.cpu, sub: "User \(pct(s.cpuUser)) · System \(pct(s.cpuSystem))")
        let cores = s.coreS
        if cores.count > 24 {
            let bh: CGFloat = 24
            plotGraph(rect: CGRect(x: r.minX + 12, y: r.minY + 42, width: r.width - 24, height: r.maxY - 10 - bh - 6 - (r.minY + 42)),
                      values: s.cpuS.values, color: t.cpu, style: t.graph, capacity: 60, glow: t.glow)
            drawCoreBars(CGRect(x: r.minX + 12, y: r.maxY - 10 - bh, width: r.width - 24, height: bh))
            return
        }
        let rows = DashboardView.trayCoreRows(cores.count)
        let cols = rows == 0 ? 1 : Int(ceil(Double(cores.count) / Double(rows)))
        let cellH: CGFloat = 32, gap: CGFloat = 5
        let gridH = rows == 0 ? 0 : CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        let gridTop = r.maxY - 10 - gridH
        plotGraph(rect: CGRect(x: r.minX + 12, y: r.minY + 42, width: r.width - 24, height: gridTop - 6 - (r.minY + 42)),
                  values: s.cpuS.values, color: t.cpu, style: t.graph, capacity: 60, glow: t.glow)
        let cw = (r.width - 24 - gap * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, series) in cores.enumerated() {
            let cell = CGRect(x: r.minX + 12 + CGFloat(i % cols) * (cw + gap),
                              y: gridTop + CGFloat(i / cols) * (cellH + gap), width: cw, height: cellH)
            drawCoreCell(cell, index: i, series: series, large: false, tiny: true)
        }
    }

    /// アプリのアイコンは巨大な画像を含むので、小さなビットマップに縮めてから持つ
    static func smallIcon(_ path: String) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        let px = 40
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        source.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: px / 2, height: px / 2))
        out.addRepresentation(rep)
        return out
    }

    func drawIcon(_ row: ProcRow, x: CGFloat, y: CGFloat, size: CGFloat) {
        let rect = CGRect(x: x, y: y, width: size, height: size)
        if let path = row.appPath {
            let img = iconCache[path] ?? DashboardView.smallIcon(path)
            iconCache[path] = img
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            ctx.addPath(rounded(rect.insetBy(dx: 1.5, dy: 1.5), 3))
            ctx.setFillColor(t.textDim.cg(0.3))
            ctx.fillPath()
        }
    }

    // MARK: - Apps

    func drawApps(_ c: CGRect) {
        var x = c.minX
        let y = c.minY
        for (label, value) in [("CPU", ProcSort.cpu), ("Memory", ProcSort.mem), ("Name", ProcSort.name)] {
            let r = chip(label, x: x, y: y, active: store.sort == value) { [unowned self] in
                self.store.sort = value
                self.scroll[.processes] = 0
            }
            x = r.maxX + 5
        }
        let groupLabel = store.groupApps ? "By app" : "By process"
        let gw = chipWidth(groupLabel)
        chip(groupLabel, x: c.maxX - gw, y: y, w: gw) { [unowned self] in
            self.store.groupApps.toggle()
            self.scroll[.processes] = 0
        }

        let listR = CGRect(x: c.minX, y: y + 36, width: c.width, height: c.height - 36)
        card(listR)
        let hf = t.font(10.5, .regular)
        text("Name", listR.minX + 14, listR.minY + 9, hf, t.textDim)
        text("CPU", listR.maxX - 130, listR.minY + 9, hf, t.textDim, align: .right)
        text("Memory", listR.maxX - 44, listR.minY + 9, hf, t.textDim, align: .right)
        let bodyR = CGRect(x: listR.minX, y: listR.minY + 30, width: listR.width, height: listR.height - 31)
        ctx.setFillColor(t.border.cg(0.6))
        ctx.fill(CGRect(x: listR.minX, y: bodyR.minY - 1, width: listR.width, height: 1))

        let rows = store.sampler.processes.list(grouped: store.groupApps, sort: store.sort)
        killStates = killStates.filter { kv in rows.contains { $0.key == kv.key } }
        let rowH: CGFloat = 34
        let maxS = max(0, CGFloat(rows.count) * rowH - bodyR.height)
        maxScroll[.processes] = maxS
        let off = min(scroll[.processes] ?? 0, maxS)
        scroll[.processes] = off

        ctx.saveGState()
        ctx.clip(to: bodyR)
        clip = bodyR
        let first = max(0, Int(off / rowH))
        let visible = Int(bodyR.height / rowH) + 2
        if first < rows.count {
            for i in first..<min(rows.count, first + visible) {
                drawRow(rows[i], rect: CGRect(x: bodyR.minX, y: bodyR.minY + CGFloat(i) * rowH - off, width: bodyR.width, height: rowH))
            }
        }
        clip = nil
        ctx.restoreGState()
        if maxS > 0 {
            let barH = max(24, bodyR.height * bodyR.height / (bodyR.height + maxS))
            let barY = bodyR.minY + (bodyR.height - barH) * off / maxS
            ctx.addPath(rounded(CGRect(x: bodyR.maxX - 5, y: barY + 2, width: 3, height: barH - 4), 1.5))
            ctx.setFillColor(t.textDim.cg(0.4))
            ctx.fillPath()
        }
    }

    /// 一覧の行から、終了させる相手（pid と開始時刻）を作る
    func quitTargets(_ r: ProcRow) -> [QuitTarget] {
        r.pids.compactMap { pid in processControl.startTime(pid).map { QuitTarget(pid: pid, start: $0) } }
    }

    /// 通常の終了を頼む。アプリならアプリとして、そうでなければ SIGTERM。結果を行に出す
    func quit(_ r: ProcRow) {
        let targets = quitTargets(r)
        let result = requestQuit(targets, control: processControl)
        if result.accepted.isEmpty {
            killStates[r.key] = .failed(result.failure ?? "Couldn't quit.", Date())
        } else {
            // 一部だけ頼めなかった時は、待っている間もその理由を出す。強制終了は頼めた相手だけが対象
            killStates[r.key] = .sent(Date(), result.accepted, result.failure)
        }
    }

    /// 強制終了。頼んだ時と同じプロセスが残っている時だけ止める
    func forceQuitRow(_ r: ProcRow, targets: [QuitTarget]) {
        let result = forceQuit(targets, control: processControl)
        if let msg = result.failure {
            killStates[r.key] = .failed(msg, Date())
        } else {
            killStates[r.key] = nil
        }
    }

    func drawRow(_ r: ProcRow, rect: CGRect) {
        let hovering = isHover(rect)
        if hovering {
            ctx.setFillColor(t.accent.cg(0.1))
            ctx.fill(rect)
        }
        let cy = rect.minY + 9
        drawIcon(r, x: rect.minX + 12, y: rect.minY + 8, size: 18)
        var name = r.name
        if r.pids.count > 1 { name += " (\(r.pids.count))" }
        let isSelf = r.pids.contains(getpid())

        if let state = killStates[r.key] {
            text(name, rect.minX + 38, cy, t.font(12), t.text, maxW: rect.width - 38 - 170)
            switch state {
            case .confirm:
                let no = chip("Cancel", x: rect.maxX - 66, y: rect.minY + 5, w: 56, h: 24) { [unowned self] in self.killStates[r.key] = nil }
                chip("Quit", x: no.minX - 60, y: rect.minY + 5, w: 56, h: 24, active: true, color: t.danger) { [unowned self] in
                    self.quit(r)
                }
            case .sent(let when, let targets, let note):
                if Date().timeIntervalSince(when) < 3 {
                    if let note {
                        text("Waiting to quit… · " + note, rect.maxX - 14, cy, t.font(11), t.danger, align: .right, maxW: rect.width - 38 - 180)
                    } else {
                        text("Waiting to quit…", rect.maxX - 14, cy, t.font(11), t.textDim, align: .right)
                    }
                } else {
                    let no = chip("Cancel", x: rect.maxX - 66, y: rect.minY + 5, w: 56, h: 24) { [unowned self] in self.killStates[r.key] = nil }
                    chip("Force Quit", x: no.minX - 80, y: rect.minY + 5, w: 76, h: 24, active: true, color: t.danger) { [unowned self] in
                        self.forceQuitRow(r, targets: targets)
                    }
                }
            case .failed(let msg, let when):
                if Date().timeIntervalSince(when) > 6 {
                    killStates[r.key] = nil
                } else {
                    let no = chip("OK", x: rect.maxX - 50, y: rect.minY + 5, w: 40, h: 24) { [unowned self] in self.killStates[r.key] = nil }
                    text(msg, no.minX - 8, cy, t.font(11), t.danger, align: .right, maxW: rect.width - 38 - 180)
                }
            }
            return
        }

        text(name, rect.minX + 38, cy, t.font(12), t.text, maxW: rect.width - 38 - 170)
        text(String(format: r.cpu >= 10 ? "%.0f%%" : "%.1f%%", r.cpu), rect.maxX - 130, cy, t.font(11.5, .regular), t.cpu, align: .right)
        text(formatBytes(r.mem), rect.maxX - 44, cy, t.font(11), t.memory, align: .right)
        if !isSelf {
            // 終了の操作は見えている行すべてに登録する（キーボードや読み上げで届くように）。
            // ボタンの絵はマウスを乗せた行か、キーボードで選んだ行にだけ出す
            let btn = CGRect(x: rect.maxX - 32, y: rect.minY + 8, width: 18, height: 18)
            let focused = nextHitFocused
            addHit(btn, label: "Quit \(r.name)") { [unowned self] in self.killStates[r.key] = .confirm }
            guard hovering || focused else { return }
            let on = isHover(btn) || focused
            ctx.addPath(rounded(btn, 9))
            ctx.setFillColor(on ? t.danger.cg() : t.danger.cg(0.16))
            ctx.fillPath()
            ctx.setStrokeColor((on ? onAccent : t.danger).cg())
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: btn.midX - 3.5, y: btn.midY - 3.5))
            ctx.addLine(to: CGPoint(x: btn.midX + 3.5, y: btn.midY + 3.5))
            ctx.move(to: CGPoint(x: btn.midX + 3.5, y: btn.midY - 3.5))
            ctx.addLine(to: CGPoint(x: btn.midX - 3.5, y: btn.midY + 3.5))
            ctx.strokePath()
        }
    }

    // MARK: - Settings

    static let previewWave: [Double] = [0.3, 0.42, 0.34, 0.5, 0.62, 0.48, 0.55, 0.8, 0.66, 0.5, 0.58, 0.72, 0.6, 0.44, 0.52, 0.68]
    static let previewWave2: [Double] = [0.5, 0.5, 0.52, 0.48, 0.5, 0.54, 0.56, 0.52, 0.5, 0.54, 0.5, 0.48, 0.52, 0.5, 0.54, 0.5]

    /// 区切り線と見出し。2つ目以降の項目の前に線を引く
    func settingsSection(_ title: String, note: String? = nil, c: CGRect, y: CGFloat, first: Bool = false) -> CGFloat {
        var y = y
        if !first {
            ctx.setFillColor(t.border.cg(0.7))
            ctx.fill(CGRect(x: c.minX, y: y, width: c.width, height: 1))
            y += 18
        }
        text(title, c.minX, y, t.font(13.5, .medium), t.text)
        y += 22
        if let note {
            text(note, c.minX, y, t.font(11), t.textDim, maxW: c.width)
            y += 20
        }
        return y + 4
    }

    func drawSettings(_ c: CGRect) {
        sliderTrack = nil
        sliderSet = nil
        // 上のタブ
        var x = c.minX
        for page in SettingsPage.allCases {
            let r = chip(page.label, x: x, y: c.minY, h: 28, active: settingsPage == page) { [unowned self] in
                self.settingsPage = page
                self.scroll[.settings] = 0
            }
            x = r.maxX + 6
        }

        let area = CGRect(x: c.minX - 4, y: c.minY + 40, width: c.width + 8, height: bounds.height - c.minY - 40)
        let off = min(scroll[.settings] ?? 0, maxScroll[.settings] ?? 0)
        ctx.saveGState()
        ctx.clip(to: area)
        clip = area
        var y = area.minY + 8 - off

        switch settingsPage {
        case .appearance:
            y = settingsSection("Skin", c: c, y: y, first: true)
            let gap: CGFloat = 10
            let cols = max(2, Int((c.width + gap) / 190))
            let w = (c.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h: CGFloat = 86
            for (i, th) in store.themes.enumerated() {
                drawSkinCard(th, CGRect(x: c.minX + CGFloat(i % cols) * (w + gap), y: y + CGFloat(i / cols) * (h + gap), width: w, height: h))
            }
            y += CGFloat((store.themes.count + cols - 1) / cols) * (h + gap) + 14

            y = settingsSection("Transparency", note: "Applies to the window and both panels.", c: c, y: y)
            // 0〜70%を5%刻み
            let track = slider("Transparency", x: c.minX, y: y, maxValue: 0.7, step: 0.05,
                               read: { [unowned self] in self.store.transparency },
                               write: { [unowned self] v in self.store.transparency = v })
            chip(store.blurBehind ? "Blur: On" : "Blur: Off", x: track.maxX + 62, y: y - 3, active: store.blurBehind) { [unowned self] in
                self.store.blurBehind.toggle()
            }
            y += 46

            y = settingsSection("Graphs", note: "Shade the area under line graphs so levels are easier to read at a glance.", c: c, y: y)
            x = c.minX
            x += text("Fill under line", x, y + 5, t.font(11.5, .medium), t.textDim) + 10
            for (on, label) in [(true, "On"), (false, "Off")] {
                let r = chip(label, x: x, y: y, active: store.graphFill == on) { [unowned self] in self.store.graphFill = on }
                x = r.maxX + 6
            }
            y += 44

            y = settingsSection("Custom skins", note: "Add a JSON skin file to the skins folder, then reload.", c: c, y: y)
            let openR = chip("Open Skins Folder", x: c.minX, y: y) { [unowned self] in
                _ = NSWorkspace.shared.open(self.store.userSkinDir)
            }
            chip("Reload Skins", x: openR.maxX + 6, y: y) { [unowned self] in
                self.store.reloadSkins()
                self.store.select(self.store.theme)
            }
            y += 44

        case .menuBar:
            y = settingsSection("Icon", c: c, y: y, first: true)
            y = drawMenuBarSettings(c, y: y)
            y += 6

            y = settingsSection("Menu bar panel", note: "What opens when you click the menu bar icon.", c: c, y: y)
            x = c.minX
            x += text("Show", x, y + 5, t.font(11.5, .medium), t.textDim) + 10
            let names = ["cpu": "CPU", "memory": "Memory", "gpu": "GPU", "network": "Network", "disk": "Disk", "power": "Power", "top": "Top processes"]
            for id in Store.allTrayItems {
                let label = names[id] ?? id
                if x + chipWidth(label) > c.maxX {
                    x = c.minX + 46
                    y += 34
                }
                let on = store.trayItems.contains(id)
                let r = chip(label, x: x, y: y, active: on) { [unowned self] in
                    var cur = self.store.trayItems
                    if on {
                        if cur.count > 1 { cur.removeAll { $0 == id } }
                    } else {
                        cur.append(id)
                    }
                    self.store.trayItems = Store.allTrayItems.filter { cur.contains($0) }
                }
                x = r.maxX + 6
            }
            y += 38
            x = c.minX
            x += text("Detail", x, y + 5, t.font(11.5, .medium), t.textDim) + 10
            x = max(x, c.minX + 46)
            for (level, label) in [(0, "Compact"), (1, "Standard"), (2, "Detailed")] {
                let r = chip(label, x: x, y: y, active: store.trayDetail == level) { [unowned self] in self.store.trayDetail = level }
                x = r.maxX + 6
            }
            y += 38
            x = c.minX
            x += text("Outer frame", x, y + 5, t.font(11.5, .medium), t.textDim) + 10
            for (on, label) in [(true, "On"), (false, "Off (sits right under the menu bar)")] {
                let r = chip(label, x: x, y: y, active: store.trayFrame == on) { [unowned self] in self.store.trayFrame = on }
                x = r.maxX + 6
            }
            y += 44

        case .panel:
            y = settingsSection("Floating panel", note: "A small panel of live graphs that always stays on top of other windows. Click a card to open its details.", c: c, y: y, first: true)
            x = c.minX
            for (on, label) in [(true, "On"), (false, "Off")] {
                let r = chip(label, x: x, y: y, active: store.floatEnabled == on) { [unowned self] in self.store.floatEnabled = on }
                x = r.maxX + 6
            }
            y += 44

            y = settingsSection("Position", note: "Which corner of the main display the panel sits in.", c: c, y: y)
            x = c.minX
            for (id, label) in [("topLeft", "Top left"), ("topRight", "Top right"), ("bottomLeft", "Bottom left"), ("bottomRight", "Bottom right")] {
                let r = chip(label, x: x, y: y, active: store.floatCorner == id) { [unowned self] in self.store.floatCorner = id }
                x = r.maxX + 6
            }
            y += 44

            y = settingsSection("Outer frame", note: "Off shows only the cards, without the surrounding background.", c: c, y: y)
            x = c.minX
            for (on, label) in [(true, "On"), (false, "Off")] {
                let r = chip(label, x: x, y: y, active: store.floatFrame == on) { [unowned self] in self.store.floatFrame = on }
                x = r.maxX + 6
            }
            y += 44

            y = settingsSection("Transparency", note: "How see-through the floating panel is.", c: c, y: y)
            // 0〜80%を5%刻み
            slider("Panel transparency", x: c.minX, y: y, maxValue: 0.8, step: 0.05,
                   read: { [unowned self] in self.store.floatTransparency },
                   write: { [unowned self] v in self.store.floatTransparency = v })
            y += 46

            y = settingsSection("Show", note: "Tick what the floating panel shows.", c: c, y: y)
            let perRow = 4
            for (i, id) in Store.allTrayItems.enumerated() {
                let on = store.floatItems.contains(id)
                checkbox(WidgetConfig.title(id), x: c.minX + CGFloat(i % perRow) * 150, y: y + CGFloat(i / perRow) * 30, on: on) { [unowned self] in
                    var cur = self.store.floatItems
                    if on {
                        if cur.count > 1 { cur.removeAll { $0 == id } }
                    } else {
                        cur.append(id)
                    }
                    self.store.floatItems = Store.allTrayItems.filter { cur.contains($0) }
                }
            }
            y += CGFloat((Store.allTrayItems.count + perRow - 1) / perRow) * 30 + 14

        case .window:
            y = settingsSection("Overview layout", note: "Move, resize and hide cards, and choose how much detail each shows.", c: c, y: y, first: true)
            chip("Customize Layout", x: c.minX, y: y) { [unowned self] in
                self.tab = .overview
                self.editingLayout = true
            }
            y += 44
            y = settingsSection("Sidebar", c: c, y: y)
            x = c.minX
            for (collapsed, label) in [(false, "Expanded"), (true, "Icons only")] {
                let r = chip(label, x: x, y: y, active: store.sidebarCollapsed == collapsed) { [unowned self] in
                    self.store.sidebarCollapsed = collapsed
                }
                x = r.maxX + 6
            }
            y += 44

        case .general:
            y = settingsSection("Update interval", note: "Longer intervals save power.", c: c, y: y, first: true)
            x = c.minX
            for (sec, label) in [(1.0, "1 sec"), (2.0, "2 sec"), (5.0, "5 sec")] {
                let r = chip(label, x: x, y: y, active: store.interval == sec) { [unowned self] in self.store.interval = sec }
                x = r.maxX + 6
            }
            y += 38
            chip(store.smoothMotion ? "Smooth motion: On" : "Smooth motion: Off", x: c.minX, y: y, active: store.smoothMotion) { [unowned self] in
                self.store.smoothMotion.toggle()
            }
            y += 44
            y = settingsSection("Quit", note: "Mimo keeps running in the menu bar when the window is closed.", c: c, y: y)
            chip("Quit Mimo", x: c.minX, y: y, color: t.danger) { [unowned self] in self.store.onQuit?() }
            y += 44
        }

        clip = nil
        ctx.restoreGState()
        maxScroll[.settings] = max(0, y + off - area.maxY + 8)
    }

    func drawSkinCard(_ th: Theme, _ r: CGRect) {
        let active = th.def.id == t.def.id
        let path = rounded(r, max(min(th.corner, 14), 2))
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if th.isGlass {
            ctx.setFillColor(NSColor.labelColor.cg(0.07))
            ctx.fill(r)
        } else {
            let sp = CGColorSpace(name: CGColorSpace.sRGB)
            if let g = CGGradient(colorsSpace: sp, colors: [th.bgTop.cg(), th.bgBottom.cg()] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            }
        }
        let g = CGRect(x: r.minX + 10, y: r.minY + 32, width: r.width - 20, height: 44)
        drawGraph(ctx, rect: g, values: DashboardView.previewWave2, color: th.memory, style: th.graph, capacity: 16, glow: th.glow)
        drawGraph(ctx, rect: g, values: DashboardView.previewWave, color: th.cpu, style: th.graph == .pixel ? .pixel : (th.graph == .bars ? .bars : .line), capacity: 16, glow: th.glow)
        if th.scanlines {
            ctx.setFillColor(NSColor.black.cg(0.14))
            var y = r.minY
            while y < r.maxY { ctx.fill(CGRect(x: r.minX, y: y, width: r.width, height: 1)); y += 3 }
        }
        ctx.restoreGState()
        text(th.def.name, r.minX + 10, r.minY + 8, th.font(12.5, .regular), th.isGlass ? t.text : th.text, maxW: r.width - 20)
        ctx.addPath(path)
        ctx.setStrokeColor(active ? t.accent.cg() : th.border.cg(isHover(r) ? 1 : 0.7))
        ctx.setLineWidth(active ? 2.5 : 1)
        ctx.strokePath()
        addHit(r, label: "Skin \(th.def.name)") { [unowned self] in self.store.select(th) }
    }
}
