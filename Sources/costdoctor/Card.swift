import AppKit

/// Totals for the share card. Nothing personal: no session names, project names or prompts.
struct CardStats {
    let days: [(day: String, tokens: Int)]
    let tokens: Int
    let usd: Double
    let turns: Int
    let sideTurns: Int
    let claude: Int
    let codex: Int
}

/// Draws a 1200x630 (social preview size) picture of the week, at twice the pixels for sharp text.
enum Card {
    static let bg = NSColor(srgbRed: 0.047, green: 0.047, blue: 0.055, alpha: 1)       // #0c0c0e
    static let ink = NSColor(srgbRed: 1.0, green: 0.969, blue: 0.937, alpha: 1)        // #fff7ef
    static let dim = NSColor(srgbRed: 1.0, green: 0.969, blue: 0.937, alpha: 0.6)
    static let orange = NSColor(srgbRed: 1.0, green: 0.616, blue: 0.322, alpha: 1)     // #ff9d52
    static let track = NSColor(srgbRed: 1.0, green: 0.616, blue: 0.322, alpha: 0.14)

    static func text(_ s: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular, at p: NSPoint) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: p)
    }

    /// Returns nil on success or a sentence on why the file could not be written.
    static func write(_ s: CardStats, to url: URL) -> String? {
        let w = 1200, h = 630, scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return "Could not draw the card." }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bg.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()

        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        let usd = "$" + (f.string(from: NSNumber(value: s.usd)) ?? "\(Int(s.usd))")
        text("MY WEEK OF AI CODING", 22, orange, weight: .semibold, at: NSPoint(x: 64, y: 548))
        text("\(fmtTokens(s.tokens)) tokens", 96, ink, weight: .bold, at: NSPoint(x: 60, y: 420))
        text("worth about \(usd) at API list prices", 32, dim, at: NSPoint(x: 64, y: 372))

        var facts: [String] = []
        if s.claude > 0 && s.codex > 0 {
            facts.append("Claude Code \(fmtTokens(s.claude)) · Codex \(fmtTokens(s.codex))")
        } else {
            facts.append(s.codex > 0 ? "all in Codex" : "all in Claude Code")
        }
        facts.append("\(f.string(from: NSNumber(value: s.turns)) ?? "\(s.turns)") turns")
        if s.turns > 0 { facts.append(String(format: "%.0f%% by subagents", Double(s.sideTurns) / Double(s.turns) * 100)) }
        text(facts.joined(separator: "   ·   "), 24, ink, at: NSPoint(x: 64, y: 312))

        // Seven bars, one per day, scaled to the busiest day.
        let peak = max(s.days.map(\.tokens).max() ?? 0, 1)
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
        let label = DateFormatter(); label.dateFormat = "EEE"
        let barW: CGFloat = 125, gap: CGFloat = 32, base: CGFloat = 92, top: CGFloat = 190
        for (i, d) in s.days.enumerated() {
            let x = 64 + CGFloat(i) * (barW + gap)
            track.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: base, width: barW, height: top), xRadius: 10, yRadius: 10).fill()
            let hgt = max(CGFloat(d.tokens) / CGFloat(peak) * top, d.tokens > 0 ? 6 : 0)
            if hgt > 0 { orange.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: base, width: barW, height: hgt), xRadius: 10, yRadius: 10).fill() }
            let name = dayFmt.date(from: d.day).map { label.string(from: $0) } ?? d.day
            text(name, 20, dim, at: NSPoint(x: x + 4, y: base - 34))
        }
        text("made with costdoctor · github.com/apexnorthca/costdoctor-cli", 18, dim, at: NSPoint(x: 64, y: 22))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return "Could not make the PNG." }
        do { try png.write(to: url) } catch { return "Could not save \(url.path): \(error.localizedDescription)" }
        return nil
    }
}
