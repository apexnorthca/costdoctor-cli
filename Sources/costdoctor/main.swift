import Foundation

let version = "1.0.2"
let appLink = "https://costdoctor.app/?ref=cli"
let args = Array(CommandLine.arguments.dropFirst())

func say(_ s: String = "") { print(s) }
func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

if args.contains("--help") || args.contains("-h") {
    say("""
    costdoctor \(version): where your Claude Code and Codex tokens go. Reads the logs on this Mac; nothing is uploaded.

      costdoctor               the last 7 days, your plan limits, and today's heaviest sessions
      costdoctor --month       the last 30 days
      costdoctor card [file]   a picture of your week to share (no session or project names on it)
      costdoctor --no-limits   do not ask Anthropic for your Claude plan limits

    Claude plan limits are read with the Claude Code sign-in already saved on this Mac. It is only read, never
    changed, and sent to Anthropic and nowhere else. Prices are estimates at API list prices.
    """)
    exit(0)
}
if args.contains("--version") { say(version); exit(0) }

let config = Config.load()
let month = args.contains("--month")
let isCard = args.first == "card"

// Claude limits first: one quick request, so the forecast below uses a fresh reading.
var limitsNote: String?
if !isCard && !args.contains("--no-limits") && config.watchClaude {
    let t = ClaudeLimitsAPI.savedToken()
    if let token = t.token { limitsNote = ClaudeLimitsAPI.fetch(token: token).note } else { limitsNote = t.why }
}

note("Reading your Claude Code and Codex logs…")
let scanner = LogScanner(config: config)
let t0 = Date()
guard scanner.scan(days: month ? 32 : 8) else {
    say("No Claude Code or Codex logs found on this Mac (looked in ~/.claude/projects and ~/.codex/sessions).")
    exit(3)
}
let snap = Diagnosis.snapshot(scanner: scanner, config: config)

func tokens(_ tool: String, _ day: String) -> Int {
    scanner.sessions.values.filter { $0.tool == tool && config.watches(tool) }.reduce(0) { $0 + ($1.days[day]?.usage.context ?? 0) }
}
func money(_ v: Double) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
    return "$" + (f.string(from: NSNumber(value: v)) ?? "\(Int(v))")
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

let days = month ? snap.month : snap.week

if isCard {
    let out = args.dropFirst().first(where: { !$0.hasPrefix("-") }).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/costdoctor-week.png")
    let week = snap.week
    if args.contains("--demo") {   // made-up numbers, for the README picture
        let m = [612, 388, 905, 441, 530, 274, 486]
        let demo = CardStats(days: zip(week, m).map { ($0.day, $1 * 1_000_000) }, tokens: 3_636_000_000, usd: 1_600, turns: 14_544,
                             sideTurns: 3_636, claude: 3_102_000_000, codex: 534_000_000)
        if let why = Card.write(demo, to: out) { say(why); exit(1) }
        say("Saved \(out.path)"); exit(0)
    }
    let stats = CardStats(
        days: week.map { ($0.day, $0.tokens) },
        tokens: week.reduce(0) { $0 + $1.tokens },
        usd: week.reduce(0) { $0 + $1.usd },
        turns: week.reduce(0) { $0 + $1.turns },
        sideTurns: week.reduce(0) { $0 + $1.sideTurns },
        claude: week.reduce(0) { $0 + tokens("Claude Code", $1.day) },
        codex: week.reduce(0) { $0 + tokens("Codex", $1.day) })
    if let why = Card.write(stats, to: out) { say(why); exit(1) }
    say("Saved \(out.path)")
    say("It shows totals only: no session names, project names or prompts.")
    exit(0)
}

say("")
say("Cost Doctor · last \(month ? 30 : 7) days" + String(format: "  (read %d log files in %.0fs; nothing uploaded)", scanner.filesRead, Date().timeIntervalSince(t0)))
say("")
say("Day          Claude Code      Codex    turns  subagents   ~list price")
for d in days {
    let side = d.turns > 0 ? Double(d.sideTurns) / Double(d.turns) * 100 : 0
    say(pad(d.day, 11) + lpad(fmtTokens(tokens("Claude Code", d.day)), 13) + lpad(fmtTokens(tokens("Codex", d.day)), 11)
        + lpad("\(d.turns)", 9) + lpad(String(format: "%.0f%%", side), 11) + lpad(money(d.usd), 14))
}
let total = days.reduce(0) { $0 + $1.tokens }
say(pad("Total", 11) + lpad(fmtTokens(days.reduce(0) { $0 + tokens("Claude Code", $1.day) }), 13)
    + lpad(fmtTokens(days.reduce(0) { $0 + tokens("Codex", $1.day) }), 11) + lpad("\(days.reduce(0) { $0 + $1.turns })", 9)
    + lpad("", 11) + lpad(money(days.reduce(0) { $0 + $1.usd }), 14))
if total == 0 { say("No tokens used in this period.") }
say("Tokens are what each turn sent and re-read (input and cache). Prices are estimates at API list prices.")

say("")
say("Plan limits")
for l in snap.limits {
    say(String(format: "  %@ %@: %.0f%% used, %@", l.tool, l.label, l.usedPercent, l.resetText) + (Date().timeIntervalSince(l.asOf) > 600 ? " (read \(fmtAgo(l.asOf)))" : ""))
    say("     \(l.forecast)")
    if let top = l.top { say("     \(top)") }
}
if snap.limits.isEmpty { say("  None known yet. Codex limits appear after your next Codex turn.") }
if let limitsNote { say("  Claude: \(limitsNote)") }

let heavy = snap.sessions.prefix(5)
if !heavy.isEmpty {
    say("")
    say("Today's heaviest sessions")
    for s in heavy {
        say("  " + lpad(fmtTokens(s.tokensToday), 6) + "  " + lpad("\(s.turnsToday)", 5) + " turns  \(s.tool): \(s.name.prefix(60))" + (s.project.isEmpty ? "" : " [\(s.project)]"))
        for a in s.advice { say("          -> \(a)") }
    }
}

say("")
say("Want this live in your menu bar, with an alert before a limit runs out or when a check fails")
say("while an agent waits? Cost Doctor for Mac: \(appLink)")
