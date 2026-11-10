import Foundation

struct Usage {
    var input = 0, cacheW = 0, cacheR = 0, output = 0
    var context: Int { input + cacheW + cacheR }
    static func += (a: inout Usage, b: Usage) {
        a.input += b.input; a.cacheW += b.cacheW; a.cacheR += b.cacheR; a.output += b.output
    }
}

struct DayAgg {
    var usage = Usage()
    var turns = 0
    var sideTurns = 0
    var sideContext = 0
    var usd = 0.0
}

struct ToolError {
    var at: Date
    var text: String
}

/// One plan limit window as a tool reports it: how much is used and when it resets.
struct LimitReading {
    var usedPercent: Double
    var resetsAt: Date
    var windowMinutes: Int
}

struct CodexLimits {
    var primary: LimitReading?     // the short window (five hours)
    var secondary: LimitReading?   // the long window (a week)
    var at: Date
}

final class SessionAgg {
    let id: String
    var tool = "Claude Code"
    var title: String?
    var firstPrompt: String?
    var cwd = ""
    var days: [String: DayAgg] = [:]
    var hours: [Int: Int] = [:]     // hour since 1970 -> context tokens, for "what used this limit window"
    var turns = 0
    var floorContext: Int?      // context of the first main-chain turn: the fixed overhead
    var peakContext = 0
    var lastContext = 0
    var lastMainAt: Date?
    var last: Date?
    var lastToolError: ToolError?   // set while the newest tool result in the main chain is an error
    /// What the main chain did last: "tool" (a tool call with no result yet), "text" (finished speaking),
    /// "result" (a tool result came back, so it is working), "prompt" (a person typed), "started"/"done" (Codex).
    var lastKind = ""
    var lastKindAt: Date?
    var pendingTool: String?
    init(id: String) { self.id = id }

    var name: String {
        if let t = title, !t.isEmpty { return t }
        if let p = firstPrompt, !p.isEmpty { return p }
        return String(id.prefix(8))
    }
    var project: String { cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent }

    func tokens(since: Date) -> Int {
        let h = Int(since.timeIntervalSince1970 / 3600)
        return hours.reduce(0) { $1.key >= h ? $0 + $1.value : $0 }
    }
}

/// Reads ~/.claude/projects/**/*.jsonl and ~/.codex/sessions/**/*.jsonl incrementally. Each assistant reply is
/// written once per content block with the same usage, so turns are counted
/// once per message id, never once per line.
final class LogScanner {
    /// Where each tool keeps its logs. The App Store build replaces this with the folders the person granted.
    static var logFolder: (String) -> URL = { key in
        let home = FileManager.default.homeDirectoryForCurrentUser
        return key == "codex" ? home.appendingPathComponent(".codex/sessions") : home.appendingPathComponent(".claude/projects")
    }
    let root: URL
    let codexRoot: URL
    let config: Config
    private(set) var sessions: [String: SessionAgg] = [:]
    private(set) var filesRead = 0
    private(set) var codexLimits: CodexLimits?
    private var files: [String: FileState] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let isoPlain = ISO8601DateFormatter()
    private let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private struct FileState {
        var offset: UInt64 = 0
        var seen = Set<String>()
        var codexModel = "gpt"
        var codexSession: String?
    }

