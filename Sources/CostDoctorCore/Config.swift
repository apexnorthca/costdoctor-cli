import Foundation

/// Settings live in ~/.costdoctor/config.json. Every key is optional; a missing
/// key keeps its default.
struct Config {
    var dailyBudget = 750_000_000        // context tokens per day before the menu bar turns amber
    var historyCeiling = 150_000         // history carried on top of a session's own start before it should compact
    var floorWarning = 60_000            // fixed overhead per turn worth flagging
    var redBorder = true                 // draw the red frame around every screen on a failed gate
    var watchGitHub = true
    var watchClaude = true
    var watchCodex = true
    var notifications = true
    var menuBarDollars = false           // show today's estimated dollars in the menu bar instead of tokens
    var menuBarLimit = true              // show the most-used plan limit in the menu bar; falls back to tokens when no limit is known
    var claudeLimits = false             // ask Anthropic for Claude plan limits with the login saved on this Mac
    var renewClaudeLogin = false         // renew the saved Claude login when it has expired, and save it back
    var limitWarnPercent = 80            // tell me when a plan limit passes this
    var notifyWaiting = true             // tell me when a session has had a tool call pending this long
    var waitMinutes = 10
    var pushURL = ""                     // phone alerts: an ntfy topic, a Slack webhook, or any address taking a JSON post
    var stallMinutes = 10                // a session idle this long on an error is reported
    /// $ per million tokens: input, cache write, cache read, output. List-price estimate only.
    /// A model is priced by the longest key its name contains, so "claude-opus-5-5" uses "opus-5-5", not "opus".
    /// Bare names ("opus", "fable") are what the tools log for "the current one", so they carry the newest price.
    /// From Anthropic's and OpenAI's published API prices, checked 2026-11-10.
    var prices: [String: [Double]] = Config.listPrices

