import Foundation

/// One plan limit as shown in the dropdown.
struct LimitView: Identifiable {
    let id: String
    let tool: String
    let label: String          // "5-hour" or "Weekly"
    let usedPercent: Double
    let resetsAt: Date
    let resetText: String
    let forecast: String
    let top: String?           // which session used most of this window
    let asOf: Date
    let level: Int             // 0 fine, 1 will run out or past the warning line, 2 reached
}

/// Something worth a notification that is not a failure: a limit about to run out, a session waiting on you.
struct Nudge: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

enum Limits {
    static let claudeFile = Config.dir.appendingPathComponent("claude-limits.json")

    /// Claude Code only hands its plan limits to a status line command, so the status line helper saves them here.
    static func claude() -> (five: LimitReading?, week: LimitReading?, at: Date)? {
        guard let data = try? Data(contentsOf: claudeFile),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = d["at"] as? Double else { return nil }
        func reading(_ key: String, _ minutes: Int) -> LimitReading? {
            guard let w = d[key] as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return LimitReading(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: reset), windowMinutes: minutes)
        }
        return (reading("five_hour", 300), reading("seven_day", 10_080), Date(timeIntervalSince1970: at))
    }

    static func timeText(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }

    static func spanText(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 90 { return "\(max(m, 1)) min" }
        if m < 48 * 60 { return String(format: "%.1f hours", Double(m) / 60) }
        return String(format: "%.1f days", Double(m) / 1440)
    }

    /// A plain sentence on where this window is heading, and how worried to be (0, 1 or 2).
    /// The pace is the average since the window opened: simple, and easy to check by hand.
    static func forecast(_ r: LimitReading, warnAt: Double, now: Date) -> (text: String, level: Int) {
        let window = Double(max(r.windowMinutes, 1)) * 60
        let start = r.resetsAt.addingTimeInterval(-window)
        let elapsed = max(now.timeIntervalSince(start), 60)
        let used = r.usedPercent
        if used >= 100 { return ("Limit reached. It resets \(timeText(r.resetsAt, now: now)).", 2) }
        if used < 1 { return ("Barely used so far.", 0) }
        if elapsed < window * 0.08 && used < 10 { return ("Too early in this window to forecast.", 0) }
        let projected = used * window / elapsed
        if projected >= 100 {
            let runOut = start.addingTimeInterval(elapsed * 100 / used)
            let early = r.resetsAt.timeIntervalSince(runOut)
            return ("At this pace you run out at \(timeText(runOut, now: now)), \(spanText(early)) before it resets.", 1)
        }
        return (String(format: "On pace to finish this window at about %.0f%%.", projected), used >= warnAt ? 1 : 0)
    }

    static func views(scanner: LogScanner, config: Config, now: Date = Date()) -> [LimitView] {
        var out: [LimitView] = []
        func add(_ tool: String, _ label: String, _ r: LimitReading?, asOf: Date) {
            guard let r, r.resetsAt > now, r.windowMinutes > 0 else { return }   // a window that already reset is stale
            let start = r.resetsAt.addingTimeInterval(-Double(r.windowMinutes) * 60)
            let mine = scanner.sessions.values.filter { $0.tool == tool }
            let total = mine.reduce(0) { $0 + $1.tokens(since: start) }
            var top: String?
            if total > 0, let best = mine.max(by: { $0.tokens(since: start) < $1.tokens(since: start) }) {
                let share = Double(best.tokens(since: start)) / Double(total) * 100
                if share >= 25 { top = String(format: "%@ used about %.0f%% of the tokens in this window.", best.name, share) }
            }
            let f = forecast(r, warnAt: Double(config.limitWarnPercent), now: now)
            out.append(LimitView(id: "\(tool):\(label):\(Int(r.resetsAt.timeIntervalSince1970))", tool: tool, label: label,
                                 usedPercent: r.usedPercent, resetsAt: r.resetsAt, resetText: "resets \(timeText(r.resetsAt, now: now))",
                                 forecast: f.text, top: top, asOf: asOf, level: f.level))
        }
        if config.watchClaude, let c = claude() {
            add("Claude Code", "5-hour", c.five, asOf: c.at)
            add("Claude Code", "Weekly", c.week, asOf: c.at)
        }
        if config.watchCodex, let c = scanner.codexLimits {
            add("Codex", "5-hour", c.primary, asOf: c.at)
            add("Codex", "Weekly", c.secondary, asOf: c.at)
        }
        return out
    }

    static func nudges(_ views: [LimitView]) -> [Nudge] {
        views.filter { $0.level >= 1 }.map {
            Nudge(id: "limit:\($0.id):\($0.level)",
                  title: "\($0.tool) \($0.label.lowercased()) limit: \(Int($0.usedPercent))% used",
                  detail: $0.forecast + ($0.top.map { " " + $0 } ?? ""))
        }
    }
}
