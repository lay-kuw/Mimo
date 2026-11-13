import Foundation
import IOKit
import IOKit.ps
import Darwin
import SystemConfiguration

/// 値と、それを計測した時刻（CFAbsoluteTime）を一緒に持つ履歴
struct Series {
    private(set) var values: [Double] = []
    private(set) var times: [Double] = []
    let cap: Int
    init(cap: Int = 120) { self.cap = cap }
    mutating func push(_ v: Double, at t: Double = CFAbsoluteTimeGetCurrent()) {
        values.append(v)
        times.append(t)
        if values.count > cap {
            values.removeFirst(values.count - cap)
            times.removeFirst(times.count - cap)
        }
    }
    func last(_ n: Int) -> [Double] { Array(values.suffix(n)) }
}

struct BatteryInfo {
    var percent: Double = 0
    var charging = false
    var onAC = false
    var minutesLeft: Int? = nil
    var cycles: Int? = nil
    var health: Double? = nil
    var temperature: Double? = nil
    var watts: Double? = nil
    var voltage: Double? = nil
    var amperage: Double? = nil
    var designCapacity: Int? = nil
    var maxCapacity: Int? = nil
    var currentCapacity: Int? = nil
    var adapterWatts: Int? = nil
    var systemWatts: Double? = nil
    /// 充電中にバッテリーへ入っている電力
    var chargeWatts: Double? = nil
    /// 電源アダプタから Mac に入っている電力
    var inputWatts: Double? = nil
}

struct InterfaceInfo {
    var name: String
    var display: String
    var ipv4: String?
    var down: Double
    var up: Double
    var received: UInt64
    var sent: UInt64
}

struct VolumeInfo {
    var name: String
    var total: Int64
    var free: Int64
    var format: String
}

struct HardwareInfo {
    var chip: String
    var model: String
    var os: String
    var coreLabels: [String]
    var performanceCores: Int
    var efficiencyCores: Int
}

private func ioProp<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
}

/// 計測はすべて公開APIの軽いカウンタ読み取り。温度のみ dlsym 経由で任意に使う。
final class Sampler {
    // CPU
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var coreLoads: [Double] = []
    // メモリ
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    // GPU
    var gpu: Double? = nil
    // ネットワーク
    var netDown: Double = 0
    var netUp: Double = 0
    // ディスク
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    // 電源・熱
    var battery: BatteryInfo? = nil
    var socTemp: Double? = nil
    var thermal: ProcessInfo.ThermalState = .nominal

    var cpuS = Series(), memS = Series(), gpuS = Series()
    var downS = Series(), upS = Series(), diskS = Series()

    // Performance 画面の詳細
    var coreS: [Series] = []
    var loadAverage: [Double] = [0, 0, 0]
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var memFree: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pageIns: Double = 0
    var pageOuts: Double = 0
    var memPressureFree: Int? = nil
    var gpuRenderer: Double? = nil
    var gpuTiler: Double? = nil
    var gpuMemory: UInt64? = nil
    var gpuName: String? = nil
    var gpuCores: Int? = nil
    var gpuRenS = Series(), gpuTilS = Series()
    var readS = Series(), writeS = Series()
    var readOps: Double = 0
    var writeOps: Double = 0
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
    var volumes: [VolumeInfo] = []
    var interfaces: [InterfaceInfo] = []
    var peakDown: Double = 0
    var peakUp: Double = 0
    var sessionDown: UInt64 = 0
    var sessionUp: UInt64 = 0
    /// 温度（10秒ごと）と電力（5〜30秒ごと）は間隔が違うので、時刻つきで長めに持って時間軸で描く
    var tempS = Series(cap: 240)
    /// Mac 全体の消費電力。取れない機種では空のまま
    var powerS = Series(cap: 400)
    /// 電池の出入り（電圧×電流）。全体の電力とは別物なので別の履歴にする
    var batteryPowerS = Series(cap: 400)
    var sensors: [(name: String, value: Double)] = []
    // ファン（ファンのない Mac では空のまま）
    var fans: [FanInfo] = []
    var fanS: [Series] = []
    /// 確認用スナップショットで、ファンのない Mac でも表示を確かめるための見本
    static var demoFans = false
    private lazy var fanReader = FanReader()
    private var demoPhase = 0.0
    lazy var hardware: HardwareInfo = Sampler.readHardware()
    /// Performance 画面が見えている間だけ電源情報の更新を早める（App が画面の表示状態から決める）
    var wantsDetail = false
    /// 確認用（--snapshot / --bench / --selftest）では、遅い計測もその場で済ませる
    var inlineSlowWork = false
    private let slowQueue = DispatchQueue(label: "mimo.sampler.slow", qos: .utility)
    private var ifaceTotals: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var ifaceNames: [String: String]? = nil
    private var prevPages: (i: UInt64, o: UInt64)? = nil

