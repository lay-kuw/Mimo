import AppKit
import Darwin

// 計測や操作の判断のうち、画面や OS に触れない部分。--selftest で確かめられるようにここへ集める。

// MARK: - カウンタの差分

/// 累積カウンタの前回値からの増分。初回は基準を取るだけで 0、値が減った時（リセットや作り直し）も
/// 巨大な値にせず 0 にして、今の値を新しい基準にする。
func counterDelta(previous: UInt64?, current: UInt64) -> UInt64 {
    guard let previous, current >= previous else { return 0 }
    return current - previous
}

/// ディスク1台ぶんの累積値
struct DiskCounters: Equatable {
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
    var readOps: UInt64 = 0
    var writeOps: UInt64 = 0
}

/// ディスクごとに差分を取ってから合計する。新しく接続されたディスクは初回値を基準にするだけ（過去の累積を足さない）。
/// 取り外されたディスクは基準から消える。
func diskDeltas(previous: [UInt64: DiskCounters], current: [UInt64: DiskCounters]) -> DiskCounters {
    var sum = DiskCounters()
    for (id, cur) in current {
        guard let prev = previous[id] else { continue }
        sum.readBytes += counterDelta(previous: prev.readBytes, current: cur.readBytes)
        sum.writeBytes += counterDelta(previous: prev.writeBytes, current: cur.writeBytes)
        sum.readOps += counterDelta(previous: prev.readOps, current: cur.readOps)
        sum.writeOps += counterDelta(previous: prev.writeOps, current: cur.writeOps)
    }
    return sum
}

// MARK: - 時間軸

/// 計測時刻つきの値を、表示する時間幅を等分したマスに並べ直す。
/// 各マスにはその中で最後に取れた値、値がなければ直前の値を入れる。ただし最後の計測から maxGap 秒より
/// 離れたマス（スリープ中など）や、最初の計測より前のマスは nil にして、線を引かない。
func binTimed(times: [Double], values: [Double], now: Double, window: Double, bins: Int, maxGap: Double) -> [Double?] {
    guard bins > 0, window > 0 else { return [] }
    var out = [Double?](repeating: nil, count: bins)
    let start = now - window
    let width = window / Double(bins)
    var j = 0
    var last: (t: Double, v: Double)? = nil
    let n = min(times.count, values.count)
    for i in 0..<bins {
        let binEnd = start + Double(i + 1) * width
        while j < n, times[j] <= binEnd {
            last = (times[j], values[j])
            j += 1
        }
        guard let l = last else { continue }
        if binEnd - l.t <= maxGap + width { out[i] = l.v }
    }
    return out
}

/// nil で区切られた連続部分（開始位置と値）
func contiguousRuns(_ bins: [Double?]) -> [(start: Int, values: [Double])] {
    var runs: [(start: Int, values: [Double])] = []
    var cur: [Double] = []
    var startIdx = 0
    for (i, v) in bins.enumerated() {
        if let v {
            if cur.isEmpty { startIdx = i }
            cur.append(v)
        } else if !cur.isEmpty {
            runs.append((startIdx, cur))
            cur = []
        }
    }
    if !cur.isEmpty { runs.append((startIdx, cur)) }
    return runs
}

/// 計測の間隔が揃っていれば、その間隔（秒）。途中で間隔が変わったり、スリープで途切れていれば nil。
func regularInterval(_ times: [Double]) -> Double? {
    guard times.count >= 3 else { return nil }
    var gaps: [Double] = []
    for i in 1..<times.count { gaps.append(times[i] - times[i - 1]) }
    let sorted = gaps.sorted()
    let median = sorted[sorted.count / 2]
    guard median > 0 else { return nil }
    for g in gaps where g > median * 1.5 || g < median / 1.5 { return nil }
    return median
}

func spanLabel(_ seconds: Double) -> String {
    let s = max(0, seconds)
    if s >= 3600 {
        let h = s / 3600
        return h == h.rounded() ? "\(Int(h)) h ago" : String(format: "%.1f h ago", h)
    }
    if s >= 60 { return "\(Int((s / 60).rounded())) min ago" }
    return "\(Int(s.rounded())) sec ago"
}

// MARK: - 電力

/// 電力のグラフに何を出すか。Mac 全体の消費電力が取れない時は、電池の出入りを「Battery power」として別に扱う。
enum PowerReading: Equatable {
    case system(Double)
    case battery(Double)
    case unavailable

    static func from(systemWatts: Double?, batteryWatts: Double?) -> PowerReading {
        if let s = systemWatts { return .system(s) }
        if let b = batteryWatts { return .battery(b) }
        return .unavailable
    }
    var title: String {
        switch self {
        case .system, .unavailable: return "System power"
        case .battery: return "Battery power"
        }
    }
}

// MARK: - アプリやプロセスの終了

/// 終了させる相手。開始時刻を一緒に持っておき、強制終了の前に同じプロセスのままか確かめる。
struct QuitTarget: Equatable {
    var pid: Int32
    var start: UInt64
}

