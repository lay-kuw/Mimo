import Foundation

func formatBytes(_ v: UInt64) -> String {
    let d = Double(v)
    if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
    if d >= 1_048_576 { return String(format: "%.0f MB", d / 1_048_576) }
    return String(format: "%.0f KB", d / 1024)
}

func formatRate(_ d: Double) -> String {
    if d >= 1_048_576 { return String(format: "%.1f MB/s", d / 1_048_576) }
    if d >= 1024 { return String(format: "%.0f KB/s", d / 1024) }
    return String(format: "%.0f B/s", d)
}