    let processes = ProcessSampler()

    private let host = mach_host_self()
    private var prevCPU: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []
    private var prevNet: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var prevDisks: [UInt64: DiskCounters] = [:]
    private var lastFast = CFAbsoluteTimeGetCurrent()
    private var lastProc: CFAbsoluteTime = 0
    private var lastSlow: CFAbsoluteTime = 0
    private var lastTemp: CFAbsoluteTime = 0
    private var lastBattery: CFAbsoluteTime = 0
    /// 温度センサは slowQueue の上だけで使う
    private let thermalReader = ThermalReader()

    /// 遅いかもしれない読み取りを裏で行い、結果だけをメインスレッドで反映する
    private func runSlow(_ work: @escaping () -> (() -> Void)) {
        if inlineSlowWork {
            work()()
            return
        }
        slowQueue.async {
            let apply = work()
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// processInterval が nil なら、プロセス一覧は見ている画面がないので読まない
    func tick(processInterval: Double?) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(now - lastFast, 0.05)
        lastFast = now
        sampleCPU()
        sampleMemory(dt: dt)
        sampleGPU()
        sampleNetwork(dt: dt)
        sampleDiskIO(dt: dt)
        sampleFans()
        cpuS.push(cpu)
        memS.push(memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0)
        gpuS.push(gpu ?? 0)
        downS.push(netDown)
        upS.push(netUp)
        diskS.push(diskRead + diskWrite)
        readS.push(diskRead)
        writeS.push(diskWrite)
        gpuRenS.push(gpuRenderer ?? 0)
        gpuTilS.push(gpuTiler ?? 0)
        peakDown = max(peakDown, netDown)
        peakUp = max(peakUp, netUp)
        var avg = [0.0, 0.0, 0.0]
        if getloadavg(&avg, 3) == 3 { loadAverage = avg }

        if let processInterval, now - lastProc >= processInterval {
            lastProc = now
            processes.sample()
        }
        if now - lastTemp >= 10 {
            lastTemp = now
            thermal = ProcessInfo.processInfo.thermalState
            let reader = thermalReader
            runSlow { [weak self] in
                let value = reader.read()
                let found = reader.sensors
                let at = CFAbsoluteTimeGetCurrent()
                return {
                    guard let self else { return }
                    self.socTemp = value
                    self.sensors = found
                    if let v = value { self.tempS.push(v, at: at) }
                }
            }
        }
        if now - lastSlow >= 30 {
            lastSlow = now
            runSlow { [weak self] in
                let space = Sampler.readDiskSpace()
                let vols = Sampler.readVolumes()
                return {
                    guard let self else { return }
                    if let space { self.diskTotal = space.total; self.diskFree = space.free }
                    self.volumes = vols
                }
            }
        }
        if now - lastBattery >= (wantsDetail ? 5 : 30) {
            lastBattery = now
            sampleBattery()
            recordPower()
        }
    }

    /// 全体の電力と電池の電力を、それぞれの履歴に分けて記録する
    private func recordPower() {
        if let w = battery?.systemWatts { powerS.push(w) }
        if let w = battery?.watts { batteryPowerS.push(w) }
    }

    private func sampleFans() {
        if Sampler.demoFans {
            demoPhase += 0.35
            fans = [FanInfo(name: "Fan 1", rpm: 2400 + 900 * sin(demoPhase), min: 1200, max: 5800),
                    FanInfo(name: "Fan 2", rpm: 2600 + 800 * sin(demoPhase + 0.8), min: 1200, max: 6200)]
        } else if fanReader.available {
            fans = fanReader.read()
        } else {
            if !fans.isEmpty { fans = [] }
        }
        if fanS.count != fans.count { fanS = fans.map { _ in Series() } }
        for (i, f) in fans.enumerated() { fanS[i].push(f.max > 0 ? min(f.rpm / f.max, 1) : 0) }
    }

    /// 計測項目ごとの所要時間を測るための入口（--bench 専用）
    func benchParts() -> [(String, () -> Void)] {
        [("cpu", { self.sampleCPU() }),
         ("memory", { self.sampleMemory(dt: 1) }),
         ("gpu", { self.sampleGPU() }),
         ("network", { self.sampleNetwork(dt: 1) }),
         ("diskIO", { self.sampleDiskIO(dt: 1) }),
         ("processes", { self.processes.sample() }),
         ("procList", { _ = self.processes.list(grouped: true, sort: .cpu) }),
         ("thermal", { _ = self.thermalReader.read() }),
         ("battery", { self.sampleBattery() }),
         ("diskSpace", { _ = Sampler.readDiskSpace() }),
         ("volumes", { _ = Sampler.readVolumes() })]
    }

    private func sampleCPU() {
        var numCPU: natural_t = 0
        var info: processor_info_array_t? = nil
        var numInfo: mach_msg_type_number_t = 0
        let r = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &numInfo)
        guard r == KERN_SUCCESS, let arr = info else { return }
        defer {
            _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: arr),
                              vm_size_t(numInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let n = Int(numCPU)
        let st = Int(CPU_STATE_MAX)
        var cur: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []
        cur.reserveCapacity(n)
        for i in 0..<n {
            let o = i * st
            cur.append((user: UInt32(bitPattern: arr[o + Int(CPU_STATE_USER)]),
                        sys: UInt32(bitPattern: arr[o + Int(CPU_STATE_SYSTEM)]),
                        idle: UInt32(bitPattern: arr[o + Int(CPU_STATE_IDLE)]),
                        nice: UInt32(bitPattern: arr[o + Int(CPU_STATE_NICE)])))
        }
        if prevCPU.count == n {
            var loads = [Double](repeating: 0, count: n)
            var tu = 0.0, ts = 0.0, tt = 0.0
            for i in 0..<n {
                let u = Double(cur[i].user &- prevCPU[i].user) + Double(cur[i].nice &- prevCPU[i].nice)
                let s = Double(cur[i].sys &- prevCPU[i].sys)
                let d = Double(cur[i].idle &- prevCPU[i].idle)
                let t = u + s + d
                loads[i] = t > 0 ? (u + s) / t : 0
                tu += u; ts += s; tt += t
            }
            coreLoads = loads
            if coreS.count != n { coreS = (0..<n).map { _ in Series(cap: 60) } }
            for i in 0..<n { coreS[i].push(loads[i]) }
            cpuUser = tt > 0 ? tu / tt : 0
            cpuSystem = tt > 0 ? ts / tt : 0
            cpu = cpuUser + cpuSystem
        }
        prevCPU = cur
    }

    private func sampleMemory(dt: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
                host_statistics64(host, HOST_VM_INFO64, q, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            // アクティビティモニタの「使用済みメモリ」と同じ考え方
            let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
            memUsed = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            memApp = app * page
            memWired = UInt64(stats.wire_count) * page
            memCompressed = UInt64(stats.compressor_page_count) * page
            memCached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
            memFree = UInt64(stats.free_count) * page
            if let prev = prevPages, stats.pageins >= prev.i, stats.pageouts >= prev.o {
                pageIns = Double((stats.pageins - prev.i) * page) / dt
                pageOuts = Double((stats.pageouts - prev.o) * page) / dt
            }
            prevPages = (i: stats.pageins, o: stats.pageouts)
        }
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            swapUsed = xsw.xsu_used
            swapTotal = xsw.xsu_total
        }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &levelSize, nil, 0) == 0 { memPressureFree = Int(level) }
    }

    private func sampleGPU() {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var best: Double? = nil
        var e = IOIteratorNext(iter)
        while e != 0 {
            if let d: [String: Any] = ioProp(e, "PerformanceStatistics"),
               let u = d["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(u) / 100)
                gpuRenderer = (d["Renderer Utilization %"] as? Int).map { Double($0) / 100 }
                gpuTiler = (d["Tiler Utilization %"] as? Int).map { Double($0) / 100 }
                gpuMemory = (d["In use system memory"] as? Int).map { UInt64(max($0, 0)) }
                if gpuName == nil {
                    gpuName = ioProp(e, "model")
                    gpuCores = ioProp(e, "gpu-core-count")
                }
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        gpu = best
    }

    /// インターフェースごとの64bitの通信量カウンタ（getifaddrs の if_data は32bitで、速い回線だと桁あふれする）
    static func readInterfaceCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (rx: UInt64, tx: UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = base.advanced(by: off).assumingMemoryBound(to: if_msghdr.self).pointee
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if hdr.ifm_type == UInt8(RTM_IFINFO2), off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = base.advanced(by: off).assumingMemoryBound(to: if_msghdr2.self).pointee
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                        out[String(cString: nameBuf)] = (rx: m.ifm_data.ifi_ibytes, tx: m.ifm_data.ifi_obytes)
                    }
                }
                off += msgLen
            }
        }
        return out
    }

    private func sampleNetwork(dt: Double) {
        var addrs: UnsafeMutablePointer<ifaddrs>? = nil
        var ips: [String: String] = [:]
        if getifaddrs(&addrs) == 0 {
            var p = addrs
            while let a = p {
                p = a.pointee.ifa_next
                guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                let name = String(cString: a.pointee.ifa_name)
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if let c = inet_ntoa(addr) { ips[name] = String(cString: c) }
            }
            freeifaddrs(addrs)
        }
        var down = 0.0, up = 0.0
        var seen: [String: (rx: UInt64, tx: UInt64)] = [:]
        var rates: [String: (d: Double, u: Double)] = [:]
        for (name, c) in Sampler.readInterfaceCounters() where name.hasPrefix("en") { // VPN等の二重計上を避ける
            seen[name] = c
            // 初回や作り直された直後は基準を取るだけ。値が減ったらリセットとみなして 0
            let dr = counterDelta(previous: prevNet[name]?.rx, current: c.rx)
            let ur = counterDelta(previous: prevNet[name]?.tx, current: c.tx)
            down += Double(dr)
            up += Double(ur)
            rates[name] = (d: Double(dr) / dt, u: Double(ur) / dt)
            var totals = ifaceTotals[name] ?? (rx: 0, tx: 0)
            totals.rx += dr
            totals.tx += ur
            ifaceTotals[name] = totals
            sessionDown += dr
            sessionUp += ur
        }
        prevNet = seen
        if ifaceNames == nil { ifaceNames = Sampler.readInterfaceNames() }
        interfaces = seen.keys.sorted().compactMap { name in
            let totals = ifaceTotals[name] ?? (rx: 0, tx: 0)
            guard ips[name] != nil || totals.rx + totals.tx > 0 else { return nil }
            let r = rates[name] ?? (d: 0, u: 0)
            return InterfaceInfo(name: name, display: ifaceNames?[name] ?? name, ipv4: ips[name],
                                 down: r.d, up: r.u, received: totals.rx, sent: totals.tx)
        }
        netDown = down / dt
        netUp = up / dt
    }

    private static func number(_ s: [String: Any], _ key: String) -> UInt64 {
        (s[key] as? UInt64) ?? UInt64(max((s[key] as? Int) ?? 0, 0))
    }

    /// ディスクごとの累積値。キーは IORegistry の ID（接続し直すと別の ID になる）
    static func readDiskCounters() -> [UInt64: DiskCounters] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iter) }
        var out: [UInt64: DiskCounters] = [:]
        var e = IOIteratorNext(iter)
        while e != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(e, &id) == KERN_SUCCESS, let s: [String: Any] = ioProp(e, "Statistics") {
                out[id] = DiskCounters(readBytes: number(s, "Bytes (Read)"), writeBytes: number(s, "Bytes (Write)"),
                                       readOps: number(s, "Operations (Read)"), writeOps: number(s, "Operations (Write)"))
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        return out
    }

    private func sampleDiskIO(dt: Double) {
        let cur = Sampler.readDiskCounters()
        // ディスクごとに差分を取ってから合計する（抜き差しで過去の累積が混ざらない）
        let d = diskDeltas(previous: prevDisks, current: cur)
        prevDisks = cur
        diskRead = Double(d.readBytes) / dt
        diskWrite = Double(d.writeBytes) / dt
        readOps = Double(d.readOps) / dt
        writeOps = Double(d.writeOps) / dt
        totalRead = cur.values.reduce(0) { $0 + $1.readBytes }
        totalWritten = cur.values.reduce(0) { $0 + $1.writeBytes }
    }

    static func readDiskSpace() -> (total: Int64, free: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return nil }
        return (Int64(v.volumeTotalCapacity ?? 0), v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func readVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            return VolumeInfo(name: v.volumeLocalizedName ?? u.lastPathComponent, total: Int64(total),
                              free: v.volumeAvailableCapacityForImportantUsage ?? 0,
                              format: v.volumeLocalizedFormatDescription ?? "")
        }
    }

    private static func readInterfaceNames() -> [String: String] {
        var out: [String: String] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return out }
        for i in all {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                out[bsd] = name
            }
        }
        return out
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ key: String) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(key, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }

    private static func readHardware() -> HardwareInfo {
        let total = ProcessInfo.processInfo.activeProcessorCount
        var kinds = [String](repeating: "", count: total)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iter) == KERN_SUCCESS {
                defer { IOObjectRelease(iter) }
                var fallback = 0
                var e = IOIteratorNext(iter)
                while e != 0 {
                    var id = fallback
                    if let d: Data = ioProp(e, "logical-cpu-id"), d.count >= 4 {
                        id = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                    }
                    if let d: Data = ioProp(e, "cluster-type"), let b = d.first, id < total, id >= 0 {
                        kinds[id] = String(UnicodeScalar(b))
                    }
                    fallback += 1
                    IOObjectRelease(e)
                    e = IOIteratorNext(iter)
                }
            }
        }
        var counts: [String: Int] = [:]
        var labels: [String] = []
        for (i, k) in kinds.enumerated() {
            if k.isEmpty {
                labels.append("Core \(i + 1)")
            } else {
                counts[k, default: 0] += 1
                labels.append("\(k)\(counts[k]!)")
            }
        }
        return HardwareInfo(chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown chip",
                            model: sysctlString("hw.model") ?? "Mac",
                            os: ProcessInfo.processInfo.operatingSystemVersionString,
                            coreLabels: labels,
                            performanceCores: counts["P"] ?? sysctlInt("hw.perflevel0.logicalcpu"),
                            efficiencyCores: counts["E"] ?? sysctlInt("hw.perflevel1.logicalcpu"))
    }

    // 電源の抜き差しや充電の開始・終了を macOS から知らせてもらう（定期の読み取りを待たない）
    private static var powerChanged: (() -> Void)?
    private var powerSource: CFRunLoopSource?

    func watchPowerSource(onChange: @escaping () -> Void) {
        Sampler.powerChanged = { [weak self] in
            guard let self else { return }
            self.refreshBattery()
            onChange()
            // 電池の計測値（電流や W 数）は電源を切り替えてから数秒〜十数秒遅れて更新されるので、
            // しばらくは1秒おきに読み直して、W 数が出たらすぐ表示する
            self.burstUntil = CFAbsoluteTimeGetCurrent() + 25
            self.burst(onChange)
        }
        guard powerSource == nil,
              let src = IOPSNotificationCreateRunLoopSource({ _ in Sampler.powerChanged?() }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        powerSource = src
    }

    private var burstUntil: CFAbsoluteTime = 0

    private func burst(_ onChange: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, CFAbsoluteTimeGetCurrent() < self.burstUntil else { return }
            let before = self.battery
            self.refreshBattery()
            let b = self.battery
            if b?.charging != before?.charging || b?.chargeWatts != before?.chargeWatts || b?.onAC != before?.onAC { onChange() }
            // 充電の W 数が出たら終わり。電池駆動に切り替わった時は時間いっぱい見る
            if let b, b.onAC, b.chargeWatts != nil || !b.charging, b.inputWatts != nil { self.burstUntil = 0; return }
            self.burst(onChange)
        }
    }

    private func refreshBattery() {
        lastBattery = CFAbsoluteTimeGetCurrent()
        sampleBattery()
        recordPower()
    }

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let ps = list.first,
              let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cur = d["Current Capacity"] as? Int,
              let maxC = d["Max Capacity"] as? Int, maxC > 0 else { battery = nil; return }
        var b = BatteryInfo()
        b.percent = Double(cur) / Double(maxC)
        b.charging = (d["Is Charging"] as? Bool) ?? false
        b.onAC = (d["Power Source State"] as? String) == "AC Power"
        let mins = (b.charging ? d["Time to Full Charge"] : d["Time to Empty"]) as? Int
        if let m = mins, m > 0 { b.minutesLeft = m }
        let e = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if e != 0 {
            defer { IOObjectRelease(e) }
            b.cycles = ioProp(e, "CycleCount")
            // 機種によって項目が BatteryData の中にある
            let data: [String: Any] = ioProp(e, "BatteryData") ?? [:]
            var raw: Int? = ioProp(e, "AppleRawMaxCapacity")
            if raw == nil { raw = data["AppleRawMaxCapacity"] as? Int }
            if raw == nil { raw = ioProp(e, "NominalChargeCapacity") }
            var design: Int? = ioProp(e, "DesignCapacity")
            if design == nil { design = data["DesignCapacity"] as? Int }
            var current: Int? = ioProp(e, "AppleRawCurrentCapacity")
            if current == nil { current = data["AppleRawCurrentCapacity"] as? Int }
            b.maxCapacity = raw
            b.designCapacity = design
            b.currentCapacity = current
            if let raw, let design, design > 0, raw > 100 { b.health = min(Double(raw) / Double(design), 1) }
            let telemetry: [String: Any] = ioProp(e, "PowerTelemetryData") ?? [:]
            if let mw = telemetry["SystemLoad"] as? Int, mw > 0 { b.systemWatts = Double(mw) / 1000 }
            if let mw = telemetry["SystemPowerIn"] as? Int, mw > 0 { b.inputWatts = Double(mw) / 1000 }
            if b.charging, let mw = telemetry["BatteryPower"] as? Int, mw > 0 { b.chargeWatts = Double(mw) / 1000 }
            if let t: Int = ioProp(e, "Temperature") { b.temperature = Double(t) / 100 }
            var amp: Int? = ioProp(e, "InstantAmperage")
            if amp == nil || amp == 0 { amp = ioProp(e, "Amperage") }
            if let v: Int = ioProp(e, "Voltage"), let a = amp {
                b.voltage = Double(v) / 1000
                b.amperage = Double(a) / 1000
                let w = abs(Double(v) * Double(a)) / 1_000_000
                if w < 400 { b.watts = w }
                if b.onAC, a > 50 { b.charging = true }
                if b.charging, b.chargeWatts == nil, a > 0, w < 400 { b.chargeWatts = w }
            }
        }
        if b.temperature == nil,
           let sensor = sensors.first(where: { $0.name.lowercased().contains("gas gauge") || $0.name.lowercased().contains("battery") }) {
            b.temperature = sensor.value
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            b.adapterWatts = adapter["Watts"] as? Int
        }
        battery = b
    }
}

