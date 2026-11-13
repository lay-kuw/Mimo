import AppKit

/// 実データで各スキンをPNGに書き出す確認用モード（メニューバーには出ない）
func runSnapshot(outDir: String) {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let store = Store(persist: false)
    store.layout = WidgetConfig.defaults
    store.sidebarCollapsed = false
    store.transparency = 0
    store.trayItems = Store.allTrayItems
    store.trayFrame = true
    store.floatItems = Store.allTrayItems
    store.metrics = ["cpu", "mem"]
    for _ in 0..<45 {
        store.sampler.tick(processInterval: 0.2)
        usleep(120_000)
    }
    func write(_ rep: NSBitmapImageRep, _ name: String) {
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
        }
    }
    let tray = DashboardView(store: store, mode: .tray, frame: NSRect(x: 0, y: 0, width: DashboardView.trayWidth, height: DashboardView.trayHeight))
    let win = DashboardView(store: store, mode: .window, frame: NSRect(x: 0, y: 0, width: 1040, height: 680))
    let float = DashboardView(store: store, mode: .float, frame: NSRect(x: 0, y: 0, width: DashboardView.floatWidth, height: 200))
    func render(_ v: DashboardView, _ name: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        write(rep, name)
    }
    for theme in store.themes {
        store.select(theme)
        tray.appearance = theme.appearance
        win.appearance = theme.appearance
        tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
        render(tray, "tray-\(theme.def.id).png")
        if ["mochi", "mochineon", "arcadeneon", "tokyonight"].contains(theme.def.id) {
            float.appearance = theme.appearance
            float.setFrameSize(NSSize(width: DashboardView.floatWidth, height: float.trayLayout().height))
            render(float, "float-\(theme.def.id).png")
        }
        if ["mochi", "tokyonight"].contains(theme.def.id) {
            store.trayFrame = false
            tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
            render(tray, "tray-noframe-\(theme.def.id).png")
            store.trayFrame = true
            store.trayItems = Store.allTrayItems
            for level in [0, 2] {
                store.trayDetail = level
                tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
                render(tray, "tray-detail\(level)-\(theme.def.id).png")
            }
            store.trayDetail = 1
            store.trayItems = ["cpu", "memory", "power"]
            tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
            render(tray, "tray-few-\(theme.def.id).png")
            store.trayItems = Store.allTrayItems
        }
        for tab in DashTab.allCases {
            if tab != .overview && theme.def.id != "mochi" && theme.def.id != "arcade" { continue }
            win.tab = tab
            render(win, "window-\(theme.def.id)-\(tab.rawValue).png")
            if tab == .settings && theme.def.id == "mochi" {
                for page in SettingsPage.allCases {
                    win.settingsPage = page
                    render(win, "settings-\(page.rawValue).png")
                }
                win.settingsPage = .appearance
            }
        }
        if ["mochi", "neon", "arcade"].contains(theme.def.id) {
            win.tab = .performance
            for page in PerfPage.allCases {
                win.perfPage = page
                render(win, "perf-\(theme.def.id)-\(page.rawValue).png")
            }
        }
        if theme.def.id == "mochi" {
            win.tab = .overview
            for level in [0, 2] {
                store.layout = WidgetConfig.defaults.map { var c = $0; c.detail = level; return c }
                render(win, "overview-detail\(level).png")
            }
            store.layout = WidgetConfig.defaults
            win.editingLayout = true
            render(win, "overview-edit.png")
            win.editingLayout = false
            store.sidebarCollapsed = true
            render(win, "sidebar-collapsed.png")
            store.sidebarCollapsed = false
        }
        store.metrics = ["cpu", "mem", "gpu", "net"]
        if let rep = renderStatusGraphs(store: store).representations.first as? NSBitmapImageRep {
            write(rep, "menubar-graphs-\(theme.def.id).png")
        }
        store.metrics = ["cpu", "mem"]
    }
