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
    var prices: [String: [Double]] = [
        "opus": [15, 18.75, 1.5, 75],
        "sonnet": [3, 3.75, 0.3, 15],
        "haiku": [1, 1.25, 0.1, 5],
        "gpt": [1.25, 1.25, 0.125, 10],     // rough placeholder for Codex models; edit to your real rates
        "default": [15, 18.75, 1.5, 75],
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
        if let v = d["prices"] as? [String: [Double]] { for (k, p) in v where p.count == 4 { c.prices[k] = p } }
        Config.adjust?(&c)
        return c
    }

    func save() {
        let d: [String: Any] = [
            "dailyBudget": dailyBudget, "historyCeiling": historyCeiling, "floorWarning": floorWarning,
            "redBorder": redBorder, "watchGitHub": watchGitHub, "watchClaude": watchClaude, "watchCodex": watchCodex,
            "notifications": notifications, "menuBarDollars": menuBarDollars, "menuBarLimit": menuBarLimit, "claudeLimits": claudeLimits, "renewClaudeLogin": renewClaudeLogin,
            "limitWarnPercent": limitWarnPercent, "notifyWaiting": notifyWaiting, "waitMinutes": waitMinutes, "pushURL": pushURL, "stallMinutes": stallMinutes, "prices": prices,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Config.file)
        }
    }

    func watches(_ tool: String) -> Bool { tool == "Codex" ? watchCodex : watchClaude }

    func usd(model: String, _ u: Usage) -> Double {
        let m = model.lowercased()
        let p = prices.first(where: { $0.key != "default" && m.contains($0.key) })?.value ?? prices["default"] ?? [0, 0, 0, 0]
        return (Double(u.input) * p[0] + Double(u.cacheW) * p[1] + Double(u.cacheR) * p[2] + Double(u.output) * p[3]) / 1e6
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
