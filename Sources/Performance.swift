import AppKit

enum PerfPage: String, CaseIterable {
    case cpu, memory, gpu, disk, network, power
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .disk: return "Disk"
        case .network: return "Network"
        case .power: return "Power"
        }
    }
}

/// タスクマネージャーのように、左で項目を選んで右に詳細を大きく出す画面
extension DashboardView {
    func drawPerformance(_ c: CGRect) {
        let listW: CGFloat = 188
        var y = c.minY
        for page in PerfPage.allCases {
            let r = CGRect(x: c.minX, y: y, width: listW, height: 62)
            drawPerfItem(page, r)
            y += 68
        }

        let d = CGRect(x: c.minX + listW + 14, y: c.minY, width: c.width - listW - 14, height: c.height)
        let off = min(scroll[.performance] ?? 0, maxScroll[.performance] ?? 0)
        ctx.saveGState()
        ctx.clip(to: d.insetBy(dx: -2, dy: -2))
        clip = d.insetBy(dx: -2, dy: -2)
        let top = d.minY - off
        let end: CGFloat
        switch perfPage {
        case .cpu: end = drawPerfCPU(d, y: top)
        case .memory: end = drawPerfMemory(d, y: top)
        case .gpu: end = drawPerfGPU(d, y: top)
        case .disk: end = drawPerfDisk(d, y: top)
        case .network: end = drawPerfNetwork(d, y: top)
        case .power: end = drawPerfPower(d, y: top)
        }
        clip = nil
        ctx.restoreGState()
        maxScroll[.performance] = max(0, end + off - d.maxY)
    }

    private func perfItemInfo(_ page: PerfPage) -> (value: String, sub: String, color: NSColor, series: [Double]) {
        let s = store.sampler
        switch page {
        case .cpu:
            return (pct(s.cpu), "\(s.coreLoads.count) cores", t.cpu, s.cpuS.last(40))
        case .memory:
            let f = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
            return (pct(f), "\(formatBytes(s.memUsed)) used", t.memory, s.memS.last(40))
        case .gpu:
            return (s.gpu.map(pct) ?? "—", s.gpuCores.map { "\($0) cores" } ?? "Graphics", t.gpu, s.gpuS.last(40))
        case .disk:
            let scale = max(s.diskS.values.max() ?? 0, 1_048_576)
            return (formatRate(s.diskRead + s.diskWrite), "\(formatBytes(UInt64(max(s.diskFree, 0)))) free", t.disk, s.diskS.last(40).map { $0 / scale })
        case .network:
            let scale = max(s.downS.values.max() ?? 0, 256 * 1024)
            return (formatRate(s.netDown), "↑ \(formatRate(s.netUp))", t.network, s.downS.last(40).map { $0 / scale })
        case .power:
            let temp = (s.socTemp ?? s.battery?.temperature).map { "\(Int($0.rounded()))°C" } ?? "—"
            let scale = max(s.tempS.values.max() ?? 0, 60)
            return (s.battery.map { pct($0.percent) } ?? temp, s.battery == nil ? thermalLabel(s.thermal).0 : temp, t.battery, s.tempS.last(40).map { $0 / scale })
        }
    }

    private func drawPerfItem(_ page: PerfPage, _ r: CGRect) {
        let info = perfItemInfo(page)
        let active = perfPage == page
        let path = rounded(r, max(t.corner - 6, 2))
        ctx.addPath(path)
        ctx.setFillColor(isHover(r) && !active ? info.color.cg(0.1) : (active ? info.color.cg(0.14) : t.surface.cg(surfaceAlpha)))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(active ? info.color.cg() : t.border.cg(0.7))
        ctx.setLineWidth(active ? 2 : 1)
        ctx.strokePath()
        text(page.title, r.minX + 10, r.minY + 8, t.font(12, .regular), t.text)
        text(info.value, r.minX + 10, r.minY + 26, t.font(12.5, .regular), info.color, maxW: 86)
        text(info.sub, r.minX + 10, r.minY + 44, t.font(9.5), t.textDim, maxW: 86)
        plotGraph(rect: CGRect(x: r.minX + 100, y: r.minY + 12, width: r.width - 110, height: r.height - 24),
                  values: info.series, color: info.color, style: t.graph, capacity: 40, glow: 0, lineWidth: 1.2)
        addHit(r, label: "\(page.title) details") { [unowned self] in
            self.perfPage = page
            self.scroll[.performance] = 0
        }
    }