    private static let pAssistant = Data(#""type":"assistant""#.utf8)
    private static let pUser = Data(#""type":"user""#.utf8)
    private static let pTitle = Data(#""type":"custom-title""#.utf8)
    private static let pToolResult = Data(#""tool_result""#.utf8)
    private static let pIsError = Data(#""is_error":true"#.utf8)
    private static let pTimestamp = Data(#""timestamp":""#.utf8)
    private static let pCodexUsage = Data(#""type":"token_usage_record""#.utf8)
    private static let pCodexMeta = Data(#""type":"session_meta""#.utf8)
    private static let pCodexTurn = Data(#""type":"turn_context""#.utf8)
    private static let pCodexUser = Data(#""role":"user""#.utf8)
    private static let pCodexLimits = Data(#""rate_limits""#.utf8)
    private static let pCodexStart = Data(#""task_started""#.utf8)
    private static let pCodexDone = Data(#""task_complete""#.utf8)

    init(root: URL = LogScanner.logFolder("claude"), codexRoot: URL = LogScanner.logFolder("codex"), config: Config) {
        self.root = root
        self.codexRoot = codexRoot
        self.config = config
    }

    func day(_ d: Date) -> String { dayFmt.string(from: d) }

    /// Scan every transcript touched in the last `days` days. Returns false when no log folder can be read.
    @discardableResult
    func scan(days: Int = 8) -> Bool {
        let claude = scan(root: root, codex: false, days: days)
        let codex = scan(root: codexRoot, codex: true, days: days)
        return claude || codex
    }

    private func scan(root: URL, codex: Bool, days: Int) -> Bool {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return false }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var any = false
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            any = true
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            let path = url.path
            var st = files[path] ?? FileState()
            let size = UInt64(v.fileSize ?? 0)
            if size == st.offset { continue }
            if size < st.offset { continue }   // truncated or replaced: leave it rather than double count
            if st.offset == 0 { filesRead += 1 }
            read(url: url, codex: codex, state: &st)
            files[path] = st
        }
        return any
    }

    private func read(url: URL, codex: Bool, state: inout FileState) {
        let isSub = url.deletingLastPathComponent().lastPathComponent == "subagents"
        let fileSession = isSub
            ? url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: state.offset) } catch { return }
        var buf = Data()
        while true {
            guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            buf.append(chunk)
            var start = buf.startIndex
            while let nl = buf[start...].firstIndex(of: 0x0A) {
                if codex { handleCodex(line: buf[start..<nl], fileSession: fileSession, state: &state) }
                else { handle(line: buf[start..<nl], fileSession: fileSession, isSub: isSub, state: &state) }
                start = nl + 1
            }
            state.offset += UInt64(start - buf.startIndex)
            buf = Data(buf[start...])
        }
    }

    private func session(_ id: String) -> SessionAgg {
        if let s = sessions[id] { return s }
        let s = SessionAgg(id: id); sessions[id] = s; return s
    }

    private func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Pulls the record's timestamp out of a line without parsing the whole thing (some lines are megabytes).
    private func quickTimestamp(_ line: Data) -> Date? {
        guard let r = line.range(of: Self.pTimestamp) else { return nil }
        let tail = line[r.upperBound...].prefix(40)
        guard let end = tail.firstIndex(of: 0x22), let s = String(data: tail[..<end], encoding: .utf8) else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    private func mark(_ s: SessionAgg, kind: String, at when: Date?, tool: String? = nil) {
        guard let when else { return }
        if let prev = s.lastKindAt, when < prev { return }
        s.lastKind = kind; s.lastKindAt = when; s.pendingTool = tool
    }

    private func add(_ s: SessionAgg, usage: Usage, model: String, when: Date, side: Bool) {
        var agg = s.days[day(when)] ?? DayAgg()
        agg.usage += usage
        agg.turns += 1
        agg.usd += config.usd(model: model, usage)
        if side { agg.sideTurns += 1; agg.sideContext += usage.context }
        s.days[day(when)] = agg
        s.hours[Int(when.timeIntervalSince1970 / 3600), default: 0] += usage.context
        s.turns += 1
        if s.last == nil || when > s.last! { s.last = when }
        if !side {
            if s.floorContext == nil { s.floorContext = usage.context }
            s.peakContext = max(s.peakContext, usage.context)
            if s.lastMainAt == nil || when >= s.lastMainAt! { s.lastMainAt = when; s.lastContext = usage.context }
        }
    }

    // MARK: Codex

    /// Codex writes one token_usage_record per model reply; input_tokens there already includes the cached part.
    private func handleCodex(line: Data, fileSession: String, state: inout FileState) {
        func codexSession(_ id: String?) -> SessionAgg {
            let s = session("codex:" + (id ?? state.codexSession ?? fileSession))
            s.tool = "Codex"
            return s
        }
        if line.range(of: Self.pCodexUsage) != nil {
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  d["type"] as? String == "token_usage_record",
                  let p = d["payload"] as? [String: Any], let u = p["usage"] as? [String: Any],
                  let when = date(d["timestamp"]) else { return }
            let rid = (p["response_id"] as? String) ?? "\(d["ordinal"] ?? UUID().uuidString)"
            if !state.seen.insert(rid).inserted { return }
            let total = u["input_tokens"] as? Int ?? 0
            let cached = u["cached_input_tokens"] as? Int ?? 0
            let written = u["cache_write_input_tokens"] as? Int ?? 0
            let usage = Usage(input: max(0, total - cached - written), cacheW: written, cacheR: cached, output: u["output_tokens"] as? Int ?? 0)
            add(codexSession(p["session_id"] as? String), usage: usage, model: state.codexModel, when: when, side: false)
            return
        }
        if line.range(of: Self.pCodexLimits) != nil || line.range(of: Self.pCodexStart) != nil || line.range(of: Self.pCodexDone) != nil {
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  d["type"] as? String == "event_msg", let p = d["payload"] as? [String: Any],
                  let when = date(d["timestamp"]) else { return }
            let kind = p["type"] as? String
            if kind == "task_started" { mark(codexSession(nil), kind: "started", at: when) }
            if kind == "task_complete" { mark(codexSession(nil), kind: "done", at: when) }
            if kind == "token_count", let rl = p["rate_limits"] as? [String: Any], codexLimits == nil || when >= codexLimits!.at {
                func reading(_ key: String) -> LimitReading? {
                    guard let w = rl[key] as? [String: Any], let pct = w["used_percent"] as? Double ?? (w["used_percent"] as? Int).map(Double.init),
                          let reset = w["resets_at"] as? Double ?? (w["resets_at"] as? Int).map(Double.init) else { return nil }
                    return LimitReading(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: reset), windowMinutes: w["window_minutes"] as? Int ?? 0)
                }
                codexLimits = CodexLimits(primary: reading("primary"), secondary: reading("secondary"), at: when)
            }
            return
        }
        if line.range(of: Self.pCodexMeta) != nil || line.range(of: Self.pCodexTurn) != nil {
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = d["type"] as? String, type == "session_meta" || type == "turn_context",
                  let p = d["payload"] as? [String: Any] else { return }
            if type == "session_meta", let id = (p["session_id"] as? String) ?? (p["id"] as? String) { state.codexSession = id }
            if let m = p["model"] as? String, !m.isEmpty { state.codexModel = m.lowercased().contains("gpt") ? m : "gpt-" + m }
            let s = codexSession(nil)
            if s.cwd.isEmpty, let c = p["cwd"] as? String { s.cwd = c }
            return
        }
        if line.range(of: Self.pCodexUser) != nil {
            let s = codexSession(nil)
            if s.firstPrompt != nil { return }
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let p = d["payload"] as? [String: Any], p["type"] as? String == "message", p["role"] as? String == "user",
                  let content = p["content"] as? [[String: Any]] else { return }
            for b in content {
                guard let t = b["text"] as? String else { continue }
                let flat = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !flat.isEmpty && !flat.hasPrefix("<") && !flat.hasPrefix("#") { s.firstPrompt = String(flat.prefix(70)); break }
            }
        }
    }

    // MARK: Claude Code

    private func handle(line: Data, fileSession: String, isSub: Bool, state: inout FileState) {
        if line.range(of: Self.pAssistant) != nil {
            guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  d["type"] as? String == "assistant",
                  let msg = d["message"] as? [String: Any],
                  let u = msg["usage"] as? [String: Any],
                  let when = date(d["timestamp"]) else { return }
            let model = msg["model"] as? String ?? "?"
            if model == "<synthetic>" { return }
            let side = isSub || (d["isSidechain"] as? Bool ?? false)
            let s = session(isSub ? fileSession : (d["sessionId"] as? String ?? fileSession))
            if s.cwd.isEmpty, let c = d["cwd"] as? String { s.cwd = c }
            if !side, let blocks = msg["content"] as? [[String: Any]] {
                // Each line holds one part of the reply; the last part decides what the session is doing now.
                if let call = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                    mark(s, kind: "tool", at: when, tool: call["name"] as? String)
                } else if blocks.contains(where: { $0["type"] as? String == "text" }) {
                    mark(s, kind: "text", at: when)
                }
            }
            let mid = (msg["id"] as? String) ?? (d["uuid"] as? String) ?? UUID().uuidString
            if !state.seen.insert(mid).inserted { return }
            let usage = Usage(input: u["input_tokens"] as? Int ?? 0,
                              cacheW: u["cache_creation_input_tokens"] as? Int ?? 0,
                              cacheR: u["cache_read_input_tokens"] as? Int ?? 0,
                              output: u["output_tokens"] as? Int ?? 0)
            add(s, usage: usage, model: model, when: when, side: side)
            return
        }
        if isSub { return }
        if line.range(of: Self.pTitle) != nil, line.count < 4096 {
            if let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               d["type"] as? String == "custom-title", let t = d["customTitle"] as? String {
                session(d["sessionId"] as? String ?? fileSession).title = t
            }
            return
        }
        guard line.range(of: Self.pUser) != nil else { return }
        let hasResult = line.range(of: Self.pToolResult) != nil
        let hasError = hasResult && line.range(of: Self.pIsError) != nil
        if hasResult && !hasError && line.count > 20_000 {
            // A big clean tool result: nothing to learn but that a result came back and it was not an error.
            if let s = sessions[fileSession] {
                s.lastToolError = nil
                mark(s, kind: "result", at: quickTimestamp(line))
            }
            return
        }
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              d["type"] as? String == "user", !(d["isSidechain"] as? Bool ?? false),
              let msg = d["message"] as? [String: Any] else { return }
        let s = session(d["sessionId"] as? String ?? fileSession)
        let when = date(d["timestamp"])
        if let text = msg["content"] as? String {
            let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if flat.isEmpty || flat.hasPrefix("<") { return }
            if s.firstPrompt == nil { s.firstPrompt = String(flat.prefix(70)) }
            s.lastToolError = nil   // a person typed here after the error
            mark(s, kind: "prompt", at: when)
            return
        }
        guard let blocks = msg["content"] as? [[String: Any]] else { return }
        var sawResult = false
        var err: String?
        for b in blocks {
            let type = b["type"] as? String
            if type == "tool_result" {
                sawResult = true
                if b["is_error"] as? Bool == true {
                    if let t = b["content"] as? String { err = t }
                    else if let parts = b["content"] as? [[String: Any]] {
                        err = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
                    } else { err = "tool call failed" }
                }
            } else if type == "text", let t = b["text"] as? String {
                let flat = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !flat.isEmpty && !flat.hasPrefix("<") {
                    if s.firstPrompt == nil { s.firstPrompt = String(flat.prefix(70)) }
                    mark(s, kind: "prompt", at: when)
                }
            }
        }
        if sawResult {
            mark(s, kind: "result", at: when)
            if let e = err, let when {
                let flat = e.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                s.lastToolError = ToolError(at: when, text: String(flat.prefix(300)))
            } else {
                s.lastToolError = nil
            }
        }
    }
}
