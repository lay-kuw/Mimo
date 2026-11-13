import AppKit

let args = CommandLine.arguments
let application = NSApplication.shared

if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    runSnapshot(outDir: args[i + 1])
    exit(0)
}
if args.contains("--bench") {
    runBench()
    exit(0)
}
if args.contains("--selftest") {
    exit(runSelfTest())
}

// 二重起動を防ぐ
let me = ProcessInfo.processInfo.processIdentifier
if let bid = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bid).contains(where: { $0.processIdentifier != me }) {
    exit(0)
}

let delegate = AppDelegate(startInBackground: args.contains("--background"))
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
