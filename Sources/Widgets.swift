import AppKit

enum WidgetDetail: Int { case compact, standard, detailed }

/// Overview と2種類のパネルで共用するカード。詳細度で中身が変わる。
extension DashboardView {
    func drawWidget(_ kind: String, _ r: CGRect, detail: WidgetDetail) {
        switch kind {
        case "cpu": drawCPU(r, capacity: 90, detail: detail)
        case "memory": drawMemory(r, detail: detail)
        case "gpu": drawGPU(r, detail: detail)
        case "network": drawNetwork(r, detail: detail)
        case "disk": drawDisk(r, detail: detail)
        case "power": drawPower(r, detail: detail)
        default: drawTopApps(r, detail: detail)
        }
    }

    // MARK: - 部品

    func metricHeader(_ r: CGRect, _ label: String, value: String, color: NSColor, sub: String?) {
        text(label, r.minX + 12, r.minY + 9, t.font(11, .regular), t.textDim)
        // メニューバーのパネルでは数字を控えめにする
        let tray = isPanel
        text(value, r.maxX - 12, r.minY + (tray ? 8 : 6), t.font(tray ? 14 : 20, DashboardView.valueWeight), color, align: .right, glow: true)
        if let sub { text(sub, r.minX + 12, r.minY + 26, t.font(10), t.textDim, maxW: r.width - 24) }
    }

    func graphRect(_ r: CGRect, top: CGFloat = 46) -> CGRect {
        CGRect(x: r.minX + 12, y: r.minY + top, width: r.width - 24, height: r.height - top - 10)
    }

    func compactCard(_ r: CGRect, _ label: String, value: String, color: NSColor, bar: Double?, sub: String? = nil) {
        card(r)
        text(label, r.minX + 12, r.minY + 9, t.font(11, .regular), t.textDim)
        let size = max(16, min(r.height * 0.4, r.width * 0.2, 60))
        let f = t.font(size, .regular)
        let lh = f.ascender - f.descender
        let center = r.minY + 24 + (r.height - 24 - (bar == nil ? 8 : 18)) / 2
        text(value, r.minX + 12, center - lh / 2, f, color, maxW: r.width - 24, glow: true)
        if let sub { text(sub, r.maxX - 12, r.minY + 9, t.font(10), t.textDim, align: .right, maxW: r.width * 0.6) }
        if let bar {
            levelBar(CGRect(x: r.minX + 12, y: r.maxY - 16, width: r.width - 24, height: 6), bar, color)
        }
    }

    func levelBar(_ r: CGRect, _ value: Double, _ color: NSColor) {
        let radius = min(t.corner / 3, r.height / 2)
        ctx.addPath(rounded(r, radius))
        ctx.setFillColor(color.cg(0.18))
        ctx.fillPath()
        let v = CGFloat(min(max(value, 0), 1))
        plotBar(track: r, filled: CGRect(x: r.minX, y: r.minY, width: max(r.width * v, 2), height: r.height), color: color, radius: radius)
    }

    /// 左にラベル、右に値を置いた1行。枠に収まらない行は描かない。
    @discardableResult
    func kvRow(_ label: String, _ value: String, x: CGFloat, y: CGFloat, w: CGFloat, limit: CGFloat, color: NSColor? = nil) -> CGFloat {
        guard y + 15 <= limit else { return y }
        let valueW = text(value, x + w, y, t.font(10.5, .regular), color ?? t.text, align: .right, maxW: w * 0.62)
        text(label, x, y, t.font(10.5), t.textDim, maxW: max(w - valueW - 6, 10))
        return y + 17
    }

    var memoryParts: [(name: String, bytes: UInt64, color: NSColor)] {
        let s = store.sampler
        return [("App", s.memApp, t.memory), ("Wired", s.memWired, t.gpu),
                ("Compressed", s.memCompressed, t.disk), ("Cached", s.memCached, t.network)]
    }

    /// メモリの内訳バー
    func memoryBar(_ r: CGRect) {
        let total = max(Double(store.sampler.memTotal), 1)
        let radius = min(t.corner / 3, r.height / 2)
        ctx.saveGState()
        ctx.addPath(rounded(r, radius))
        ctx.clip()
        ctx.setFillColor(t.textDim.cg(0.16))
        ctx.fill(r)
        var x = r.minX
        for part in memoryParts {
            let w = r.width * CGFloat(Double(part.bytes) / total)
            ctx.setFillColor(part.color.cg())
            ctx.fill(CGRect(x: x, y: r.minY, width: w, height: r.height))
            x += w
        }
        ctx.restoreGState()
    }

