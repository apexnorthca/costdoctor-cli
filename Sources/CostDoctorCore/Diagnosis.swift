import Foundation

struct SessionReport: Identifiable {
    let id: String
    let tool: String
    let name: String
    let project: String
    let tokensToday: Int
    let turnsToday: Int
    let usdToday: Double
    let contextNow: Int
    let floor: Int
    let sideShare: Double
    let last: Date
    let advice: [String]
    let state: String        // "Working", "Waiting on Bash for 6 min", "Finished 14 min ago", ...
    let stateLevel: Int      // 0 working, 1 finished or quiet, 2 waiting on a tool, 3 stopped on a failure
}

struct DayReport: Identifiable {
    var id: String { day }
    let day: String
    let tokens: Int
    let turns: Int
    let sideTurns: Int
    let usd: Double
}

struct Snapshot {
    var ready = false
    var readFailed = false
    var today = DayReport(day: "", tokens: 0, turns: 0, sideTurns: 0, usd: 0)
    var week: [DayReport] = []
    var month: [DayReport] = []      // the last 30 days, oldest first
    var monthReady = true            // false until the month-long read has finished
    var sessions: [SessionReport] = []
    var limits: [LimitView] = []
    var nudges: [Nudge] = []
    var overBudget = false
    var scannedAt = Date()
}

enum Diagnosis {
    /// Plain-language findings for one session, most expensive problem first.
    static func advice(context: Int, floor: Int, sideShare: Double, turns: Int, tokens: Int, config: Config) -> [String] {
        var out: [String] = []
        // Judged against the session's own start, not a fixed number: a session that begins at 126K
        // is not "bloated" at 200K, it has 74K of history. What compacting can remove is the history.
        let history = max(0, context - floor)
        if history >= config.historyCeiling {
            let ratio = Double(context) / Double(max(floor, 20_000))
            out.append(String(format: "Compact now: it carries %@ of history on top of a %@ start, so each turn costs about %.1fx a fresh one.",
                              fmtTokens(history), fmtTokens(floor), ratio))
        }
        if floor >= config.floorWarning {
            out.append("Starts at \(fmtTokens(floor)) before any work. Turn off connectors and plugins this session does not use.")
        }
        if sideShare >= 0.6 && tokens >= 20_000_000 {
            out.append(String(format: "Subagents are %.0f%% of its tokens today. Fewer, narrower helpers would cut it.", sideShare * 100))
        }
        if turns >= 1500 {
            out.append("\(turns) turns today in one session. Long sessions pay for their whole history every turn.")
        }
        return out
    }

    /// What a session is doing right now, read from the last thing it wrote to its log.
    /// A pending tool call cannot be told apart from a long-running command, so the wording says so.
    static func state(_ s: SessionAgg, config: Config, now: Date) -> (text: String, level: Int, waitedSeconds: TimeInterval) {
        let at = s.lastKindAt ?? s.last ?? now
        let idle = max(0, now.timeIntervalSince(at))
        let span = Limits.spanText(idle)
        if let e = s.lastToolError, idle >= Double(config.stallMinutes) * 60, e.at <= at.addingTimeInterval(1) || s.lastKind == "text" {
            return ("Stopped on a failure, idle \(span)", 3, 0)
        }
        switch s.lastKind {
        case "tool":
            if idle < 45 { return ("Working", 0, 0) }
            return ("Waiting on \(s.pendingTool ?? "a tool") for \(span) (may need your approval)", 2, idle)
        case "text", "done":
            if idle < 30 { return ("Working", 0, 0) }
            return ("Finished \(span) ago", 1, 0)
        case "result", "prompt", "started":
            if idle < 180 { return ("Working", 0, 0) }
            return ("Quiet for \(span)", 1, 0)
        default:
            return (idle < 120 ? "Working" : "Last active \(span) ago", idle < 120 ? 0 : 1, 0)
        }
    }

    static func snapshot(scanner: LogScanner, config: Config, now: Date = Date()) -> Snapshot {
        var snap = Snapshot()
        snap.ready = true
        snap.scannedAt = now
        let today = scanner.day(now)
        var byDay: [String: DayAgg] = [:]
        let watched = scanner.sessions.values.filter { config.watches($0.tool) }
        for s in watched {
            for (d, a) in s.days {
                var t = byDay[d] ?? DayAgg()
                t.usage += a.usage; t.turns += a.turns; t.sideTurns += a.sideTurns; t.usd += a.usd
                byDay[d] = t
            }
        }
        func report(_ d: String) -> DayReport {
            let a = byDay[d] ?? DayAgg()
            return DayReport(day: d, tokens: a.usage.context, turns: a.turns, sideTurns: a.sideTurns, usd: a.usd)
        }
        snap.today = report(today)
        snap.month = (0..<30).reversed().map { report(scanner.day(now.addingTimeInterval(-Double($0) * 86_400))) }
        snap.week = Array(snap.month.suffix(7))
        snap.overBudget = snap.today.tokens > config.dailyBudget
        var nudges: [Nudge] = []
        snap.sessions = watched.compactMap { s -> SessionReport? in
            guard let a = s.days[today], a.usage.context > 0 else { return nil }
            let share = a.usage.context > 0 ? Double(a.sideContext) / Double(a.usage.context) : 0
            let floor = s.floorContext ?? 0
            let st = state(s, config: config, now: now)
            if config.notifyWaiting, st.level == 2, st.waitedSeconds >= Double(config.waitMinutes) * 60, st.waitedSeconds < 6 * 3600 {
                nudges.append(Nudge(id: "wait:\(s.id):\(Int((s.lastKindAt ?? now).timeIntervalSince1970))",
                                    title: "Waiting on you: \(s.name)",
                                    detail: "\(s.tool)\(s.project.isEmpty ? "" : " · " + s.project) has had a \(s.pendingTool ?? "tool") call pending for \(Limits.spanText(st.waitedSeconds)). It may need your approval."))
            }
            return SessionReport(
                id: s.id, tool: s.tool, name: s.name, project: s.project, tokensToday: a.usage.context, turnsToday: a.turns,
                usdToday: a.usd, contextNow: s.lastContext, floor: floor, sideShare: share, last: s.last ?? now,
                advice: advice(context: s.lastContext, floor: floor, sideShare: share, turns: a.turns,
                               tokens: a.usage.context, config: config),
                state: st.text, stateLevel: st.level)
        }.sorted { $0.tokensToday > $1.tokensToday }
        snap.limits = Limits.views(scanner: scanner, config: config, now: now)
        snap.nudges = Limits.nudges(snap.limits) + nudges
        return snap
    }
}