/// Apple Silicon の温度センサ。非公開APIなので dlsym で探し、無ければ nil を返すだけにする。
final class ThermalReader {
    private typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
    private typealias ServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeRawPointer?
    private typealias PropFn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias EventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeRawPointer?
    private typealias FloatFn = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private var client: UnsafeMutableRawPointer? = nil
    private var services: UnsafeRawPointer? = nil
    private var propFn: PropFn? = nil
    private var eventFn: EventFn? = nil
    private var floatFn: FloatFn? = nil
    private var names: [String?] = []
    private(set) var sensors: [(name: String, value: Double)] = []

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"),
              let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let p = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        let create = unsafeBitCast(c, to: CreateFn.self)
        let setMatch = unsafeBitCast(m, to: SetMatchFn.self)
        let copyServices = unsafeBitCast(s, to: ServicesFn.self)
        propFn = unsafeBitCast(p, to: PropFn.self)
        eventFn = unsafeBitCast(e, to: EventFn.self)
        floatFn = unsafeBitCast(f, to: FloatFn.self)
        guard let cl = create(nil) else { return }
        client = cl
        let match = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as NSDictionary
        _ = setMatch(cl, UnsafeRawPointer(Unmanaged.passUnretained(match).toOpaque()))
        services = copyServices(cl)
    }

    func read() -> Double? {
        guard let services, let propFn, let eventFn, let floatFn else { return nil }
        let arr = Unmanaged<CFArray>.fromOpaque(services).takeUnretainedValue()
        let n = CFArrayGetCount(arr)
        if names.count != n {
            let key = "Product" as NSString
            let keyPtr = UnsafeRawPointer(Unmanaged.passUnretained(key).toOpaque())
            names = (0..<n).map { i in
                guard let s = CFArrayGetValueAtIndex(arr, i), let v = propFn(s, keyPtr) else { return nil }
                return Unmanaged<AnyObject>.fromOpaque(v).takeRetainedValue() as? String
            }
        }
        var core: [Double] = []
        var found: [(name: String, value: Double)] = []
        var other: [Double] = []
        let tempType: Int64 = 15
        let field = Int32(15 << 16)
        for i in 0..<n {
            guard let s = CFArrayGetValueAtIndex(arr, i), let ev = eventFn(s, tempType, 0, 0) else { continue }
            let v = floatFn(ev, field)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            guard v > 5, v < 130 else { continue }
            let name = names[i] ?? ""
            let l = name.lowercased()
            if !name.isEmpty { found.append((name: name, value: v)) }
            if l.contains("tdie") || l.contains("acc mtr") { core.append(v) }
            else if !(l.contains("battery") || l.contains("nand") || l.contains("tcal")) { other.append(v) }
        }
        sensors = found.sorted { $0.value > $1.value }
        let use = core.isEmpty ? other : core
        return use.max()
    }
}
