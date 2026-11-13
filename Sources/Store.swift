import AppKit

/// アプリ全体の状態と設定
final class Store {
    let sampler = Sampler()
    private(set) var themes: [Theme] = []
    private(set) var theme: Theme
    var onThemeChange: (() -> Void)?
    var onSettingsChange: (() -> Void)?
    var onTransparencyChange: (() -> Void)?
    var onFloatChange: (() -> Void)?
    var onQuit: (() -> Void)?

    static let fallback = SkinDef(id: "plain", name: "Default", appearance: "auto", material: "glass")

    var userSkinDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mimo/Skins", isDirectory: true)
    }

    private let d: UserDefaults
    var metrics: [String] {
        get { d.stringArray(forKey: "metrics") ?? ["cpu", "mem"] }
        set { d.set(newValue, forKey: "metrics"); onSettingsChange?() }
    }
    var interval: Double {
        get { let v = d.double(forKey: "interval"); return v > 0 ? v : 2 }
        set { d.set(newValue, forKey: "interval"); onSettingsChange?() }
    }
    var groupApps: Bool {
        get { d.object(forKey: "groupApps") as? Bool ?? true }
        set { d.set(newValue, forKey: "groupApps") }
    }
    var sort: ProcSort {
        get { ProcSort(rawValue: d.string(forKey: "sort") ?? "cpu") ?? .cpu }
        set { d.set(newValue.rawValue, forKey: "sort") }
    }

    // メニューバーのアイコン
    var menuIcon: String {
        get { d.string(forKey: "menuIcon") ?? "heart" }
        set { d.set(newValue, forKey: "menuIcon"); onSettingsChange?() }
    }
    var menuColor: String {
        get { d.string(forKey: "menuColor") ?? "system" }
        set { d.set(newValue, forKey: "menuColor"); onSettingsChange?() }
    }
    var menuSource: String {
        get { d.string(forKey: "menuSource") ?? "cpu" }
        set { d.set(newValue, forKey: "menuSource"); onSettingsChange?() }
    }
    var menuShowValue: Bool {
        get { d.bool(forKey: "menuShowValue") }
        set { d.set(newValue, forKey: "menuShowValue"); onSettingsChange?() }
    }
    var smoothMotion: Bool {
        get { d.object(forKey: "smoothMotion") as? Bool ?? true }
        set { d.set(newValue, forKey: "smoothMotion"); onSettingsChange?() }
    }
    /// 背景の透明度。0 で不透明、0.7 で最も透ける
    var transparency: Double {
        get { d.double(forKey: "transparency") }
        set { d.set(newValue, forKey: "transparency"); onTransparencyChange?() }
    }
    /// メニューバーのパネルに出すカード
    static let allTrayItems = ["cpu", "memory", "gpu", "network", "disk", "power", "top"]
    var trayItems: [String] {
        get { d.stringArray(forKey: "trayItems") ?? Store.allTrayItems }
        set { d.set(newValue, forKey: "trayItems"); onSettingsChange?() }
    }
    /// メニューバーのパネルの詳しさ 0 Compact / 1 Standard / 2 Detailed
    var trayDetail: Int {
        get { d.object(forKey: "trayDetail") as? Int ?? 1 }
        set { d.set(newValue, forKey: "trayDetail"); onSettingsChange?() }
    }
    /// メニューバーのパネル全体を囲む枠と背景
    var trayFrame: Bool {
        get { d.object(forKey: "trayFrame") as? Bool ?? true }
        set { d.set(newValue, forKey: "trayFrame"); onTransparencyChange?() }
    }
    // 常に手前に出すフローティングパネル
    var floatEnabled: Bool {
        get { d.bool(forKey: "floatEnabled") }
        set { d.set(newValue, forKey: "floatEnabled"); onFloatChange?() }
    }
    /// 画面のどの隅に置くか topLeft / topRight / bottomLeft / bottomRight
    var floatCorner: String {
        get { d.string(forKey: "floatCorner") ?? "topRight" }
        set { d.set(newValue, forKey: "floatCorner"); onFloatChange?() }
    }
    /// パネル全体の透明度。0 で不透明、0.8 で最も透ける
    var floatTransparency: Double {
        get { d.double(forKey: "floatTransparency") }
        set { d.set(newValue, forKey: "floatTransparency"); onFloatChange?() }
    }
    /// フローティングパネルに出すカード
    var floatItems: [String] {
        get { d.stringArray(forKey: "floatItems") ?? ["cpu", "memory", "network"] }
        set { d.set(newValue, forKey: "floatItems"); onFloatChange?() }
    }
    /// フローティングパネル全体を囲む枠と背景
    var floatFrame: Bool {
        get { d.object(forKey: "floatFrame") as? Bool ?? true }
        set { d.set(newValue, forKey: "floatFrame"); onFloatChange?() }
    }
    var blurBehind: Bool {
        get { d.bool(forKey: "blurBehind") }
        set { d.set(newValue, forKey: "blurBehind"); onTransparencyChange?() }
    }
    /// 線だけのグラフの下を薄く塗る
    var graphFill: Bool {
        get { d.object(forKey: "graphFill") as? Bool ?? true }
        set { d.set(newValue, forKey: "graphFill"); onSettingsChange?() }
    }
    var sidebarCollapsed: Bool {
        get { d.bool(forKey: "sidebarCollapsed") }
        set { d.set(newValue, forKey: "sidebarCollapsed") }
    }

    /// アイコンの動きに使う負荷（0〜1）
    var menuLoad: Double {
        let s = sampler
        switch menuSource {
        case "mem": return s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        case "gpu": return s.gpu ?? 0
        case "net": return min(1, sqrt((s.netDown + s.netUp) / (20 * 1_048_576)))
        default: return s.cpu
        }
    }
    var menuValueText: String {
        if menuSource == "net" { return formatRate(sampler.netDown + sampler.netUp) }
        return "\(Int((menuLoad * 100).rounded()))%"
    }

    // Overview のレイアウト
    var layout: [WidgetConfig] {
        get {
            guard let data = d.data(forKey: "overviewLayout"),
                  let saved = try? JSONDecoder().decode([WidgetConfig].self, from: data) else { return WidgetConfig.defaults }
            let missing = WidgetConfig.defaults.filter { w in !saved.contains { $0.kind == w.kind } }
                .map { w -> WidgetConfig in var c = w; c.visible = false; return c }
            return saved + missing
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "overviewLayout") }
        }
    }

    init(persist: Bool) {
        // 確認用スナップショットが普段の設定を書き換えないよう保存先を分ける
        d = persist ? .standard : (UserDefaults(suiteName: "io.github.lay-kuw.mimo.snapshot") ?? .standard)
        theme = Theme(Store.fallback)
        // 確認用では、裏で読む計測もその場で済ませて結果をすぐ使う
        sampler.inlineSlowWork = !persist
        reloadSkins()
    }

    func reloadSkins() {
        var defs: [String: SkinDef] = [:]
        let dec = JSONDecoder()
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Skins")) }
        try? FileManager.default.createDirectory(at: userSkinDir, withIntermediateDirectories: true)
        dirs.append(userSkinDir) // 同じ id ならユーザー側が優先
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "json" {
                guard let data = try? Data(contentsOf: f) else { continue }
                do {
                    let s = try dec.decode(SkinDef.self, from: data)
                    defs[s.id] = s
                } catch {
                    NSLog("Mimo: could not read skin \(f.lastPathComponent): \(error)")
                }
            }
        }
        if defs.isEmpty { defs[Store.fallback.id] = Store.fallback }
        themes = defs.values
            .sorted { ($0.order ?? 999, $0.name) < ($1.order ?? 999, $1.name) }
            .map { Theme($0) }
        let want = d.string(forKey: "skin") ?? "mononeon"
        theme = themes.first { $0.def.id == want } ?? themes[0]
    }

    func select(_ t: Theme) {
        d.set(t.def.id, forKey: "skin")
        theme = t
        onThemeChange?()
    }
}