    static let listPrices: [String: [Double]] = [
        "fable-5-2": [8, 10, 0.2, 40], "fable-5-1": [10, 12.5, 0.25, 50], "fable": [8, 10, 0.2, 40],
        "mythos-5-1": [10, 12.5, 0.25, 50], "mythos": [8, 10, 0.2, 40],
        "opus-5-5": [4, 5, 0.2, 20], "opus-5": [5, 6.25, 0.5, 25], "opus-4": [5, 6.25, 0.5, 25],
        "opus-4-1": [15, 18.75, 1.5, 75], "opus": [4, 5, 0.2, 20],
        "sonnet-5-5": [2, 2.5, 0.1, 10], "sonnet-5": [2, 2.5, 0.2, 10], "sonnet-4": [3, 3.75, 0.3, 15], "sonnet": [2, 2.5, 0.1, 10],
        "haiku-5-5": [0.1, 0.125, 0.01, 0.5], "haiku-4": [1, 1.25, 0.1, 5], "haiku": [0.1, 0.125, 0.01, 0.5],
        // Codex. OpenAI has no separate cache-write price, so that slot repeats the input price.
        "gpt-6.1-sol": [2, 2, 0.1, 10], "gpt-6.1-terra": [1, 1, 0.05, 5], "gpt-6-astra": [10, 10, 1, 50],
        "gpt-6-sol": [2, 2, 0.2, 10], "gpt-6-luna": [0.1, 0.1, 0.01, 0.5], "gpt": [2, 2, 0.1, 10],
        "default": [8, 10, 0.2, 40],
    ]
    /// The table shipped before 2026-11-10. A settings file that still holds one of these never chose it, so it is
    /// not treated as the person's own rate.
    static let legacyPrices: [String: [Double]] = [
        "opus": [15, 18.75, 1.5, 75], "sonnet": [3, 3.75, 0.3, 15], "haiku": [1, 1.25, 0.1, 5],
        "gpt": [1.25, 1.25, 0.125, 10], "default": [15, 18.75, 1.5, 75],
    ]

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".costdoctor")
    static let alertsDir = dir.appendingPathComponent("alerts")
    static let dismissedDir = alertsDir.appendingPathComponent("dismissed")
    static let ackFile = dir.appendingPathComponent("acked.json")
    static let file = dir.appendingPathComponent("config.json")
    static let welcomedFile = dir.appendingPathComponent("welcomed")

    /// Set once at start by a build that must force some settings (the App Store build turns off what its sandbox forbids).
    static var adjust: ((inout Config) -> Void)?

    static func load() -> Config {
        var c = Config()
        Config.adjust?(&c)
        try? FileManager.default.createDirectory(at: dismissedDir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: file),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        if let v = d["dailyBudget"] as? Int { c.dailyBudget = v }
        if let v = d["historyCeiling"] as? Int { c.historyCeiling = v }
        if let v = d["floorWarning"] as? Int { c.floorWarning = v }
        if let v = d["redBorder"] as? Bool { c.redBorder = v }
        if let v = d["watchGitHub"] as? Bool { c.watchGitHub = v }
        if let v = d["watchClaude"] as? Bool { c.watchClaude = v }
        if let v = d["watchCodex"] as? Bool { c.watchCodex = v }
        if let v = d["notifications"] as? Bool { c.notifications = v }
        if let v = d["menuBarDollars"] as? Bool { c.menuBarDollars = v }
        if let v = d["menuBarLimit"] as? Bool { c.menuBarLimit = v }
        if let v = d["claudeLimits"] as? Bool { c.claudeLimits = v }
        if let v = d["renewClaudeLogin"] as? Bool { c.renewClaudeLogin = v }
        if let v = d["limitWarnPercent"] as? Int { c.limitWarnPercent = v }
        if let v = d["notifyWaiting"] as? Bool { c.notifyWaiting = v }
        if let v = d["waitMinutes"] as? Int { c.waitMinutes = v }
        if let v = d["pushURL"] as? String { c.pushURL = v }
        if let v = d["stallMinutes"] as? Int { c.stallMinutes = v }
        if let v = d["prices"] as? [String: [Double]] { for (k, p) in v where p.count == 4 && Config.legacyPrices[k] != p { c.prices[k] = p } }
        Config.adjust?(&c)
        return c
    }

    func save() {
        let d: [String: Any] = [
            "dailyBudget": dailyBudget, "historyCeiling": historyCeiling, "floorWarning": floorWarning,
            "redBorder": redBorder, "watchGitHub": watchGitHub, "watchClaude": watchClaude, "watchCodex": watchCodex,
            "notifications": notifications, "menuBarDollars": menuBarDollars, "menuBarLimit": menuBarLimit, "claudeLimits": claudeLimits, "renewClaudeLogin": renewClaudeLogin,
            "limitWarnPercent": limitWarnPercent, "notifyWaiting": notifyWaiting, "waitMinutes": waitMinutes, "pushURL": pushURL, "stallMinutes": stallMinutes,
            // Only rates the person changed are saved, so a later update to the list prices reaches them.
            "prices": prices.filter { Config.listPrices[$0.key] != $0.value },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Config.file)
        }
    }

    func watches(_ tool: String) -> Bool { tool == "Codex" ? watchCodex : watchClaude }

    func usd(model: String, _ u: Usage) -> Double {
        let m = model.lowercased()
        let key = prices.keys.filter { $0 != "default" && m.contains($0) }.max { $0.count < $1.count } ?? "default"
        let p = prices[key] ?? [0, 0, 0, 0]
        // Two published price steps by prompt size, applied only to the list prices, never to a rate the person set.
        var inRate = 1.0, outRate = 1.0
        if prices[key] == Config.listPrices[key] {
            if key.hasPrefix("haiku") && key != "haiku-4" && u.context > 100_000 { inRate = 5; outRate = 5 }
            if key.hasPrefix("gpt-6") && u.context > 272_000 { inRate = 2; outRate = 1.5 }
        }
        return ((Double(u.input) * p[0] + Double(u.cacheW) * p[1] + Double(u.cacheR) * p[2]) * inRate + Double(u.output) * p[3] * outRate) / 1e6
    }
}

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: d >= 1e8 ? "%.0fM" : "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0fK", d / 1e3) }
    return "\(n)"
}

func fmtAgo(_ date: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 90 { return "just now" }
    if s < 5400 { return "\(s / 60) min ago" }
    if s < 172_800 { return String(format: "%.1f h ago", Double(s) / 3600) }
    return "\(s / 86_400) d ago"
}