    // MARK: - 共通部品

    private func pageHeader(_ title: String, detail: String, _ d: CGRect, y: CGFloat) -> CGFloat {
        let w = text(title, d.minX, y, t.font(21, .medium), t.text, glow: true)
        text(detail, d.maxX, y + 8, t.font(11), t.textDim, align: .right, maxW: max(d.width - w - 16, 40))
        return y + 38
    }

    /// 大きいグラフ。横軸は計測時刻から決める。
    /// 間隔が揃った履歴は今まで通りなめらかに流し、温度や電力のように間隔がまちまちのもの（window を指定）や、
    /// 途中で更新間隔が変わった・スリープで途切れた履歴は、時刻の位置に描いて空白は空白のまま残す。
    private func bigGraph(_ r: CGRect, title: String, value: String, series: Series, scale: Double = 1, color: NSColor,
                          capacity: Int = 120, scaleTop: String = "100%", window: Double? = nil, maxGap: Double? = nil,
                          emptyNote: String? = nil) {
        card(r)
        text(title, r.minX + 12, r.minY + 9, t.font(11.5, .regular), t.textDim)
        text(value, r.maxX - 12, r.minY + 5, t.font(18, .regular), color, align: .right, glow: true)
        let plot = CGRect(x: r.minX + 12, y: r.minY + 36, width: r.width - 24, height: r.height - 58)
        ctx.setStrokeColor(t.border.cg(0.55))
        ctx.setLineWidth(1)
        for f in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let gy = floor(plot.maxY - plot.height * f) + 0.5
            ctx.move(to: CGPoint(x: plot.minX, y: gy))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: gy))
        }
        ctx.strokePath()
        let now = CFAbsoluteTimeGetCurrent()
        let shownTimes = Array(series.times.suffix(capacity))
        let values = scale == 1 ? series.values : series.values.map { $0 / scale }
        let span: Double
        if window == nil, let step = regularInterval(shownTimes) {
            plotGraph(rect: plot, values: values, color: color, style: t.graph, capacity: capacity, glow: t.glow, lineWidth: 1.8)
            span = Double(capacity - 1) * step
        } else {
            let w = window ?? max(now - (shownTimes.first ?? now), 60)
            drawTimedGraph(plot, times: series.times, values: values, now: now, window: w, color: color,
                           maxGap: maxGap ?? max(store.interval * 3, 10))
            span = w
        }
        if series.values.isEmpty, let emptyNote {
            text(emptyNote, plot.midX, plot.midY - 8, t.font(11.5), t.textDim, align: .center)
        }
        text(spanLabel(span), plot.minX, plot.maxY + 4, t.font(9.5), t.textDim)
        text("Top \(scaleTop)", plot.maxX, plot.maxY + 4, t.font(9.5), t.textDim, align: .right)
    }

    /// 計測時刻の位置に描く。間が maxGap より空いたところ（スリープなど）は線を切る
    private func drawTimedGraph(_ plot: CGRect, times: [Double], values: [Double], now: Double, window: Double,
                                color: NSColor, maxGap: Double) {
        let bins = max(2, min(240, Int(plot.width / 3)))
        let binned = binTimed(times: times, values: values, now: now, window: window, bins: bins, maxGap: maxGap)
        let step = plot.width / CGFloat(bins)
        let style: GraphStyle = t.graph
        for run in contiguousRuns(binned) where run.values.count == 1 {
            // 1点だけの区間は点で示す
            let x = plot.minX + CGFloat(run.start + 1) * step
            let y = plot.maxY - CGFloat(min(max(run.values[0], 0), 1)) * plot.height
            ctx.setFillColor(color.cg())
            ctx.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
        }
        for run in contiguousRuns(binned) where run.values.count >= 2 {
            let x0 = plot.minX + CGFloat(run.start + 1) * step
            let rect = CGRect(x: x0, y: plot.minY, width: CGFloat(run.values.count - 1) * step, height: plot.height)
            drawGraph(ctx, rect: rect, values: run.values, color: color, style: style, capacity: run.values.count,
                      glow: t.glow, lineWidth: 1.8, fillAlpha: style == .line ? 0.26 : 0.32, fill: style == .line && store.graphFill)
        }
    }

    private func statGrid(_ items: [(String, String)], x: CGFloat, y: CGFloat, w: CGFloat, cols: Int) -> CGFloat {
        let rows = Int(ceil(Double(items.count) / Double(max(cols, 1))))
        let r = CGRect(x: x, y: y, width: w, height: CGFloat(rows) * 44 + 8)
        card(r)
        let cw = (w - 16) / CGFloat(cols)
        for (i, item) in items.enumerated() {
            let cx = x + 12 + CGFloat(i % cols) * cw
            let cy = y + 8 + CGFloat(i / cols) * 44
            text(item.0, cx, cy, t.font(10), t.textDim, maxW: cw - 10)
            text(item.1, cx, cy + 15, t.font(14, .regular), t.text, maxW: cw - 10)
        }
        return r.maxY
    }

    private func processTable(_ title: String, sort: ProcSort, x: CGFloat, y: CGFloat, w: CGFloat, count: Int) -> CGFloat {
        let rows = store.sampler.processes.list(grouped: store.groupApps, sort: sort).prefix(count)
        let r = CGRect(x: x, y: y, width: w, height: 32 + CGFloat(count) * 24 + 6)
        card(r)
        text(title, x + 12, y + 9, t.font(11.5, .regular), t.textDim)
        text("CPU", x + w - 72, y + 10, t.font(10, .regular), t.textDim, align: .right)
        text("Memory", x + w - 12, y + 10, t.font(10, .regular), t.textDim, align: .right)
        var ry = y + 32
        for row in rows {
            drawIcon(row, x: x + 12, y: ry + 1, size: 16)
            text(row.name, x + 34, ry, t.font(11.5), t.text, maxW: w - 34 - 124)
            text(String(format: row.cpu >= 10 ? "%.0f%%" : "%.1f%%", row.cpu), x + w - 72, ry, t.font(11.5, .regular), t.cpu, align: .right)
            text(formatBytes(row.mem), x + w - 12, ry, t.font(11), t.memory, align: .right)
            ry += 24
        }
        return r.maxY
    }

    // MARK: - CPU

    private func drawPerfCPU(_ d: CGRect, y start: CGFloat) -> CGFloat {
        let s = store.sampler
        let hw = s.hardware
        var y = pageHeader("CPU", detail: hw.chip, d, y: start)
        let cores = s.coreS
        let cols = max(2, min(max(cores.count, 2), Int((d.width + 8) / 118)))
        let rows = Int(ceil(Double(max(cores.count, 1)) / Double(cols)))
        let cellH: CGFloat = 72
        let coreBlock = 28 + CGFloat(rows) * (cellH + 8)
        let fixed: CGFloat = 38 + coreBlock + 10 + 96 + 10 + 164 + 10
        let graphH = max(170, d.height - fixed)
        bigGraph(CGRect(x: d.minX, y: y, width: d.width, height: graphH), title: "Utilization",
                 value: pct(s.cpu), series: s.cpuS, color: t.cpu)
        y += graphH + 10

        text("Cores", d.minX + 2, y + 4, t.font(11.5, .regular), t.textDim)
        y += 26
        let cw = (d.width - 8 * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, series) in cores.enumerated() {
            let cell = CGRect(x: d.minX + CGFloat(i % cols) * (cw + 8), y: y + CGFloat(i / cols) * (cellH + 8), width: cw, height: cellH)
            drawCoreCell(cell, index: i, series: series, large: true)
        }
        y += CGFloat(rows) * (cellH + 8) + 2

        let load = s.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
        y = statGrid([("User", pct(s.cpuUser)), ("System", pct(s.cpuSystem)), ("Idle", pct(max(1 - s.cpu, 0))),
                      ("Load average", load), ("Processes", "\(s.processes.totalCount)"),
                      ("Uptime", formatUptime(ProcessInfo.processInfo.systemUptime)),
                      ("Performance cores", "\(hw.performanceCores)"), ("Efficiency cores", "\(hw.efficiencyCores)")],
                     x: d.minX, y: y, w: d.width, cols: 4) + 10
        return processTable("Top by CPU", sort: .cpu, x: d.minX, y: y, w: d.width, count: 5)
    }

    // MARK: - メモリ

    private func drawPerfMemory(_ d: CGRect, y start: CGFloat) -> CGFloat {
        let s = store.sampler
        let frac = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        var y = pageHeader("Memory", detail: "\(formatBytes(s.memTotal)) installed", d, y: start)
        let fixed: CGFloat = 38 + 92 + 10 + 96 + 10 + 164 + 10
        let graphH = max(170, d.height - fixed)
        bigGraph(CGRect(x: d.minX, y: y, width: d.width, height: graphH), title: "Used", value: pct(frac), series: s.memS, color: t.memory)
        y += graphH + 10

        let box = CGRect(x: d.minX, y: y, width: d.width, height: 92)
        card(box)
        text("Composition", box.minX + 12, box.minY + 9, t.font(11.5, .regular), t.textDim)
        memoryBar(CGRect(x: box.minX + 12, y: box.minY + 30, width: box.width - 24, height: 14))
        var parts = memoryParts.map { ($0.name, $0.bytes, $0.color) }
        parts.append(("Free", s.memFree, t.textDim))
        let lw = (box.width - 24) / CGFloat(parts.count)
        for (i, p) in parts.enumerated() {
            let x = box.minX + 12 + CGFloat(i) * lw
            ctx.setFillColor(p.2.cg())
            ctx.fillEllipse(in: CGRect(x: x, y: box.minY + 55, width: 7, height: 7))
            text(p.0, x + 11, box.minY + 51, t.font(10), t.textDim, maxW: lw - 12)
            text(formatBytes(p.1), x + 11, box.minY + 66, t.font(11.5, .regular), t.text, maxW: lw - 12)
        }
        y += 102

        let pressure = s.memPressureFree.map { "\(100 - $0)%" } ?? "—"
        y = statGrid([("Used", formatBytes(s.memUsed)), ("Pressure", pressure),
                      ("Swap used", "\(formatBytes(s.swapUsed)) / \(formatBytes(s.swapTotal))"),
                      ("Page ins", formatRate(s.pageIns)), ("Page outs", formatRate(s.pageOuts)),
                      ("GPU memory", s.gpuMemory.map(formatBytes) ?? "—")],
                     x: d.minX, y: y, w: d.width, cols: 3) + 10
        return processTable("Top by memory", sort: .mem, x: d.minX, y: y, w: d.width, count: 5)
    }

    // MARK: - GPU

    private func drawPerfGPU(_ d: CGRect, y start: CGFloat) -> CGFloat {
        let s = store.sampler
        var y = pageHeader("GPU", detail: s.gpuName ?? "Graphics", d, y: start)
        let fixed: CGFloat = 38 + 170 + 10 + 96 + 10
        let graphH = max(190, d.height - fixed)
        bigGraph(CGRect(x: d.minX, y: y, width: d.width, height: graphH), title: "Utilization",
                 value: s.gpu.map(pct) ?? "—", series: s.gpuS, color: t.gpu)
        y += graphH + 10
        let w = (d.width - 10) / 2
        bigGraph(CGRect(x: d.minX, y: y, width: w, height: 170), title: "Renderer", value: s.gpuRenderer.map(pct) ?? "—", series: s.gpuRenS, color: t.gpu)
        bigGraph(CGRect(x: d.minX + w + 10, y: y, width: w, height: 170), title: "Tiler", value: s.gpuTiler.map(pct) ?? "—", series: s.gpuTilS, color: t.accent)
        y += 180
        return statGrid([("Model", s.gpuName ?? "—"), ("Cores", s.gpuCores.map { "\($0)" } ?? "—"),
                         ("Memory in use", s.gpuMemory.map(formatBytes) ?? "—")],
                        x: d.minX, y: y, w: d.width, cols: 3)
    }

    // MARK: - ディスク

    private func drawPerfDisk(_ d: CGRect, y start: CGFloat) -> CGFloat {
        let s = store.sampler
        var y = pageHeader("Disk", detail: "\(s.volumes.count) volume\(s.volumes.count == 1 ? "" : "s")", d, y: start)
        let volumeH: CGFloat = 38 + CGFloat(max(s.volumes.count, 1)) * 42
        let fixed: CGFloat = 38 + 10 + 96 + 10 + volumeH
        let graphH = max(190, d.height - fixed)
        let w = (d.width - 10) / 2
        let scale = max(s.readS.values.max() ?? 0, s.writeS.values.max() ?? 0, 1_048_576)
        bigGraph(CGRect(x: d.minX, y: y, width: w, height: graphH), title: "Read", value: formatRate(s.diskRead),
                 series: s.readS, scale: scale, color: t.disk, scaleTop: formatRate(scale))
        bigGraph(CGRect(x: d.minX + w + 10, y: y, width: w, height: graphH), title: "Write", value: formatRate(s.diskWrite),
                 series: s.writeS, scale: scale, color: t.accent, scaleTop: formatRate(scale))
        y += graphH + 10
        y = statGrid([("Read operations", String(format: "%.0f /s", s.readOps)), ("Write operations", String(format: "%.0f /s", s.writeOps)),
                      ("Read since boot", formatBytes(s.totalRead)), ("Written since boot", formatBytes(s.totalWritten))],
                     x: d.minX, y: y, w: d.width, cols: 4) + 10
        let box = CGRect(x: d.minX, y: y, width: d.width, height: volumeH)
        card(box)
        text("Volumes", box.minX + 12, box.minY + 9, t.font(11.5, .regular), t.textDim)
        var ry = box.minY + 32
        for v in s.volumes {
            let used = v.total > 0 ? 1 - Double(v.free) / Double(v.total) : 0
            text(v.name, box.minX + 12, ry, t.font(11.5, .regular), t.text, maxW: box.width * 0.5)
            text("\(formatBytes(UInt64(max(v.free, 0)))) free of \(formatBytes(UInt64(max(v.total, 0))))", box.maxX - 12, ry, t.font(11), t.textDim, align: .right)
            levelBar(CGRect(x: box.minX + 12, y: ry + 20, width: box.width - 24, height: 6), used, used > 0.92 ? t.danger : t.disk)
            ry += 42
        }
        return box.maxY
    }

    // MARK: - 通信

    private func drawPerfNetwork(_ d: CGRect, y start: CGFloat) -> CGFloat {
        let s = store.sampler
        var y = pageHeader("Network", detail: s.interfaces.first?.display ?? "", d, y: start)
        let tableH: CGFloat = 38 + CGFloat(max(s.interfaces.count, 1)) * 46
        let fixed: CGFloat = 38 + 10 + 96 + 10 + tableH
        let graphH = max(190, d.height - fixed)
        let w = (d.width - 10) / 2
        let scale = max(s.downS.values.max() ?? 0, s.upS.values.max() ?? 0, 256 * 1024)
        bigGraph(CGRect(x: d.minX, y: y, width: w, height: graphH), title: "Download", value: formatRate(s.netDown),
                 series: s.downS, scale: scale, color: t.network, scaleTop: formatRate(scale))
        bigGraph(CGRect(x: d.minX + w + 10, y: y, width: w, height: graphH), title: "Upload", value: formatRate(s.netUp),
                 series: s.upS, scale: scale, color: t.disk, scaleTop: formatRate(scale))
        y += graphH + 10
        y = statGrid([("Peak download", formatRate(s.peakDown)), ("Peak upload", formatRate(s.peakUp)),
                      ("Downloaded (session)", formatBytes(s.sessionDown)), ("Uploaded (session)", formatBytes(s.sessionUp))],
                     x: d.minX, y: y, w: d.width, cols: 4) + 10
        let box = CGRect(x: d.minX, y: y, width: d.width, height: tableH)
        card(box)
        text("Interfaces", box.minX + 12, box.minY + 9, t.font(11.5, .regular), t.textDim)
        var ry = box.minY + 32
        if s.interfaces.isEmpty {
            text("No active interfaces", box.minX + 12, ry, t.font(11.5), t.textDim)
        }
        for i in s.interfaces {
            text("\(i.display)  (\(i.name))", box.minX + 12, ry, t.font(11.5, .regular), t.text, maxW: box.width * 0.55)
            text("↓ \(formatRate(i.down))   ↑ \(formatRate(i.up))", box.maxX - 12, ry, t.font(11), t.network, align: .right)
            text(i.ipv4 ?? "No IPv4 address", box.minX + 12, ry + 17, t.font(10.5), t.textDim, maxW: box.width * 0.55)
            text("\(formatBytes(i.received)) down · \(formatBytes(i.sent)) up", box.maxX - 12, ry + 17, t.font(10.5), t.textDim, align: .right)
            ry += 46
        }
        return box.maxY
    }

    // MARK: - 電源と熱

    private func drawPerfPower(_ d: CGRect, y start: CGFloat) -> CGFloat {
        let s = store.sampler
        let (label, color) = thermalLabel(s.thermal)
        var y = pageHeader("Power", detail: "Thermal state: \(label)", d, y: start)
        let w = (d.width - 10) / 2
        let sensorRows = min(s.sensors.count, 8)
        let sensorH: CGFloat = sensorRows > 0 ? 38 + CGFloat(Int(ceil(Double(sensorRows) / 2))) * 20 : 0
        let fanBoxH: CGFloat = s.fans.isEmpty ? 0 : 32 + CGFloat(s.fans.count) * 34
        let fixed: CGFloat = 38 + 106 + 10 + 96 + 10 + sensorH + (fanBoxH > 0 ? fanBoxH + 10 : 0)
        let graphH = max(170, d.height - fixed)

        if let b = s.battery {
            let box = CGRect(x: d.minX, y: y, width: d.width, height: 96)
            card(box)
            text(pct(b.percent), box.minX + 14, box.minY + 8, t.font(28, .regular), t.battery, glow: true)
            text(batteryStateText(b), box.minX + 96, box.minY + 18, t.font(13, .regular), t.text, maxW: box.width - 110)
            levelBar(CGRect(x: box.minX + 14, y: box.minY + 58, width: box.width - 28, height: 14), b.percent, b.percent < 0.2 && !b.charging ? t.danger : t.battery)
            y += 106
        }
        // 温度は10秒ごと、電力は5〜30秒ごとの記録なので、直近30分を時刻の位置に描く
        let window: Double = 30 * 60
        bigGraph(CGRect(x: d.minX, y: y, width: w, height: graphH), title: "Temperature",
                 value: (s.socTemp ?? s.battery?.temperature).map { "\(Int($0.rounded()))°C" } ?? "—",
                 series: s.tempS, scale: 100, color: color, capacity: s.tempS.cap, scaleTop: "100°C", window: window, maxGap: 45)
        // Mac 全体の電力が取れない時は、電池の出入りを「Battery power」として出す（全体の電力とは混ぜない）
        let reading = PowerReading.from(systemWatts: s.battery?.systemWatts, batteryWatts: s.battery?.watts)
        let powerSeries: Series
        let powerValue: String
        switch reading {
        case .system(let v): powerSeries = s.powerS; powerValue = String(format: "%.1f W", v)
        case .battery(let v): powerSeries = s.batteryPowerS; powerValue = String(format: "%.1f W", v)
        case .unavailable: powerSeries = s.powerS; powerValue = "—"
        }
        let wattScale = max(powerSeries.values.max() ?? 0, 10)
        bigGraph(CGRect(x: d.minX + w + 10, y: y, width: w, height: graphH), title: reading.title, value: powerValue,
                 series: powerSeries, scale: wattScale, color: t.accent, capacity: powerSeries.cap,
                 scaleTop: String(format: "%.0f W", wattScale), window: window, maxGap: 75,
                 emptyNote: reading == .unavailable ? "Not available on this Mac" : nil)
        y += graphH + 10

        if let b = s.battery {
            y = statGrid([("Maximum capacity", b.health.map(pct) ?? "—"), ("Cycle count", b.cycles.map { "\($0)" } ?? "—"),
                          ("Voltage", b.voltage.map { String(format: "%.2f V", $0) } ?? "—"),
                          ("Current", b.amperage.map { String(format: "%.2f A", $0) } ?? "—"),
                          ("Battery temperature", b.temperature.map { String(format: "%.1f°C", $0) } ?? "—"),
                          ("Power adapter", b.adapterWatts.map { a in "\(a) W" + (b.inputWatts.map { String(format: " · using %.1f W", $0) } ?? "") } ?? "—"),
                          ("Design capacity", b.designCapacity.map { "\($0) mAh" } ?? "—"),
                          ("Full charge", b.maxCapacity.map { "\($0) mAh" } ?? "—")],
                         x: d.minX, y: y, w: d.width, cols: 4) + 10
        }
        if !s.fans.isEmpty {
            let box = CGRect(x: d.minX, y: y, width: d.width, height: fanBoxH)
            card(box)
            text("Fans", box.minX + 12, box.minY + 9, t.font(11.5, .regular), t.textDim)
            let rangeW: CGFloat = 150
            let gx = box.minX + 220
            let avail = box.maxX - 12 - rangeW - 12 - gx
            for (i, f) in s.fans.enumerated() {
                let ry = box.minY + 32 + CGFloat(i) * 34
                text(f.name, box.minX + 12, ry, t.font(12), t.text)
                text(formatRPM(f.rpm), box.minX + 100, ry, t.font(12, .regular), t.accent, glow: true)
                if i < s.fanS.count, avail > 60 {
                    plotGraph(rect: CGRect(x: gx, y: ry - 3, width: avail * 0.55, height: 22), values: s.fanS[i].values,
                              color: t.accent, style: t.graph, capacity: 60, glow: 0, lineWidth: 1.2)
                }
                if avail > 60 {
                    let bx = gx + avail * 0.55 + 14
                    levelBar(CGRect(x: bx, y: ry + 5, width: gx + avail - bx, height: 6), f.level, t.accent)
                }
                if f.max > 0 {
                    text("\(formatRPM(f.min).replacingOccurrences(of: " rpm", with: "")) – \(formatRPM(f.max))",
                         box.maxX - 12, ry, t.font(10.5), t.textDim, align: .right, maxW: rangeW)
                }
            }
            y = box.maxY + 10
        }
        guard sensorRows > 0 else { return y }
        let box = CGRect(x: d.minX, y: y, width: d.width, height: sensorH)
        card(box)
        text("Hottest sensors", box.minX + 12, box.minY + 9, t.font(11.5, .regular), t.textDim)
        let cw = (box.width - 36) / 2
        for (i, sensor) in s.sensors.prefix(8).enumerated() {
            kvRow(sensor.name, String(format: "%.1f°C", sensor.value),
                  x: box.minX + 12 + CGFloat(i % 2) * (cw + 12), y: box.minY + 32 + CGFloat(i / 2) * 20, w: cw, limit: box.maxY)
        }
        return box.maxY
    }
}
