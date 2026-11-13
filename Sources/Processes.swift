import Foundation
import Darwin

struct ProcRow {
    var key: String
    var name: String
    var cpu: Double      // 100 = 1コア分
    var mem: UInt64
    var pids: [Int32]
    var appPath: String?
}

enum ProcSort: String { case cpu, mem, name }

/// 自分のユーザーで動くプロセスを読む。システムプロセスは権限がなく読めないため一覧に出さない。
final class ProcessSampler {
    private struct Prev { var ticks: UInt64; var start: UInt64 }
    private struct Ident { var name: String; var appPath: String?; var start: UInt64 }

    private var prev: [Int32: Prev] = [:]
    private var idents: [Int32: Ident] = [:]
    private var lastTime = DispatchTime.now().uptimeNanoseconds
    private var pidBuf = [Int32](repeating: 0, count: 4096)
    private let timebase: Double = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t.denom == 0 ? 1 : Double(t.numer) / Double(t.denom)
    }()

    private(set) var rows: [ProcRow] = []
    private(set) var totalCount = 0

    func sample() {
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Double(now &- lastTime)
        lastTime = now
        let found = pidBuf.withUnsafeMutableBytes { b -> Int32 in
            proc_listallpids(b.baseAddress, Int32(b.count))
        }
        guard found > 0 else { return }
        let count = min(Int(found), pidBuf.count)
        totalCount = count
        var next: [Int32: Prev] = [:]
        next.reserveCapacity(count)
        var result: [ProcRow] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let pid = pidBuf[i]
            guard pid > 0 else { continue }
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { q in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, q)
                }
            }
            guard r == 0 else { continue }
            let ticks = info.ri_user_time &+ info.ri_system_time
            let start = info.ri_proc_start_abstime
            next[pid] = Prev(ticks: ticks, start: start)
            var cpu = 0.0
            if let p = prev[pid], p.start == start, ticks >= p.ticks, wall > 0 {
                cpu = Double(ticks - p.ticks) * timebase / wall * 100
            }
            let id = identity(pid: pid, start: start)
            result.append(ProcRow(key: "p\(pid)", name: id.name, cpu: cpu,
                                  mem: info.ri_phys_footprint, pids: [pid], appPath: id.appPath))
        }
        prev = next
        idents = idents.filter { next[$0.key] != nil }
        rows = result
    }

    private func identity(pid: Int32, start: UInt64) -> Ident {
        if let c = idents[pid], c.start == start { return c }
        var buf = [CChar](repeating: 0, count: 4096)
        var path = ""
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { path = String(cString: buf) }
        var id: Ident
        if let r = path.range(of: ".app/") {
            let appPath = String(path[path.startIndex..<r.lowerBound]) + ".app"
            let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            id = Ident(name: name, appPath: appPath, start: start)
        } else if !path.isEmpty {
            id = Ident(name: (path as NSString).lastPathComponent, appPath: nil, start: start)
        } else {
            var nb = [CChar](repeating: 0, count: 256)
            _ = proc_name(pid, &nb, UInt32(nb.count))
            id = Ident(name: String(cString: nb), appPath: nil, start: start)
        }
        if id.name.isEmpty { id.name = "pid \(pid)" }
        idents[pid] = id
        return id
    }

    func list(grouped: Bool, sort: ProcSort) -> [ProcRow] {
        var out: [ProcRow]
        if grouped {
            var map: [String: ProcRow] = [:]
            for r in rows {
                let k = r.appPath ?? r.key
                if var e = map[k] {
                    e.cpu += r.cpu; e.mem += r.mem; e.pids += r.pids
                    map[k] = e
                } else {
                    var n = r
                    n.key = k
                    map[k] = n
                }
            }
            out = Array(map.values)
        } else {
            out = rows
        }
        switch sort {
        case .cpu: out.sort { $0.cpu == $1.cpu ? $0.mem > $1.mem : $0.cpu > $1.cpu }
        case .mem: out.sort { $0.mem > $1.mem }
        case .name: out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return out
    }
}
