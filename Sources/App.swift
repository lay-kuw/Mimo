import AppKit

final class PopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 常に手前に出すパネル。押しても他のアプリからフォーカスを奪わない
final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store(persist: true)
    private let startInBackground: Bool
    private var statusItem: NSStatusItem!

    // メニューバーのパネル（Overviewのみ）
    private var panel: PopPanel!
    private var panelEffect: NSVisualEffectView!
    private var panelView: DashboardView!
    private var panelOpen = false
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var panelClosedAt: CFTimeInterval = 0

    // 常に手前に出すパネル（設定でオンの間だけ作る）
    private var floatPanel: FloatPanel?
    private var floatEffect: NSVisualEffectView?
    private var floatView: DashboardView?
    private var floatVisible: Bool { floatPanel?.isVisible ?? false }

    // 通常のアプリウィンドウ
    private var window: NSWindow?
    private var windowEffect: NSVisualEffectView?
    private var windowView: DashboardView?
    private var lastTab: DashTab = .overview

    private var timer: Timer?
    private lazy var menuIcon = MenuBarAnimator(store: store) { [weak self] in self?.statusItem.button }
    private var asleep = false

    init(startInBackground: Bool) {
        self.startInBackground = startInBackground
        super.init()
    }

    private var windowVisible: Bool {
        guard let w = window, w.isVisible else { return false }
        return w.occlusionState.contains(.visible)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildPanel()
        store.onThemeChange = { [weak self] in self?.applyTheme() }
        store.onSettingsChange = { [weak self] in
            self?.restartTimer()
            self?.menuIcon.invalidate()
            self?.refreshStatus()
            self?.floatView?.needsDisplay = true
        }
        store.onTransparencyChange = { [weak self] in self?.applyTransparency() }
        store.onFloatChange = { [weak self] in
            self?.applyFloat()
            self?.windowView?.needsDisplay = true
        }
        store.onQuit = { NSApp.terminate(nil) }
        applyTheme()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        tick()
        restartTimer()
        store.sampler.watchPowerSource { [weak self] in
            guard let self else { return }
            self.refreshStatus()
            if self.panelOpen { self.panelView.needsDisplay = true }
            if self.windowVisible { self.windowView?.needsDisplay = true }
            self.floatView?.needsDisplay = true
        }
        if !startInBackground { openWindow(tab: .overview) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Finder や Dock から開き直された時はウィンドウを出す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(tab: nil)
        return true
    }

    // MARK: - メニュー

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mimo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mimo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // メニューには出さず、⌘W・⌘M・⌘H・⌘, のショートカットだけ残す
        let hidden: [(String, Selector, String, AnyObject?)] = [
            ("Close", #selector(NSWindow.performClose(_:)), "w", nil),
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", nil),
            ("Hide Mimo", #selector(NSApplication.hide(_:)), "h", nil),
            ("Settings…", #selector(showSettings), ",", self),
        ]
        for (title, action, key, target) in hidden {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            appMenu.addItem(item)
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        NSApp.mainMenu = main
    }

    @objc private func showSettings() { openWindow(tab: .settings) }

    // MARK: - パネルとウィンドウ

    private func buildPanel() {
        let size = NSSize(width: DashboardView.trayWidth, height: DashboardView.trayHeight)
        panel = PopPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        panelEffect = NSVisualEffectView(frame: root.bounds)
        panelEffect.autoresizingMask = [.width, .height]
        panelEffect.material = .popover
        panelEffect.blendingMode = .behindWindow
        panelEffect.state = .active
        root.addSubview(panelEffect)
        panelView = DashboardView(store: store, mode: .tray, frame: root.bounds)
        panelView.autoresizingMask = [.width, .height]
        // パネルのカードを押したら、メインウィンドウで対応する画面を出してパネルを閉じる
        panelView.onNavigate = { [weak self] d in
            guard let self else { return }
            self.closePanel()
            self.openWindow(tab: nil, destination: d)
        }
        panelView.onDismiss = { [weak self] in self?.closePanel() }
        root.addSubview(panelView)
        panel.contentView = root
    }

    private func buildFloat() {
        let size = NSSize(width: DashboardView.floatWidth, height: 200)
        let p = FloatPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.masksToBounds = true
        let fx = NSVisualEffectView(frame: root.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        root.addSubview(fx)
        let v = DashboardView(store: store, mode: .float, frame: root.bounds)
        v.autoresizingMask = [.width, .height]
        // カードを押したら、メインウィンドウで対応する画面を出す（パネルは出したまま）
        v.onNavigate = { [weak self] d in self?.openWindow(tab: nil, destination: d) }
        root.addSubview(v)
        p.contentView = root
        floatPanel = p
        floatEffect = fx
        floatView = v
    }

    /// 設定に合わせて、常に手前のパネルを出す・消す・見た目を揃える
    private func applyFloat() {
        guard store.floatEnabled else {
            if let p = floatPanel {
                p.orderOut(nil)
                floatPanel = nil
                floatEffect = nil
                floatView = nil
                restartTimer()
            }
            return
        }
        let created = floatPanel == nil
        if created { buildFloat() }
        guard let p = floatPanel, let v = floatView else { return }
        let t = store.theme
        p.appearance = t.appearance
        let framed = store.floatFrame
        p.hasShadow = framed
        p.contentView?.layer?.cornerRadius = framed ? t.corner : 0
        floatEffect?.isHidden = !framed || !(t.isGlass || (store.transparency > 0 && store.blurBehind))
        p.alphaValue = CGFloat(1 - min(max(store.floatTransparency, 0), 0.8))
        placeFloat()
        v.needsDisplay = true
        p.invalidateShadow()
        if !p.isVisible { p.orderFrontRegardless() }
        if created {
            store.sampler.processes.sample()
            restartTimer()
        }
    }

    /// 選んだ隅に、中身の高さに合わせて置く
    private func placeFloat() {
        guard let p = floatPanel, let v = floatView, let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let margin: CGFloat = 12
        let w = DashboardView.floatWidth
        let h = min(v.trayLayout().height, vf.height - margin * 2)
        let corner = store.floatCorner
        let x = corner.hasSuffix("Left") ? vf.minX + margin : vf.maxX - w - margin
        let y = corner.hasPrefix("top") ? vf.maxY - h - margin : vf.minY + margin
        let frame = NSRect(x: x, y: y, width: w, height: h)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }

    @objc private func screensChanged() { placeFloat() }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1040, height: 680)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Mimo"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 860, height: 580)
        w.delegate = self
        let root = NSView(frame: rect)
        let fx = NSVisualEffectView(frame: root.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .underWindowBackground
        fx.blendingMode = .behindWindow
        fx.state = .active
        root.addSubview(fx)
        let v = DashboardView(store: store, mode: .window, frame: root.bounds)
        v.autoresizingMask = [.width, .height]
        root.addSubview(v)
        w.contentView = root
        w.center()
        w.setFrameAutosaveName("MimoMainWindow")
        window = w
        windowEffect = fx
        windowView = v
    }

    /// メインウィンドウを出す。すでにあれば作り直さずに前面へ出す。destination があればその画面を先頭から表示する
    private func openWindow(tab: DashTab?, destination: Destination? = nil) {
        if window == nil {
            buildWindow()
            applyTheme()
        }
        if let destination {
            windowView?.show(destination)
        } else {
            windowView?.tab = tab ?? lastTab
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(windowView)
        store.sampler.processes.sample()
        windowView?.needsDisplay = true
        restartTimer()
    }

    /// 見えている画面がプロセス一覧を使う時だけ、全プロセスを読む
    private var processesNeeded: Bool {
        if panelOpen {
            let items = store.trayItems
            if items.contains("top") || (store.trayDetail == 2 && items.contains("cpu")) { return true }
        }
        if floatVisible, store.floatItems.contains("top") { return true }
        if windowVisible, let v = windowView {
            switch v.tab {
            case .processes: return true
            case .performance: return v.perfPage == .cpu || v.perfPage == .memory
            case .overview: return store.layout.contains { $0.visible && ($0.kind == "top" || ($0.kind == "cpu" && $0.detail == 2)) }
            case .settings: return false
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        lastTab = windowView?.tab ?? lastTab
        store.sampler.wantsDetail = false
        // ウィンドウを閉じたらメモリを手放し、Dockから消えてメニューバー常駐だけに戻る
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.delegate = nil
            self.window = nil
            self.windowEffect = nil
            self.windowView = nil
            NSApp.setActivationPolicy(.accessory)
            self.restartTimer()
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        store.sampler.wantsDetail = windowVisible && windowView?.tab == .performance
        restartTimer()
        if windowVisible { windowView?.needsDisplay = true }
    }

    private func applyTheme() {
        let t = store.theme
        panel.appearance = t.appearance
        panel.contentView?.layer?.cornerRadius = t.corner
        panelView.needsDisplay = true
        panel.invalidateShadow()
        menuIcon.invalidate()
        if let w = window {
            w.appearance = t.appearance
            windowView?.needsDisplay = true
        }
        applyTransparency()
        refreshStatus()
    }

    /// 背景の透け具合を、ウィンドウと2種類のパネルに同じように反映する
    private func applyTransparency() {
        let t = store.theme
        let seeThrough = t.isGlass || store.transparency > 0
        let blur = t.isGlass || (store.transparency > 0 && store.blurBehind)
        panelEffect.isHidden = !blur || !store.trayFrame
        panel.hasShadow = store.trayFrame
        panel.contentView?.layer?.cornerRadius = store.trayFrame ? t.corner : 0
        panelView.needsDisplay = true
        panel.invalidateShadow()
        if let w = window {
            w.isOpaque = !seeThrough
            w.backgroundColor = seeThrough ? .clear : t.bgTop
            windowEffect?.isHidden = !blur
            windowView?.needsDisplay = true
            w.invalidateShadow()
        }
        applyFloat()
    }

    private func refreshStatus() {
        menuIcon.refresh()
    }

    private func tick() {
        if asleep { return }
        // 電源情報を速く読むのは、Performance 画面が実際に見えている間だけ
        store.sampler.wantsDetail = windowVisible && windowView?.tab == .performance
        let watchingApps = windowVisible && (windowView?.tab == .processes || windowView?.tab == .performance)
        store.sampler.tick(processInterval: processesNeeded ? (watchingApps || panelOpen ? 2 : 5) : nil)
        refreshStatus()
        if panelOpen { panelView.needsDisplay = true }
        if windowVisible { windowView?.needsDisplay = true }
        floatView?.needsDisplay = true
    }

    private func restartTimer() {
        timer?.invalidate()
        let iv = store.interval
        let t = Timer(timeInterval: iv, repeats: true) { [weak self] _ in self?.tick() }
        // なめらか表示中は計測の間隔を揃える。それ以外はまとめて起きられるようにして省電力に
        let watching = store.smoothMotion && (panelOpen || windowVisible || floatVisible)
        t.tolerance = iv * (watching ? 0.02 : 0.25)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func screensSlept() {
        asleep = true
        timer?.invalidate()
        menuIcon.pause()
    }
    @objc private func screensWoke() {
        asleep = false
        tick()
        restartTimer()
        menuIcon.resume()
    }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Open Mimo", action: #selector(openFromMenu), keyEquivalent: "").target = self
            let floatItem = m.addItem(withTitle: "Floating Panel", action: #selector(toggleFloat), keyEquivalent: "")
            floatItem.target = self
            floatItem.state = store.floatEnabled ? .on : .off
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Mimo", action: #selector(quitApp), keyEquivalent: "").target = self
            statusItem.menu = m
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        // アイコンを押した瞬間に外側クリックとして閉じた直後なら、開き直さない
        if panelOpen {
            closePanel()
        } else if CACurrentMediaTime() - panelClosedAt > 0.35 {
            openPanel()
        }
    }

    @objc private func openFromMenu() { openWindow(tab: nil) }
    @objc private func toggleFloat() { store.floatEnabled.toggle() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func openPanel() {
        guard let button = statusItem.button, let bw = button.window else { return }
        let screenH = ((bw.screen ?? NSScreen.main)?.visibleFrame.height ?? 900)
        DashboardView.trayMaxHeight = screenH - 16
        let w = DashboardView.trayWidth, h = min(panelView.trayLayout().height, screenH - 8)
        // 枠なしのときはメニューバーのすぐ下に出す
        let gap: CGFloat = store.trayFrame ? 6 : 0
        let br = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let vf = (bw.screen ?? NSScreen.main)?.visibleFrame ?? br
        var x = br.midX - w / 2
        x = min(max(x, vf.minX + 8), vf.maxX - w - 8)
        panel.setFrame(NSRect(x: x, y: br.minY - h - gap, width: w, height: h), display: false)
        panelOpen = true
        store.sampler.processes.sample()
        panelView.needsDisplay = true
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panelView)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            panel.animator().alphaValue = 1
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panelOpen else { return }
            self.closePanel()
        }
        // 自分のウィンドウ（メインウィンドウや常に手前のパネル）を押した時も閉じる。
        // メニューバーのアイコン自身は statusClicked が開け閉めするので除く
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.panelOpen, let w = event.window, w !== self.panel, w !== self.statusItem.button?.window {
                // 押した操作そのものは先に通してから閉じる
                DispatchQueue.main.async { [weak self] in
                    if self?.panelOpen == true { self?.closePanel() }
                }
            }
            return event
        }
        restartTimer()
    }

    private func closePanel() {
        panelClosedAt = CACurrentMediaTime()
        panelOpen = false
        panel.orderOut(nil)
        panelView.releaseCaches()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
        restartTimer()
    }
}