/// OS への操作をまとめたもの。テストでは偽物に差し替える。
struct ProcessControl {
    /// アプリとして登録されていれば通常の終了を頼んで、受け付けたかを返す。アプリでなければ nil。
    var terminateApp: (Int32) -> Bool?
    /// アプリとして登録されていれば強制終了して、成功したかを返す。アプリでなければ nil。
    var forceTerminateApp: (Int32) -> Bool?
    /// シグナルを送って、失敗した時の errno を返す（成功は 0）
    var signal: (Int32, Int32) -> Int32
    /// 今その pid で動いているプロセスの開始時刻。いなければ nil。
    var startTime: (Int32) -> UInt64?
    var selfPID: Int32

    static let live = ProcessControl(
        terminateApp: { pid in
            guard let app = NSRunningAppLookup.app(pid) else { return nil }
            return app.terminate()
        },
        forceTerminateApp: { pid in
            guard let app = NSRunningAppLookup.app(pid) else { return nil }
            return app.forceTerminate()
        },
        signal: { pid, sig in kill(pid, sig) == 0 ? 0 : errno },
        startTime: { pid in processStartTime(pid) },
        selfPID: getpid())
}

struct QuitOutcome: Equatable {
    /// 依頼を受け付けた相手
    var accepted: [QuitTarget] = []
    /// 頼めなかった相手
    var failed: [QuitTarget] = []
    /// うまくいかなかった理由（画面に出す）。一部だけ失敗した時も入る
    var failure: String? = nil
}

private func describe(errno e: Int32) -> String {
    switch e {
    case EPERM: return "Not permitted. It belongs to another user or the system."
    case ESRCH: return "It has already quit."
    default: return String(cString: strerror(e))
    }
}

/// 通常の終了。アプリならアプリとして終了を頼む（保存の確認などはアプリに任せる）。
/// アプリでないプロセスにだけ SIGTERM を送る。グループ内でアプリが見つかったら、補助プロセスはアプリに任せる。
func requestQuit(_ targets: [QuitTarget], control: ProcessControl) -> QuitOutcome {
    var out = QuitOutcome()
    let list = targets.filter { $0.pid != control.selfPID }
    guard !list.isEmpty else { return QuitOutcome(failure: "Nothing to quit.") }
    var appFound = false
    for t in list {
        guard let ok = control.terminateApp(t.pid) else { continue }
        appFound = true
        if ok { out.accepted.append(t) } else { out.failed.append(t) }
    }
    if appFound {
        if out.accepted.isEmpty {
            out.failure = "The app didn't accept the quit request."
        } else if !out.failed.isEmpty {
            out.failure = "\(out.failed.count) of \(out.failed.count + out.accepted.count) apps didn't accept the quit request."
        }
        return out
    }
    var errors: [Int32] = []
    for t in list {
        let e = control.signal(t.pid, SIGTERM)
        if e == 0 { out.accepted.append(t) } else { out.failed.append(t); errors.append(e) }
    }
    if let e = errors.first {
        out.failure = out.accepted.isEmpty
            ? "Couldn't quit: " + describe(errno: e)
            : "\(errors.count) of \(list.count) couldn't be asked to quit: " + describe(errno: e)
    }
    return out
}

/// 強制終了。最初に終了を頼んだ時と同じプロセスがまだ動いている時だけ止める（pid の使い回しで別のプロセスを止めない）。
func forceQuit(_ targets: [QuitTarget], control: ProcessControl) -> QuitOutcome {
    var out = QuitOutcome()
    var errors: [Int32] = []
    var stillRunning = 0
    for t in targets where t.pid != control.selfPID {
        guard let now = control.startTime(t.pid), now == t.start else { continue }
        stillRunning += 1
        if let ok = control.forceTerminateApp(t.pid) {
            if ok { out.accepted.append(t) } else { out.failed.append(t); errors.append(EPERM) }
            continue
        }
        let e = control.signal(t.pid, SIGKILL)
        if e == 0 { out.accepted.append(t) } else { out.failed.append(t); errors.append(e) }
    }
    if stillRunning == 0 {
        out.failure = "It has already quit."
    } else if let e = errors.first {
        out.failure = out.accepted.isEmpty
            ? "Couldn't force quit: " + describe(errno: e)
            : "\(errors.count) of \(stillRunning) couldn't be force quit: " + describe(errno: e)
    }
    return out
}

/// 通常のアプリ（Dock に出るものとメニューバー常駐のもの）だけを「アプリ」として扱う。
/// 補助プロセスはアプリ本体の終了に任せる。
enum NSRunningAppLookup {
    static func app(_ pid: Int32) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited else { return nil }
        return app
    }
}

/// pid のプロセス開始時刻（同じ pid が別のプロセスに使い回されていないかの確認用）
func processStartTime(_ pid: Int32) -> UInt64? {
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { q in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, q)
        }
    }
    return r == 0 ? info.ri_proc_start_abstime : nil
}

// MARK: - 画面の移動先

/// カードをクリックした時の行き先
enum Destination: Equatable {
    case performance(PerfPage)
    case processes

    static func forCard(_ kind: String) -> Destination {
        switch kind {
        case "cpu": return .performance(.cpu)
        case "memory": return .performance(.memory)
        case "gpu": return .performance(.gpu)
        case "network": return .performance(.network)
        case "disk": return .performance(.disk)
        case "power": return .performance(.power)
        default: return .processes
        }
    }

    var label: String {
        switch self {
        case .performance(let p): return "\(p.title) details"
        case .processes: return "Processes"
        }
    }
}