    func formatUptime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let d = m / 1440, h = (m % 1440) / 60
        if d > 0 { return "\(d)d \(h)h" }
        return "\(h)h \(m % 60)m"
    }

    /// ラベルと値つきの小さいグラフ（GPU の Renderer / Tiler など）
    func miniGraphCell(_ r: CGRect, _ label: String, _ value: Double?, _ values: [Double], _ color: NSColor, short: String? = nil) {
        ctx.addPath(rounded(r, max(t.corner - 9, 2)))
        ctx.setFillColor(color.cg(0.07))
        ctx.fillPath()
        let narrow = r.width < 90
        let f = t.font(narrow ? 9 : 9.5, .regular)
        let pad: CGFloat = narrow ? 5 : 6
        let vw = text(value.map(pct) ?? "—", r.maxX - pad, r.minY + 3, f, color, align: .right)
        text(narrow ? (short ?? label) : label, r.minX + pad, r.minY + 3, f, t.textDim, maxW: r.width - vw - pad * 2 - 3)
        plotGraph(rect: CGRect(x: r.minX + 4, y: r.minY + 16, width: r.width - 8, height: r.height - 19),
                  values: values, color: color, style: t.graph, capacity: 30, glow: 0, lineWidth: 1.2)
    }

    /// 色の点つきの凡例を、カードの下に2〜3列で並べる。使った高さを返す
    @discardableResult
    func legendGrid(_ items: [(full: String, short: String, value: String, color: NSColor?)], _ r: CGRect) -> CGFloat {
        let w = r.width - 24
        let cols = w > 300 ? 3 : 2
        let colGap: CGFloat = 12
        let cw = (w - colGap * CGFloat(cols - 1)) / CGFloat(cols)
        let rowH: CGFloat = 16
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        let h = CGFloat(rows) * rowH
        let top = r.maxY - 10 - h
        // 狭いカードでは単位を詰めて（1.4 GB → 1.4G）名前を残す
        let narrow = cw < 90
        let f = t.font(narrow ? 9.5 : 10)
        for (i, item) in items.enumerated() {
            let x = r.minX + 12 + CGFloat(i % cols) * (cw + colGap)
            let y = top + CGFloat(i / cols) * rowH
            var lx = x
            if let c = item.color {
                ctx.setFillColor(c.cg())
                ctx.fillEllipse(in: CGRect(x: x, y: y + 4.5, width: 6, height: 6))
                lx += 10
            }
            let value = narrow ? item.value.replacingOccurrences(of: " GB", with: "G").replacingOccurrences(of: " MB", with: "M")
                .replacingOccurrences(of: " KB", with: "K") : item.value
            let vw = text(value, x + cw, y, t.font(narrow ? 9.5 : 10, .regular), t.text, align: .right)
            let label = cw > 110 ? item.full : item.short
            if narrow, item.color != nil { lx -= 2 }
            text(label, lx, y, f, t.textDim, maxW: max(x + cw - vw - 4 - lx, 10))
        }
        return h
    }

    // MARK: - CPU

    func drawCoreBars(_ r: CGRect) {
        let cores = store.sampler.coreLoads
        guard !cores.isEmpty, r.height > 2 else { return }
        let gap: CGFloat = 3
        let bw = (r.width - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
        let radius = min(t.corner / 5, 3)
        for (i, v) in cores.enumerated() {
            let x = r.minX + CGFloat(i) * (bw + gap)
            ctx.addPath(rounded(CGRect(x: x, y: r.minY, width: bw, height: r.height), radius))
            ctx.setFillColor(t.cpu.cg(0.14))
            ctx.fillPath()
            let fh = max(1, r.height * CGFloat(v))
            plotBar(track: CGRect(x: x, y: r.minY, width: bw, height: r.height),
                    filled: CGRect(x: x, y: r.maxY - fh, width: bw, height: fh), color: t.cpu.withAlphaComponent(0.9), radius: radius)
        }
    }

    func drawCPU(_ r: CGRect, capacity: Int, detail: WidgetDetail = .standard) {
        let s = store.sampler
        if detail == .compact {
            compactCard(r, "CPU", value: pct(s.cpu), color: t.cpu, bar: s.cpu)
            return
        }
        card(r)
        var cpuSub = "User \(pct(s.cpuUser)) · System \(pct(s.cpuSystem))"
        if detail == .detailed { cpuSub = "\(s.hardware.chip) · " + cpuSub }
        metricHeader(r, "CPU", value: pct(s.cpu), color: t.cpu, sub: cpuSub)
        if detail == .standard {
            let bh: CGFloat = r.height > 150 ? 22 : 16
            let by = r.maxY - bh - 10
            plotGraph(rect: CGRect(x: r.minX + 12, y: r.minY + 42, width: r.width - 24, height: by - 6 - (r.minY + 42)),
                      values: s.cpuS.values, color: t.cpu, style: t.graph, capacity: capacity, glow: t.glow)
            drawCoreBars(CGRect(x: r.minX + 12, y: by, width: r.width - 24, height: bh))
            return
        }
        // Detailed：コアごとのグラフと統計
        let infoY = r.maxY - 27
        let load = s.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
        var info = "Load \(load)  ·  \(s.processes.totalCount) processes  ·  Up \(formatUptime(ProcessInfo.processInfo.systemUptime))"
        if let temp = s.socTemp { info += "  ·  \(Int(temp.rounded()))°C" }
        text(info, r.minX + 12, infoY, t.font(10.5), t.textDim, maxW: r.width - 24)

        let top = r.minY + 42
        let usable = infoY - 6 - top
        let cores = s.coreS
        let cols = DashboardView.coreColumns(cores.count, width: r.width - 24, tray: isPanel)
        let rows = cores.isEmpty ? 0 : Int(ceil(Double(cores.count) / Double(cols)))
        let coreH: CGFloat = 40
        let gridH = CGFloat(rows) * (coreH + 6)
        if usable - gridH >= 30 {
            let graphH = usable - gridH
            plotGraph(rect: CGRect(x: r.minX + 12, y: top, width: r.width - 24, height: graphH - 6),
                      values: s.cpuS.values, color: t.cpu, style: t.graph, capacity: capacity, glow: t.glow)
            let cw = (r.width - 24 - 6 * CGFloat(cols - 1)) / CGFloat(cols)
            for (i, series) in cores.enumerated() {
                let cell = CGRect(x: r.minX + 12 + CGFloat(i % cols) * (cw + 6),
                                  y: top + graphH + CGFloat(i / cols) * (coreH + 6), width: cw, height: coreH)
                drawCoreCell(cell, index: i, series: series, large: false, tiny: cw < 56)
            }
        } else {
            let bh = min(usable * 0.4, 22)
            plotGraph(rect: CGRect(x: r.minX + 12, y: top, width: r.width - 24, height: usable - bh - 6),
                      values: s.cpuS.values, color: t.cpu, style: t.graph, capacity: capacity, glow: t.glow)
            drawCoreBars(CGRect(x: r.minX + 12, y: infoY - 6 - bh, width: r.width - 24, height: bh))
        }
    }

    func drawCoreCell(_ r: CGRect, index: Int, series: Series, large: Bool, tiny: Bool = false) {
        let s = store.sampler
        let path = rounded(r, max(t.corner - 9, 2))
        ctx.addPath(path)
        ctx.setFillColor(t.cpu.cg(0.07))
        ctx.fillPath()
        let labels = s.hardware.coreLabels
        let label = index < labels.count ? labels[index] : "Core \(index + 1)"
        let v = index < s.coreLoads.count ? s.coreLoads[index] : 0
        let f = t.font(large ? 11 : (tiny ? 8.5 : 9.5), .regular)
        let pad: CGFloat = tiny ? 4 : 6
        if r.width < 46 {
            text(pct(v), r.midX, r.minY + 3, f, t.cpu, align: .center)
        } else {
            text(label, r.minX + pad, r.minY + 3, f, t.textDim)
            text(pct(v), r.maxX - pad, r.minY + 3, f, t.cpu, align: .right)
        }
        let top: CGFloat = large ? 21 : 15
        plotGraph(rect: CGRect(x: r.minX + 4, y: r.minY + top, width: r.width - 8, height: r.height - top - 3),
                  values: series.values, color: t.cpu, style: t.graph, capacity: large ? 60 : 30, glow: 0, lineWidth: 1.2)
    }

    // MARK: - メモリ

    func drawMemory(_ r: CGRect, detail: WidgetDetail = .standard) {
        let s = store.sampler
        let frac = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        if detail == .compact {
            compactCard(r, "Memory", value: pct(frac), color: t.memory, bar: frac)
            return
        }
        card(r)
        var sub = String(format: "%.1f / %.0f GB", Double(s.memUsed) / 1_073_741_824, Double(s.memTotal) / 1_073_741_824)
        if s.swapUsed > 0 { sub += " · Swap \(formatBytes(s.swapUsed))" }
        metricHeader(r, "Memory", value: pct(frac), color: t.memory, sub: sub)
        if detail == .standard {
            plotGraph(rect: graphRect(r), values: s.memS.values, color: t.memory, style: t.graph, capacity: 45, glow: t.glow)
            return
        }
        var items: [(full: String, short: String, value: String, color: NSColor?)] = [
            ("App", "App", formatBytes(s.memApp), t.memory), ("Wired", "Wired", formatBytes(s.memWired), t.gpu),
            ("Compressed", "Comp.", formatBytes(s.memCompressed), t.disk), ("Cached", "Cache", formatBytes(s.memCached), t.network),
            ("Free", "Free", formatBytes(s.memFree), nil)]
        if let free = s.memPressureFree { items.append(("Pressure", "Press.", "\(100 - free)%", nil)) }
        let legendH = legendGrid(items, r)
        plotGraph(rect: CGRect(x: r.minX + 12, y: r.minY + 44, width: r.width - 24, height: r.maxY - 10 - legendH - 8 - (r.minY + 44)),
                  values: s.memS.values, color: t.memory, style: t.graph, capacity: 45, glow: t.glow)
    }

    // MARK: - GPU

    func drawGPU(_ r: CGRect, detail: WidgetDetail = .standard) {
        let s = store.sampler
        if detail == .compact {
            compactCard(r, "GPU", value: s.gpu.map(pct) ?? "—", color: t.gpu, bar: s.gpu ?? 0)
            return
        }
        card(r)
        // Standard は使用中のメモリ、Detailed はチップ名（メモリは下の行に出る）
        var gpuSub = s.gpuName ?? "Graphics"
        if detail == .standard, let m = s.gpuMemory { gpuSub = "\(formatBytes(m)) memory in use" }
        if s.gpu == nil { gpuSub = "Unavailable" }
        metricHeader(r, "GPU", value: s.gpu.map(pct) ?? "—", color: t.gpu, sub: gpuSub)
        if detail == .standard {
            plotGraph(rect: graphRect(r), values: s.gpuS.values, color: t.gpu, style: t.graph, capacity: 45, glow: t.glow)
            return
        }
        // 下から：使用中のメモリとコア数 → Renderer / Tiler の小さいグラフ → 全体のグラフ
        var bottom = r.maxY - 10
        var info: [String] = []
        if let v = s.gpuMemory { info.append("\(formatBytes(v)) in use") }
        if let v = s.gpuCores { info.append("\(v) cores") }
        if !info.isEmpty {
            text(info.joined(separator: " · "), r.minX + 12, bottom - 14, t.font(10), t.textDim, maxW: r.width - 24)
            bottom -= 20
        }
        let cellH: CGFloat = 40, gap: CGFloat = 6
        let cw = (r.width - 24 - gap) / 2
        let cellY = bottom - cellH
        miniGraphCell(CGRect(x: r.minX + 12, y: cellY, width: cw, height: cellH), "Renderer", s.gpuRenderer, s.gpuRenS.values, t.gpu, short: "Render")
        miniGraphCell(CGRect(x: r.minX + 12 + cw + gap, y: cellY, width: cw, height: cellH), "Tiler", s.gpuTiler, s.gpuTilS.values, t.accent)
        plotGraph(rect: CGRect(x: r.minX + 12, y: r.minY + 44, width: r.width - 24, height: cellY - 6 - (r.minY + 44)),
                  values: s.gpuS.values, color: t.gpu, style: t.graph, capacity: 45, glow: t.glow)
    }

    // MARK: - 通信

    func drawNetwork(_ r: CGRect, detail: WidgetDetail = .standard) {
        let s = store.sampler
        if detail == .compact {
            card(r)
            text("Network", r.minX + 12, r.minY + 9, t.font(11, .regular), t.textDim)
            let size = max(12, min(r.height * 0.18, r.width * 0.09, 18))
            let mid = r.minY + 24 + (r.height - 24) / 2
            text("↓ \(formatRate(s.netDown))", r.minX + 12, mid - size * 1.35, t.font(size, .regular), t.network, maxW: r.width - 24)
            text("↑ \(formatRate(s.netUp))", r.minX + 12, mid + size * 0.05, t.font(size, .regular), t.disk, maxW: r.width - 24)
            return
        }
        card(r)
        text("Network", r.minX + 12, r.minY + 9, t.font(11, .regular), t.textDim)
        text("↓ \(formatRate(s.netDown))", r.maxX - 12, r.minY + 8, t.font(10.5, .regular), t.network, align: .right)
        text("↑ \(formatRate(s.netUp))", r.maxX - 12, r.minY + 24, t.font(10.5, .regular), t.disk, align: .right)
        var top: CGFloat = 46
        if detail == .detailed {
            var y = r.minY + 46
            let limit = r.maxY - 6
            for i in s.interfaces.prefix(3) {
                y = kvRow(i.display, i.ipv4 ?? "No address", x: r.minX + 12, y: y, w: r.width - 24, limit: limit)
            }
            y = kvRow("Session down", formatBytes(s.sessionDown), x: r.minX + 12, y: y, w: r.width - 24, limit: limit, color: t.network)
            y = kvRow("Session up", formatBytes(s.sessionUp), x: r.minX + 12, y: y, w: r.width - 24, limit: limit, color: t.disk)
            top = y - r.minY + 4
        }
        let scale = max(s.downS.values.max() ?? 0, s.upS.values.max() ?? 0, 256 * 1024)
        let g = graphRect(r, top: top)
        plotGraph(rect: g, values: s.downS.values.map { $0 / scale }, color: t.network, style: t.graph == .bars ? .area : t.graph, capacity: 45, glow: t.glow)
        if t.graph != .pixel {
            plotGraph(rect: g, values: s.upS.values.map { $0 / scale }, color: t.disk, style: .line, capacity: 45, glow: t.glow, lineWidth: 1, fillable: false)
        }
    }

    // MARK: - ディスク

    func drawDisk(_ r: CGRect, detail: WidgetDetail = .standard) {
        let s = store.sampler
        let used = s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0
        let freeText = "\(formatBytes(UInt64(max(s.diskFree, 0)))) free"
        let barColor = used > 0.92 ? t.danger : t.disk
        if detail == .compact {
            compactCard(r, "Disk", value: formatBytes(UInt64(max(s.diskFree, 0))), color: t.disk, bar: used, sub: "free")
            return
        }
        card(r)
        text("Disk", r.minX + 12, r.minY + 9, t.font(11, .regular), t.textDim)
        text(freeText, r.maxX - 12, r.minY + 8, t.font(11.5, .regular), t.disk, align: .right)
        var y = diskUsage(r, used: used, color: barColor)
        let limit = r.maxY - 6
        y = kvRow("Read", formatRate(s.diskRead), x: r.minX + 12, y: y, w: r.width - 24, limit: limit)
        y = kvRow("Write", formatRate(s.diskWrite), x: r.minX + 12, y: y, w: r.width - 24, limit: limit)
        if detail == .detailed {
            y = kvRow("Reads", String(format: "%.0f /s", s.readOps), x: r.minX + 12, y: y, w: r.width - 24, limit: limit)
            y = kvRow("Writes", String(format: "%.0f /s", s.writeOps), x: r.minX + 12, y: y, w: r.width - 24, limit: limit)
            for v in s.volumes.prefix(3) {
                y = kvRow(v.name, "\(formatBytes(UInt64(max(v.free, 0)))) free", x: r.minX + 12, y: y, w: r.width - 24, limit: limit)
            }
        }
        let scale = max(s.diskS.values.max() ?? 0, 1_048_576)
        plotGraph(rect: CGRect(x: r.minX + 12, y: y + 4, width: r.width - 24, height: r.maxY - y - 14),
                  values: s.diskS.values.map { $0 / scale }, color: t.disk, style: t.graph, capacity: 45, glow: t.glow)
    }

    /// ディスクの使用量：細い線と目盛り。戻り値はその下の行を始める位置
    func diskUsage(_ r: CGRect, used: Double, color: NSColor) -> CGFloat {
        let x = r.minX + 12, w = r.width - 24
        let u = CGFloat(min(max(used, 0), 1))
        let track = CGRect(x: x, y: r.minY + 35, width: w, height: 3)
        ctx.addPath(rounded(track, 1.5))
        ctx.setFillColor(color.cg(0.16))
        ctx.fillPath()
        ctx.addPath(rounded(CGRect(x: x, y: track.minY, width: max(w * u, 3), height: 3), 1.5))
        ctx.setFillColor(color.cg())
        ctx.fillPath()
        ctx.setFillColor(t.textDim.cg(0.35))
        for i in 1..<4 { ctx.fill(CGRect(x: x + w * CGFloat(i) / 4 - 0.5, y: track.maxY + 2, width: 1, height: 3)) }
        return r.minY + 47
    }

    // MARK: - 電源と熱

    func thermalLabel(_ s: ProcessInfo.ThermalState) -> (String, NSColor) {
        switch s {
        case .nominal: return ("Normal", t.network)
        case .fair: return ("Warm", t.disk)
        case .serious: return ("Hot", t.danger)
        case .critical: return ("Critical", t.danger)
        @unknown default: return ("—", t.textDim)
        }
    }

    func batteryTimeText(_ b: BatteryInfo) -> String? {
        guard let m = b.minutesLeft else { return nil }
        let time = "\(m / 60):" + String(format: "%02d", m % 60)
        return b.charging ? "Full in \(time)" : "\(time) left"
    }

    func batteryStateText(_ b: BatteryInfo, withTime: Bool = true) -> String {
        var state = b.charging ? "Charging" : (b.onAC ? "Plugged in" : "On battery")
        if b.charging, let w = b.chargeWatts, w >= 0.1 { state += String(format: " %.1f W", w) }
        if withTime, let time = batteryTimeText(b) { state += " · " + (b.charging ? time.lowercased() : time) }
        return state
    }

    func drawBatteryIcon(x: CGFloat, y: CGFloat, _ b: BatteryInfo) {
        let body = CGRect(x: x, y: y + 0.5, width: 22, height: 11)
        ctx.addPath(rounded(body, 2.8))
        ctx.setStrokeColor(t.text.cg(0.75))
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.setFillColor(t.text.cg(0.75))
        ctx.fill(CGRect(x: body.maxX + 1, y: body.midY - 2.5, width: 1.5, height: 5))
        let color = b.percent < 0.2 && !b.charging ? t.danger : t.battery
        ctx.addPath(rounded(CGRect(x: body.minX + 1.5, y: body.minY + 1.5, width: (body.width - 3) * CGFloat(b.percent), height: body.height - 3), 1.5))
        ctx.setFillColor(color.cg())
        ctx.fillPath()
    }

    func fanSummary(_ fans: [FanInfo]) -> String {
        // 1行に収めるため、いちばん速く回っているファンだけ出す（全部は Detailed で）
        return "Fan " + formatRPM(fans.map { $0.rpm }.max() ?? 0)
    }

    func drawPower(_ r: CGRect, detail: WidgetDetail = .standard) {
        let s = store.sampler
        let (label, color) = thermalLabel(s.thermal)
        let temp = s.socTemp ?? s.battery?.temperature
        let tempText = temp.map { "\(Int($0.rounded()))°C" } ?? "—"
        if detail == .compact {
            if let b = s.battery {
                compactCard(r, "Power", value: pct(b.percent), color: t.battery, bar: b.percent, sub: "\(tempText) · \(label)")
            } else {
                compactCard(r, "Thermal", value: tempText, color: color, bar: nil, sub: label)
            }
            return
        }
        card(r)
        let ix = r.minX + 12, iy = r.minY + 11
        if let b = s.battery {
            drawBatteryIcon(x: ix, y: iy, b)
            text("\(pct(b.percent))  \(batteryStateText(b, withTime: false))", ix + 31, iy - 2, t.font(12, .regular), t.text, maxW: r.width - 124)
            var parts: [String] = []
            if let time = batteryTimeText(b) { parts.append(time) }
            // 電池の状態（容量・充放電回数）は Detailed のときだけ
            if detail == .detailed {
                if let h = b.health { parts.append("Capacity \(pct(h))") }
                if let c = b.cycles { parts.append("\(c) cycles") }
            }
            // Mac 全体の電力が取れない時は、電池の電力だとわかるように書く
            switch PowerReading.from(systemWatts: b.systemWatts, batteryWatts: b.watts) {
            case .system(let w) where w >= 0.5: parts.append(String(format: "%.1f W", w))
            case .battery(let w) where w >= 0.5: parts.append(String(format: "Battery %.1f W", w))
            default: break
            }
            if !s.fans.isEmpty { parts.append(fanSummary(s.fans)) }
            text(parts.joined(separator: " · "), ix, iy + 21, t.font(10), t.textDim, maxW: r.width - 84)
        } else {
            text("Running on AC power", ix, iy + 4, t.font(12, .regular), t.text)
            if !s.fans.isEmpty { text(fanSummary(s.fans), ix, iy + 24, t.font(10), t.textDim, maxW: r.width - 84) }
        }
        let tray = isPanel
        text(tempText, r.maxX - 12, r.minY + (tray ? 9 : 7), t.font(tray ? 13 : 17, DashboardView.valueWeight), color, align: .right, glow: true)
        text(label, r.maxX - 12, r.minY + 32, t.font(10), t.textDim, align: .right)
        guard detail == .detailed else { return }
        var y = r.minY + 54
        let limit = r.maxY - 6
        let x = r.minX + 12, w = r.width - 24
        if let b = s.battery {
            if let v = b.voltage { y = kvRow("Voltage", String(format: "%.2f V", v), x: x, y: y, w: w, limit: limit) }
            if let a = b.amperage { y = kvRow("Current", String(format: "%.2f A", a), x: x, y: y, w: w, limit: limit) }
            if let c = b.temperature { y = kvRow("Battery", String(format: "%.1f°C", c), x: x, y: y, w: w, limit: limit) }
            if let c = b.chargeWatts, b.charging { y = kvRow("Charging", String(format: "%.1f W", c), x: x, y: y, w: w, limit: limit) }
            if let i = b.inputWatts { y = kvRow("Power in", String(format: "%.1f W", i), x: x, y: y, w: w, limit: limit) }
            if let a = b.adapterWatts { y = kvRow("Adapter", "\(a) W", x: x, y: y, w: w, limit: limit) }
        }
        for f in s.fans {
            y = kvRow(f.name, formatRPM(f.rpm), x: x, y: y, w: w, limit: limit)
        }
        for sensor in s.sensors.prefix(4) {
            y = kvRow(sensor.name, String(format: "%.0f°C", sensor.value), x: x, y: y, w: w, limit: limit)
        }
    }

    // MARK: - 重いプロセス

    func drawTopApps(_ r: CGRect, detail: WidgetDetail = .standard) {
        card(r)
        text("Top processes", r.minX + 12, r.minY + 8, t.font(11, .regular), t.textDim)
        let headFont = t.font(10, .regular)
        if detail == .compact {
            text("CPU", r.maxX - 12, r.minY + 9, headFont, t.textDim, align: .right)
        } else {
            text("CPU", r.maxX - 72, r.minY + 9, headFont, t.textDim, align: .right)
            text("Memory", r.maxX - 12, r.minY + 9, headFont, t.textDim, align: .right)
        }
        let rowH: CGFloat = detail == .detailed ? 28 : 22
        let count = max(1, Int((r.height - 30) / rowH))
        let rows = store.sampler.processes.list(grouped: store.groupApps, sort: .cpu).prefix(count)
        var y = r.minY + 28
        let maxCPU = max(rows.first?.cpu ?? 1, 1)
        for row in rows {
            drawIcon(row, x: r.minX + 12, y: y + 1, size: 15)
            var name = row.name
            if detail == .detailed && row.pids.count > 1 { name += " (\(row.pids.count))" }
            let rightW: CGFloat = detail == .compact ? 58 : 108
            text(name, r.minX + 32, y, t.font(11.5), t.text, maxW: max(r.width - 44 - rightW, 20))
            if detail == .compact {
                text("\(Int(row.cpu.rounded()))%", r.maxX - 12, y, t.font(11.5, .regular), t.cpu, align: .right)
            } else {
                text("\(Int(row.cpu.rounded()))%", r.maxX - 72, y, t.font(11.5, .regular), t.cpu, align: .right)
                text(formatBytes(row.mem), r.maxX - 12, y, t.font(10.5), t.textDim, align: .right)
            }
            if detail == .detailed {
                levelBar(CGRect(x: r.minX + 32, y: y + 19, width: r.width - 44, height: 3), row.cpu / maxCPU, t.cpu)
            }
            y += rowH
        }
    }
}
