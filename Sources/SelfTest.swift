import AppKit

/// --selftest：計算と操作の確認。ビルドのたびに実行し、1つでも失敗したらビルドを止める。
func runSelfTest() -> Int32 {
    var passed = 0, failed = 0
    func check(_ ok: Bool, _ name: String) {
        if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }

    // MARK: 通信量のカウンタ
    check(counterDelta(previous: nil, current: 500) == 0, "counter: first sample only sets the baseline")
    check(counterDelta(previous: 100, current: 600) == 500, "counter: normal increase")
    let sixGiB: UInt64 = 6 << 30
    check(counterDelta(previous: 10, current: 10 + sixGiB) == sixGiB, "counter: more than 4 GiB in one interval is kept (64-bit)")
    check(counterDelta(previous: 9_000_000_000, current: 1_234) == 0, "counter: a reset counts as zero, not a huge jump")

    // MARK: ディスクの抜き差し
    let base = DiskCounters(readBytes: 1_000, writeBytes: 2_000, readOps: 10, writeOps: 20)
    var prev: [UInt64: DiskCounters] = [1: base]
    var cur: [UInt64: DiskCounters] = [1: DiskCounters(readBytes: 1_500, writeBytes: 2_100, readOps: 15, writeOps: 21),
                                       2: DiskCounters(readBytes: 900_000_000_000, writeBytes: 500_000_000_000, readOps: 9_000_000, writeOps: 7_000_000)]
    var d = diskDeltas(previous: prev, current: cur)
    check(d == DiskCounters(readBytes: 500, writeBytes: 100, readOps: 5, writeOps: 1), "disk: attaching a disk does not add its old totals")
    prev = cur
    cur = [1: DiskCounters(readBytes: 1_600, writeBytes: 2_100, readOps: 16, writeOps: 21)]
    d = diskDeltas(previous: prev, current: cur)
    check(d.readBytes == 100 && d.writeBytes == 0, "disk: detaching a disk gives the remaining disks' activity only")
    prev = cur
    cur = [1: DiskCounters(readBytes: 10, writeBytes: 10, readOps: 1, writeOps: 1)]
    d = diskDeltas(previous: prev, current: cur)
    check(d == DiskCounters(), "disk: a counter reset counts as zero")

    // MARK: 時間軸
    let now = 100_000.0
    let tenSec = (0..<120).map { now - 1_200 + Double($0) * 10 + 10 }   // 直近20分、10秒ごと
    var bins = binTimed(times: tenSec, values: tenSec.map { _ in 0.5 }, now: now, window: 1_800, bins: 180, maxGap: 45)
    let firstFilled = bins.firstIndex { $0 != nil } ?? -1
    check(firstFilled >= 59 && firstFilled <= 61, "time axis: 20 minutes of data fills only the right two thirds of a 30 minute window (first bin \(firstFilled))")
    check(bins.suffix(110).allSatisfy { $0 != nil }, "time axis: recent bins are filled")
    let sleepTimes = (0..<60).map { now - 1_800 + Double($0) * 10 } + (0..<30).map { now - 300 + Double($0) * 10 }
    bins = binTimed(times: sleepTimes, values: sleepTimes.map { _ in 0.4 }, now: now, window: 1_800, bins: 180, maxGap: 45)
    check(contiguousRuns(bins).count == 2, "time axis: a sleep gap breaks the line into two parts")
    check(regularInterval([0, 2, 4, 6, 8]) == 2, "time axis: regular interval is detected")
    check(regularInterval([0, 2, 4, 9, 14, 19]) == nil, "time axis: a changed update interval is detected")
    check(regularInterval([0, 2, 4, 600, 602]) == nil, "time axis: a sleep gap is detected")
    check(spanLabel(1_800) == "30 min ago" && spanLabel(238) == "4 min ago" && spanLabel(45) == "45 sec ago", "time axis: span labels")

    // MARK: 電力
    check(PowerReading.from(systemWatts: 6.5, batteryWatts: 21) == .system(6.5), "power: system power is preferred")
    let fallback = PowerReading.from(systemWatts: nil, batteryWatts: 8)
    check(fallback == .battery(8) && fallback.title == "Battery power", "power: battery power is labelled as battery power")
    check(PowerReading.from(systemWatts: nil, batteryWatts: nil) == .unavailable, "power: unavailable when neither is known")

    // MARK: 終了
    var signals: [(Int32, Int32)] = []
    var forced: [Int32] = []
    func control(apps: [Int32: Bool], starts: [Int32: UInt64], signalErr: Int32 = 0) -> ProcessControl {
        ProcessControl(terminateApp: { apps[$0] },
                       forceTerminateApp: { pid in
                           guard apps[pid] != nil else { return nil }
                           forced.append(pid)
                           return true
                       },
                       signal: { pid, sig in signals.append((pid, sig)); return signalErr },
                       startTime: { starts[$0] },
                       selfPID: 999)
    }
    var out = requestQuit([QuitTarget(pid: 100, start: 1)], control: control(apps: [100: false], starts: [100: 1]))
    check(out.accepted.isEmpty && (out.failure ?? "").contains("didn't accept"), "quit: an app refusing to quit is reported")
    signals = []
    out = requestQuit([QuitTarget(pid: 100, start: 1), QuitTarget(pid: 101, start: 1)], control: control(apps: [100: true], starts: [:]))
    check(out.accepted.map(\.pid) == [100] && signals.isEmpty, "quit: apps are asked to quit normally, helpers are not signalled")
    signals = []
    out = requestQuit([QuitTarget(pid: 200, start: 1)], control: control(apps: [:], starts: [:], signalErr: EPERM))
    check(signals.first?.1 == SIGTERM && (out.failure ?? "").contains("Not permitted"), "quit: a plain process gets SIGTERM and failures are reported")
    signals = []
    out = requestQuit([QuitTarget(pid: 999, start: 1)], control: control(apps: [:], starts: [:]))
    check(signals.isEmpty && out.failure != nil, "quit: never quits itself")
    signals = []
    out = forceQuit([QuitTarget(pid: 300, start: 5)], control: control(apps: [:], starts: [300: 6]))
    check(signals.isEmpty && (out.failure ?? "").contains("already quit"), "force quit: a reused pid is not killed")
    signals = []
    out = forceQuit([QuitTarget(pid: 300, start: 5)], control: control(apps: [:], starts: [300: 5]))
    check(signals.first.map { $0 == (300, SIGKILL) } ?? false && out.failure == nil, "force quit: the same process is killed")
    forced = []
    out = forceQuit([QuitTarget(pid: 100, start: 5)], control: control(apps: [100: true], starts: [100: 5]))
    check(forced == [100], "force quit: apps are force-terminated as apps")
    // 一部だけ成功した場合
    func partialControl(denied: Int32) -> ProcessControl {
        ProcessControl(terminateApp: { _ in nil }, forceTerminateApp: { _ in nil },
                       signal: { pid, _ in pid == denied ? EPERM : 0 },
                       startTime: { _ in 7 }, selfPID: 999)
    }
    let two = [QuitTarget(pid: 400, start: 7), QuitTarget(pid: 401, start: 7)]
    out = requestQuit(two, control: partialControl(denied: 401))
    check(out.accepted.map(\.pid) == [400] && out.failed.map(\.pid) == [401] && (out.failure ?? "").contains("1 of 2"),
          "quit: a partial failure keeps what succeeded and reports what didn't")
    out = forceQuit(two, control: partialControl(denied: 401))
    check(out.accepted.map(\.pid) == [400] && out.failed.map(\.pid) == [401] && (out.failure ?? "").contains("1 of 2"),
          "force quit: a partial failure is reported")
    out = requestQuit([QuitTarget(pid: 100, start: 1), QuitTarget(pid: 102, start: 1)],
                      control: control(apps: [100: true, 102: false], starts: [:]))
    check(out.accepted.map(\.pid) == [100] && (out.failure ?? "").contains("1 of 2 apps"), "quit: one app refusing out of two is reported")

    // MARK: カードから詳細画面へ
    let store = Store(persist: false)
    for _ in 0..<3 { store.sampler.tick(processInterval: 0); usleep(50_000) }
    let saved = (store.layout, store.trayItems, store.trayDetail)
    store.layout = WidgetConfig.defaults
    store.trayItems = Store.allTrayItems
    let kinds = Store.allTrayItems
    func render(_ v: DashboardView) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
    }
    func cardHit(_ v: DashboardView, _ kind: String) -> DashboardView.Hit? {
        v.hits.first { $0.pointer && $0.label.hasPrefix(WidgetConfig.title(kind) + ",") }
    }
    let win = DashboardView(store: store, mode: .window, frame: NSRect(x: 0, y: 0, width: 1040, height: 680))
    for level in 0...2 {
        store.layout = WidgetConfig.defaults.map { var c = $0; c.detail = level; return c }
        for kind in kinds {
            win.tab = .overview
            win.editingLayout = false
            win.scroll[.performance] = 240
            win.scroll[.processes] = 240
            render(win)
            guard let h = cardHit(win, kind) else { check(false, "overview: \(kind) card is clickable (detail \(level))"); continue }
            win.performClick(at: CGPoint(x: h.rect.midX, y: h.rect.midY))
            let want = Destination.forCard(kind)
            let ok: Bool
            switch want {
            case .performance(let p): ok = win.tab == .performance && win.perfPage == p && win.scroll[.performance] == 0
            case .processes: ok = win.tab == .processes && win.scroll[.processes] == 0
            }
            check(ok, "overview: \(kind) card opens \(want.label) at the top (detail \(level))")
        }
    }
    store.layout = WidgetConfig.defaults
    win.tab = .overview
    win.editingLayout = true
    render(win)
    check(!win.hits.contains { $0.pointer }, "overview: cards are not clickable while editing the layout")
    let cpuRect = win.widgetZones.first { $0.kind == "cpu" }?.rect ?? .zero
    win.performClick(at: CGPoint(x: cpuRect.midX, y: cpuRect.midY + 40))
    check(win.tab == .overview && win.editingLayout, "overview: clicking a card while editing does not navigate")
    if let hide = win.hits.first(where: { $0.label == "Hide CPU" }) {
        win.performClick(at: CGPoint(x: hide.rect.midX, y: hide.rect.midY))
        check(store.layout.first { $0.kind == "cpu" }?.visible == false, "overview: the hide button still works while editing")
    } else {
        check(false, "overview: hide button exists while editing")
    }
    store.layout = WidgetConfig.defaults
    win.editingLayout = false

    let tray = DashboardView(store: store, mode: .tray, frame: NSRect(x: 0, y: 0, width: DashboardView.trayWidth, height: DashboardView.trayHeight))
    var opened: Destination? = nil
    tray.onNavigate = { opened = $0 }
    for level in 0...2 {
        store.trayDetail = level
        tray.setFrameSize(NSSize(width: DashboardView.trayWidth, height: tray.trayLayout().height))
        for kind in kinds {
            opened = nil
            render(tray)
            guard let h = cardHit(tray, kind) else { check(false, "panel: \(kind) card is clickable (detail \(level))"); continue }
            tray.performClick(at: CGPoint(x: h.rect.midX, y: h.rect.midY))
            check(opened == Destination.forCard(kind), "panel: \(kind) card asks to open \(Destination.forCard(kind).label) (detail \(level))")
        }
    }
    render(tray)
    if let h = cardHit(tray, "memory") {
        tray.updateCursor(at: CGPoint(x: h.rect.midX, y: h.rect.midY))
        check(tray.wantsPointer, "panel: pointing hand over a card")
        tray.updateCursor(at: CGPoint(x: -10, y: -10))
        check(!tray.wantsPointer, "panel: normal cursor outside cards")
    }

    // MARK: 常に手前のパネル
    let savedFloat = store.floatItems
    store.floatItems = Store.allTrayItems
    let float = DashboardView(store: store, mode: .float, frame: NSRect(x: 0, y: 0, width: DashboardView.floatWidth, height: 200))
    float.onNavigate = { opened = $0 }
    float.setFrameSize(NSSize(width: DashboardView.floatWidth, height: float.trayLayout().height))
    for kind in kinds {
        opened = nil
        render(float)
        guard let h = cardHit(float, kind) else { check(false, "floating panel: \(kind) card is clickable"); continue }
        float.performClick(at: CGPoint(x: h.rect.midX, y: h.rect.midY))
        check(opened == Destination.forCard(kind), "floating panel: \(kind) card asks to open \(Destination.forCard(kind).label)")
    }
    store.floatItems = ["cpu", "network"]
    check(float.trayLayout().items.map { $0.kind } == ["cpu", "network"], "floating panel: shows only the chosen items")
    store.floatItems = savedFloat

    // MARK: キーボードと読み上げ
    // 終了の操作は、マウスを乗せていなくても見えている行すべてに登録される
    win.tab = .processes
    win.hover = nil
    render(win)
    let quitButtons = win.hits.filter { $0.label.hasPrefix("Quit ") }.count
    check(quitButtons > 3, "keyboard: quit buttons are reachable without hovering (\(quitButtons) visible rows)")
    // 画面上の行で「Quit」→ 確認の「Quit」ボタンまでキーボードで進める
    let fake = ProcessControl(terminateApp: { _ in nil }, forceTerminateApp: { _ in nil },
                              signal: { pid, _ in pid % 2 == 0 ? 0 : EPERM }, startTime: { _ in 1 }, selfPID: getpid())
    win.processControl = fake
    if let i = win.hits.firstIndex(where: { $0.label.hasPrefix("Quit ") }) {
        win.focusIndex = i
        win.hits[i].action()
        render(win)
        check(win.hits.contains { $0.label == "Quit" } && win.hits.contains { $0.label == "Cancel" },
              "keyboard: the quit confirmation buttons are reachable")
        win.hits.first { $0.label == "Cancel" }?.action()
    }
    win.processControl = .live
    win.tab = .settings
    win.settingsPage = .appearance
    render(win)
    if let i = win.hits.firstIndex(where: { $0.label == "Transparency" }) {
        let before = store.transparency
        check(win.hits[i].value != nil && win.hits[i].adjust != nil, "accessibility: the transparency slider has a value and can be adjusted")
        win.hits[i].adjust?(1)
        check(abs(store.transparency - min(before + 0.05, 0.7)) < 0.001, "keyboard: the transparency slider goes up one step")
        win.hits[i].adjust?(-1)
        check(abs(store.transparency - before) < 0.001, "keyboard: the transparency slider goes down one step")
        render(win)
        let slider = (win.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            .first { $0.accessibilityLabel() == "Transparency" }
        check(slider?.accessibilityRole() == .slider && slider?.accessibilityValue() as? String == "\(Int((store.transparency * 100).rounded()))%",
              "accessibility: the slider is read out as a slider with its value")
    } else {
        check(false, "accessibility: the transparency slider is exposed")
    }
    let elements = win.accessibilityChildren() ?? []
    check(elements.count == win.hits.count && win.hits.allSatisfy { !$0.label.isEmpty }, "accessibility: every control is exposed with a label")
    check(win.hits.contains { $0.label == "Appearance" } && win.hits.contains { $0.label == "Overview" }, "accessibility: tabs and settings pages are named")
    win.focusIndex = nil
    win.moveFocus(by: 1)
    check(win.focusIndex == 0, "keyboard: Tab focuses the first control")
    win.moveFocus(by: -1)
    check(win.focusIndex == win.hits.count - 1, "keyboard: Shift-Tab wraps to the last control")
    if let i = win.hits.firstIndex(where: { $0.label == "Processes" }) {
        win.focusIndex = i
        win.hits[i].action()
        check(win.tab == .processes, "keyboard: activating a focused tab switches screens")
    }

    store.layout = saved.0
    store.trayItems = saved.1
    store.trayDetail = saved.2
    print("selftest: \(passed) passed, \(failed) failed")
    return failed == 0 ? 0 : 1
}
