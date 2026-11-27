import SwiftUI

/// The line Claude Code's terminal shows while it works — the star turning
/// through its shapes in Claude's orange, a word for what it is doing, and
/// how long it has been at it — drawn the same way in the pill.
///
/// The session publishes only that it is busy, not the word its terminal
/// happens to show, so the word is one of Claude Code's own, chosen once per
/// turn so it holds still while the turn lasts.
enum ClaudeSpinner {
    /// The star's shapes, as the terminal steps through them.
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    static let orange = Color(red: 0.851, green: 0.467, blue: 0.341)

    static let words = [
        "Accomplishing", "Actualizing", "Baking", "Beboppin'", "Blanching", "Booping", "Brewing",
        "Calculating", "Cerebrating", "Channelling", "Churning", "Clauding", "Coalescing",
        "Cogitating", "Combobulating", "Computing", "Concocting", "Conjuring", "Considering",
        "Contemplating", "Cooking", "Crafting", "Crunching", "Deciphering", "Deliberating",
        "Divining", "Elucidating", "Enchanting", "Envisioning", "Finagling", "Forging",
        "Frolicking", "Germinating", "Hatching", "Herding", "Honking", "Hustling", "Ideating",
        "Imagining", "Incubating", "Inferring", "Jiving", "Manifesting", "Marinating",
        "Meandering", "Moseying", "Mulling", "Musing", "Noodling", "Percolating",
        "Perambulating", "Perusing", "Philosophising", "Pondering", "Pontificating",
        "Puttering", "Puzzling", "Reticulating", "Ruminating", "Scheming", "Schlepping",
        "Shimmying", "Simmering", "Smooshing", "Spelunking", "Stewing", "Sussing",
        "Synthesizing", "Tinkering", "Transmuting", "Unfurling", "Unravelling", "Vibing",
        "Whirring", "Wibbling", "Wizarding", "Wrangling",
    ]

    /// The same word for the whole of one turn of one session.
    static func word(session: String, since: Date) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in "\(session)|\(Int(since.timeIntervalSince1970))".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return words[Int(hash % UInt64(words.count))]
    }

    /// "42s", "3m 05s", as the terminal counts.
    static func elapsed(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3600, (seconds % 3600) / 60)
    }
}

/// The star alone: turning while `active`, still otherwise.
struct ClaudeSpinnerGlyph: View {
    var active: Bool
    var size: CGFloat = 13
    @AppStorage(Preferences.codedockLookKey) private var look = "dark"
    private var theme: DockTheme { DockTheme(rawValue: look) ?? .dark }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.12)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
                glyph(ClaudeSpinner.frames[step % ClaudeSpinner.frames.count], color: theme.working)
            }
        } else {
            glyph("✳", color: active ? theme.working : theme.ink)
        }
    }

    private func glyph(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            // Every shape in the same box, so the word beside it never shifts.
            .frame(width: size * 1.1, alignment: .center)
    }
}