// ファンのある Mac での見た目（見本の値）
    Sampler.demoFans = true
    for _ in 0..<20 { store.sampler.tick(processInterval: 5); usleep(30_000) }
    if let th = store.themes.first(where: { $0.def.id == "tokyonight" }) {
        store.select(th)
        tray.appearance = th.appearance
        win.appearance = th.appearance
    }
    store.trayDetail = 2
    tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
    render(tray, "fans-tray-detailed.png")
    store.trayDetail = 1
    tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
    render(tray, "fans-tray.png")
    win.tab = .performance
    win.perfPage = .power
    render(win, "fans-perf-power.png")
    Sampler.demoFans = false
    // 時間軸の確認：温度は10秒ごと、電力は30秒ごとで直近20分、途中に7分のスリープ（値は見本）
    let realTemp = store.sampler.tempS, realPower = store.sampler.powerS
    var demoTemp = Series(cap: 240), demoPower = Series(cap: 400)
    let nowT = CFAbsoluteTimeGetCurrent()
    for k in 0..<120 {
        let at = nowT - 1_200 + Double(k) * 10
        if at > nowT - 780 && at < nowT - 360 { continue }
        demoTemp.push(48 + 6 * sin(Double(k) / 9), at: at)
        if k % 3 == 0 { demoPower.push(6 + 3 * sin(Double(k) / 7), at: at) }
    }
    store.sampler.tempS = demoTemp
    store.sampler.powerS = demoPower
    render(win, "timeaxis-perf-power.png")
    store.sampler.tempS = realTemp
    store.sampler.powerS = realPower
    // コアの多い Mac での見た目（値は見本）
    let realLoads = store.sampler.coreLoads, realS = store.sampler.coreS, realHW = store.sampler.hardware
    for (e, p) in [(4, 12), (8, 16), (8, 32)] {
        let n = e + p
        store.sampler.coreLoads = (0..<n).map { i in 0.15 + 0.8 * abs(sin(Double(i) * 1.7)) }
        store.sampler.coreS = (0..<n).map { i in
            var ser = Series(cap: 60)
            for k in 0..<60 { ser.push(min(1, max(0, 0.4 + 0.35 * sin(Double(k) * 0.3 + Double(i))))) }
            return ser
        }
        store.sampler.hardware.coreLabels = (0..<e).map { "E\($0 + 1)" } + (0..<p).map { "P\($0 + 1)" }
        store.trayDetail = 1
        tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
        render(tray, "cores\(n)-tray.png")
        store.trayDetail = 2
        tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
        render(tray, "cores\(n)-tray-detailed.png")
        store.trayDetail = 1
        win.tab = .overview
        render(win, "cores\(n)-overview.png")
        store.layout = WidgetConfig.defaults.map { var c = $0; c.detail = 2; return c }
        render(win, "cores\(n)-overview-detailed.png")
        store.layout = WidgetConfig.defaults
        win.tab = .performance
        win.perfPage = .cpu
        render(win, "cores\(n)-perf.png")
    }
    store.sampler.coreLoads = realLoads
    store.sampler.coreS = realS
    store.sampler.hardware = realHW
    // アイコンの全コマを拡大して並べる
    let cell = CGSize(width: 150, height: 100)
    let styles = MenuIconStyle.all.filter { $0.id != "graphs" }
    let sheet = renderIconBitmap(size: CGSize(width: cell.width * 8, height: cell.height * CGFloat(styles.count))) { cg in
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: cell.width * 8, height: cell.height * CGFloat(styles.count)))
        for (row, st) in styles.enumerated() {
            for f in 0..<8 {
                let r = CGRect(x: CGFloat(f) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height)
                MenuIconArt.draw(st.id, cg: cg, rect: r.insetBy(dx: 6, dy: 6), phase: Double(f) / 8,
                                 load: Double(f) / 7, color: NSColor.black.cgColor)
            }
        }
    }
    if let rep = sheet.representations.first as? NSBitmapImageRep { write(rep, "menu-icons-frames.png") }
    // 実寸でも確認する
    let actual = renderIconBitmap(size: CGSize(width: 32 * 7, height: 44)) { cg in
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 32 * 7, height: 22))
        cg.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 22, width: 32 * 7, height: 22))
        for (i, st) in styles.enumerated() {
            MenuIconArt.draw(st.id, cg: cg, rect: CGRect(x: CGFloat(i) * 32 + 2, y: 2, width: 28, height: 18), phase: 0.12, load: 0.6, color: NSColor.black.cgColor)
            MenuIconArt.draw(st.id, cg: cg, rect: CGRect(x: CGFloat(i) * 32 + 2, y: 24, width: 28, height: 18), phase: 0.62, load: 0.6, color: NSColor.white.cgColor)
        }
    }
    if let rep = actual.representations.first as? NSBitmapImageRep { write(rep, "menu-icons-actual.png") }
    print("snapshots written: \(outDir)")
}

