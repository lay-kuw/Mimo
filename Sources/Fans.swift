import Foundation
import IOKit

/// ファン1つぶんの情報。回転数は rpm。
struct FanInfo {
    var name: String
    var rpm: Double
    var min: Double
    var max: Double
    /// 最低〜最高のうち、今どのあたりで回っているか（0〜1）
    var level: Double {
        guard max > min else { return max > 0 ? Swift.min(rpm / max, 1) : 0 }
        return Swift.min(Swift.max((rpm - min) / (max - min), 0), 1)
    }
}

private let rpmFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return f
}()

func formatRPM(_ v: Double) -> String {
    (rpmFormatter.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))") + " rpm"
}

// SMC（電源・温度・ファンを受け持つ部品）とやりとりする時の入れ物。C の SMCKeyData_t と同じ並び（80バイト）。
private struct SMCVers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0 }
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// ファンの回転数を SMC から読む。ファンのない Mac では最初の1回で読むのをやめる。
final class FanReader {
    private var conn: io_connect_t = 0
    private(set) var available = true
    private(set) var fanCount = 0

    static var layoutSize: Int { MemoryLayout<SMCParam>.size }
    static var resultOffset: Int { MemoryLayout<SMCParam>.offset(of: \SMCParam.result) ?? -1 }

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { available = false; return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &conn) != kIOReturnSuccess {
            conn = 0
            available = false
        }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    func read() -> [FanInfo] {
        guard available else { return [] }
        if fanCount == 0 {
            fanCount = Int(value("FNum") ?? 0)
            if fanCount <= 0 {
                available = false
                if conn != 0 { IOServiceClose(conn); conn = 0 }
                return []
            }
        }
        let n = min(fanCount, 4)
        return (0..<n).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return FanInfo(name: n == 1 ? "Fan" : "Fan \(i + 1)", rpm: max(rpm, 0),
                           min: value("F\(i)Mn") ?? 0, max: value("F\(i)Mx") ?? 0)
        }
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func code(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func name(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? ""
    }

    func value(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var input = SMCParam()
        input.key = FanReader.code(key)
        input.data8 = 9 // キーの型と大きさを聞く
        guard let info = call(&input) else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // 値を読む
        guard let out = call(&input) else { return nil }
        let size = Int(info.keyInfo.dataSize)
        var raw = out.bytes
        let b = withUnsafeBytes(of: &raw) { Array($0.prefix(max(0, min(size, 32)))) }
        switch FanReader.name(info.keyInfo.dataType) {
        case "flt ":
            guard b.count >= 4 else { return nil }
            var f: Float32 = 0
            _ = withUnsafeMutableBytes(of: &f) { b.prefix(4).copyBytes(to: $0) }
            return f.isFinite ? Double(f) : nil
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 ":
            return b.first.map(Double.init)
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }
}
