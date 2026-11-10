import Foundation

/// Claude plan limits, asked of Anthropic's usage service with the Claude Code sign-in already saved on this Mac.
/// This part only READS the saved sign-in: it never renews it, changes it, or saves it anywhere. The sign-in is sent
/// to Anthropic and nowhere else, and is never printed or logged. Only the percentages are kept.
enum ClaudeLimitsAPI {
    /// The access token from the saved sign-in, or a plain sentence on why there is none.
    /// `expired` is true when a sign-in exists but its token has run out (Claude Code renews it the next time it runs).
    static func savedToken() -> (token: String?, expired: Bool, why: String?) {
        var record: [String: Any]?
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { record = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
        }
        if record?["claudeAiOauth"] == nil {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            record = (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        guard let o = record?["claudeAiOauth"] as? [String: Any], let t = o["accessToken"] as? String, !t.isEmpty else {
            return (nil, false, "No saved Claude sign-in was found on this Mac. Sign in to Claude Code once, then try again.")
        }
        if let exp = (o["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 < Date().timeIntervalSince1970 + 60 {
            return (nil, true, "The saved Claude sign-in has expired. Open Claude Code once so it renews, then try again.")
        }
        return (t, false, nil)
    }

    private static func when(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue > 1e11 ? n.doubleValue / 1000 : n.doubleValue }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// Asks Anthropic for the current limits and saves the percentages to `Limits.claudeFile`.
    /// Returns nil on success or a plain sentence on why not; `body` is the service's answer (percentages, no secrets).
    /// Blocks for up to 14 seconds.
    static func fetch(token: String, now: Date = Date()) -> (note: String?, body: String?) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var data: Data?, code = 0, failure: String?
        URLSession(configuration: .ephemeral).dataTask(with: req) { d, r, e in
            data = d; code = (r as? HTTPURLResponse)?.statusCode ?? 0; failure = e?.localizedDescription
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 14) == .timedOut { return ("Anthropic took too long to answer for your limits.", nil) }
        if let failure { return ("Could not reach Anthropic for your limits: \(failure)", nil) }
        let body = "HTTP \(code) " + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        if code == 401 || code == 403 { return ("Anthropic did not accept the saved Claude sign-in. Open Claude Code once so it renews, then try again.", body) }
        guard code == 200, let data, let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("Anthropic's usage service answered with error \(code).", body)
        }
        var save: [String: Any] = ["at": now.timeIntervalSince1970]
        for k in ["five_hour", "seven_day"] {
            guard let w = d[k] as? [String: Any],
                  let pct = ((w["utilization"] ?? w["used_percentage"]) as? NSNumber)?.doubleValue,
                  let reset = when(w["resets_at"]) else { continue }
            save[k] = ["used_percentage": pct, "resets_at": reset]
        }
        guard save.count > 1 else { return ("Anthropic answered, but with no plan limits for this account.", body) }
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: save) { try? out.write(to: Limits.claudeFile, options: .atomic) }
        return (nil, String(data: data, encoding: .utf8))
    }
}