private func cpuNow() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
}

private func footprintMB() -> Double {
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { q in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, q)
        }
    }
    return Double(info.ri_phys_footprint) / 1_048_576
}

/// 処理ごとのCPU時間とメモリを測って表示する（--bench）
func runBench() {
    let store = Store(persist: false)
    print(String(format: "start footprint %.1f MB", footprintMB()))
    for _ in 0..<3 { store.sampler.tick(processInterval: 0); usleep(100_000) }
    print(String(format: "after sampling %.1f MB", footprintMB()))
    func measure(_ name: String, _ n: Int, _ body: () -> Void) {
        let c0 = cpuNow()
        for _ in 0..<n { autoreleasepool { body() } }
        print(String(format: "%-12@ %8.2f ms", name as NSString, (cpuNow() - c0) / Double(n) * 1000))
    }
    for (name, f) in store.sampler.benchParts() { measure(name, 20, f) }
    measure("graphsIcon", 50) { _ = renderStatusGraphs(store: store) }
    measure("heartFrame", 50) {
        _ = renderIconBitmap(size: MenuIconArt.size) { cg in
            MenuIconArt.draw("heart", cg: cg, rect: CGRect(origin: .zero, size: MenuIconArt.size), phase: 0.3, load: 0, color: NSColor.black.cgColor)
        }
    }
    let hw = store.sampler.hardware
    print("chip: \(hw.chip) | model: \(hw.model) | P \(hw.performanceCores) E \(hw.efficiencyCores) | cores: \(hw.coreLabels)")
    print("gpu: \(store.sampler.gpuName ?? "nil") cores \(store.sampler.gpuCores.map(String.init) ?? "nil") renderer \(String(describing: store.sampler.gpuRenderer)) memory \(String(describing: store.sampler.gpuMemory))")
    print("sensors: \(store.sampler.sensors.prefix(6).map { "\($0.name)=\(Int($0.value))" })")
    print("battery: \(String(describing: store.sampler.battery))")
    print("interfaces: \(store.sampler.interfaces.map { "\($0.display)/\($0.name)/\($0.ipv4 ?? "-")" })")
    print("volumes: \(store.sampler.volumes.map { $0.name })")
    func benchDraw(_ view: DashboardView, _ label: String, tabs: [DashTab]) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        for theme in store.themes where ["mochi", "neon", "arcade"].contains(theme.def.id) {
            store.select(theme)
            for tab in tabs {
                view.tab = tab
                measure("\(label)/\(theme.def.id)/\(tab.rawValue)", 10) { view.cacheDisplay(in: view.bounds, to: rep) }
            }
        }
    }
    benchDraw(DashboardView(store: store, mode: .tray, frame: NSRect(x: 0, y: 0, width: DashboardView.trayWidth, height: DashboardView.trayHeight)), "tray", tabs: [.overview])
    benchDraw(DashboardView(store: store, mode: .window, frame: NSRect(x: 0, y: 0, width: 1040, height: 680)), "window", tabs: DashTab.allCases)
    print(String(format: "after panel draw %.1f MB", footprintMB()))
}
