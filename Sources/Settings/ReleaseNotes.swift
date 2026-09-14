import Foundation

/// What one release changed, in the app's own words.
struct ReleaseNote: Equatable {
    /// Matched against `CFBundleShortVersionString`, so it has to be exactly
    /// the string `MARKETING_VERSION` is set to.
    let version: String
    /// One line under the title. What this release is *about*.
    let headline: String
    let changes: [Change]

    /// A title carries the change; the detail is optional, so a small fix can
    /// be a single line rather than a line padded out to match its neighbours.
    struct Change: Equatable {
        let title: String
        let detail: String

        init(title: String, detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }
}

/// The release history the app ships with.
///
/// Written here rather than fetched from the appcast: it has to be there on a
/// first launch with no network, and it belongs to the build it describes.
/// Bumping `MARKETING_VERSION` without adding an entry is caught by
/// `testTheCurrentVersionHasANote`.
enum ReleaseNotes {
    static var all: [ReleaseNote] {
        [
            ReleaseNote(
                version: "1.11.0",
                headline: L10n.t("Kiro and MiniMax, German, a daily pace ring for Claude, and a switch for folding over full-screen apps."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Kiro and MiniMax"),
                        detail: L10n.t("Kiro reads the kiro-cli sign-in already on this Mac. MiniMax signs in from Codenotch, with a choice of international or China region.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Deutsch"),
                        detail: L10n.t("German joins the app's languages, and the limit and reset notifications are now in Simplified Chinese too.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A daily pace ring for Claude"),
                        detail: L10n.t("Optionally, Claude's main ring shows today's share of the weekly limit, a seventh a day, with the session moving to the thin ring.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Codex's extra limits"),
                        detail: L10n.t("The hover card lists Spark and code review when your account has them, and Appearance can hide them.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Fold for full-screen apps"),
                        detail: L10n.t("The automatic fold over full-screen apps can now be switched off, for anyone whose maximised windows kept folding the notch.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("DeepSeek pricing windows"),
                        detail: L10n.t("Peak and off-peak hours are fully configurable, and signing in picks up DeepSeek's login more reliably.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Alerts on time"),
                        detail: L10n.t("Usage refreshes the moment a limit window rolls over, so reset and limit alerts arrive when they happen, even without a notch on screen.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Smaller fixes"),
                        detail: L10n.t("New providers stay off until you switch them on, the recenter button gives clearer feedback, hovering is ignored while Option-dragging, the Codex completion sound keeps its setting, and the Windows rings and hover card match the Mac's.")
                    ),
                ]
            ),
            ReleaseNote(
                version: "1.10.0",
                headline: L10n.t("Tells you when a limit resets or runs out, speaks Russian, and reads Kimi."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("A card when a limit resets, and when one runs out"),
                        detail: L10n.t("The notch slides out a card the moment a provider's limit rolls over, and again when a session or weekly limit reaches 100%. Notifications in Settings chooses which of those you want, with an optional chime.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Kimi"),
                        detail: L10n.t("Its weekly and 5-hour limits, the sessions it is running, and clicking one now raises the exact terminal tab it is in rather than only the app.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Русский"),
                        detail: L10n.t("A fifth language, on the Mac and on Windows.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Quit from Settings"),
                        detail: L10n.t("A quit action in the Settings sidebar, for when the menu bar icon is switched off.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A web page cannot reach Codenotch's local servers"),
                        detail: L10n.t("The Ollama relay and the Windows event server now refuse browser requests from other sites, and raw responses are kept out of the system log. Reading DeepSeek also checks the page's address exactly, where a lookalike domain could have passed before.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Windows"),
                        detail: L10n.t("Diagnostics print the shape of a value rather than the value, so nothing sensitive lands in a report, and the port's build is checked on every change.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Smaller fixes"),
                        detail: L10n.t("The move handle lines up with the camera housing, and more of Settings is translated into Simplified Chinese.")
                    ),
                ]
            ),
            ReleaseNote(
                version: "1.9.0",
                headline: L10n.t("LM Studio, DeepSeek and Devin, Japanese and Portuguese, and no more keychain password on a timer."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("LM Studio"),
                        detail: L10n.t("Loaded models, whether each is thinking or queued, generation speed, how full its context is, and a daily ledger of the tokens it used. Read from LM Studio on this Mac.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("DeepSeek and Devin"),
                        detail: L10n.t("DeepSeek's platform balance and spend, with a card of daily usage, and Devin's usage.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("日本語 and Português (Brasil)"),
                        detail: L10n.t("Two more languages, and the language picker is now a menu so all of them fit.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The keychain password stops coming back"),
                        detail: L10n.t("Claude Code and Antigravity recreate their saved logins in a way macOS will not let an Always Allow outlast, so the password dialogue kept returning. Background refreshes no longer show it at all; Allow access in Settings is the one place it can still appear.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Carry the notch to another edge"),
                        detail: L10n.t("Hold the arc above the notch and drop it on any edge. Appearance can hide the arc if you would rather not see it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("More on the hover card"),
                        detail: L10n.t("The account's plan under the title, and Codex rate-limit resets you have not used yet.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A Claude login that Claude Code empties keeps its reading"),
                        detail: L10n.t("After Claude Code updates itself it can clear every profile's saved login at once. The last numbers now stay, dimmed, instead of vanishing.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Antigravity reads the same numbers from every source"),
                        detail: L10n.t("Its local server and Google's own endpoint are read by one parser, so the ring does not change depending on which answered. In automatic mode an exhausted limit only leads when every limit is exhausted.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Gemini API counts OpenCode and Hermes"),
                        detail: L10n.t("Turns made through OpenCode and Hermes now count toward the Gemini API ring.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Smaller fixes"),
                        detail: L10n.t("Recentre moves the notch at once; full-screen auto-fold accounts for the camera housing; and a rate-limit wait no longer costs a whole extra refresh.")
                    ),
                ]
            ),
            ReleaseNote(
                version: "1.8.0",
                headline: L10n.t("A second ring for the week, Liquid Glass, French, and Claude Desktop read straight from its own cache."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("The week gets a ring of its own"),
                        detail: L10n.t("A second arc, inside the headline ring or outside it, for providers that publish a weekly limit as well as a session one. Off by default; Appearance has the switch.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Liquid Glass"),
                        detail: L10n.t("The open notch, its tooltip and the settings orb take the system's own glass surface, so they refract what is behind them instead of sitting on it. Reduce Transparency turns it solid.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Français"),
                        detail: L10n.t("A third language in Appearance, alongside English and 简体中文.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Claude Desktop usage, read from its own cache"),
                        detail: L10n.t("A third way to read a Claude account, used when the CLI and the token cannot answer. Nothing is sent anywhere: the cache is on this Mac and is only decompressed.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Claude Code found where npm puts it"),
                        detail: L10n.t("An install under nvm, Volta or pnpm is discovered like any other, which also restores the background sign-in renewal for those setups.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("No more transcript folders left behind"),
                        detail: L10n.t("Reading Claude usage ran in a fresh directory every poll, and Claude Code filed a transcript folder for each one. It now runs from a single place, in print mode, writing no session at all.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Reset times follow the Mac's clock"),
                        detail: L10n.t("A 24-hour Mac gets 24-hour reset times instead of AM and PM.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A finished session says so"),
                        detail: L10n.t("Agent sessions carry a success state, so a run that has completed reads differently from one still going.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Antigravity: choose which limit leads"),
                        detail: L10n.t("The headline ring can follow a named limit rather than whichever happens to be tightest, and a CLI-only install counts as a real account.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Only the hardware notch wakes a notch joined to it"),
                        detail: L10n.t("A notch merged with the camera housing no longer wakes from a pointer anywhere along the whole top edge.")
                    ),
                ]
            ),
            ReleaseNote(
                version: "1.7.0",
                headline: L10n.t("Speaks Chinese, watches local models think, and stays welded to the edge."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("简体中文"),
                        detail: L10n.t("A Language picker in Appearance: follow the Mac, or hold the app to English or Simplified Chinese whatever the Mac is set to. Copy added since the translation was written falls back to English rather than going blank.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Ollama models show thinking and generation speed"),
                        detail: L10n.t("Each loaded model gets its own cell, with the tokens per second of its last response and a mark while it is thinking. The measurement is taken locally and nothing about a prompt leaves the machine.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Claude Code sessions started from the desktop app are counted"),
                        detail: L10n.t("A session launched from Claude for Mac now reaches the notch like any other. The sign-in also renews itself in the background, so a ring stops ageing out after a week of use.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The notch is welded to the screen edge"),
                        detail: L10n.t("No hairline of wallpaper behind it at any size, and it stays anchored while the size slider is dragged instead of drifting and catching up at the end.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Set the size by slider as well as by preset"),
                        detail: L10n.t("Three named sizes for a decision made for you, or a slider when you have a particular size in mind.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The notch folds away for a full-screen app"),
                        detail: L10n.t("Whatever is frontmost and full-screen gets the whole screen; the notch comes back when you leave it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The settings gear is a toggle"),
                        detail: L10n.t("It turns and presses in as it is clicked, and a second click closes Settings rather than doing nothing.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Cursor stops showing work that finished months ago"),
                        detail: L10n.t("Finished background agents were leaving the ring amber indefinitely. Only a real, current chat counts as waiting now.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Antigravity reads a CLI-only install"),
                        detail: L10n.t("An install with no desktop app is a real account rather than a missing one, and its daily quota is read directly.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A ready-made download, no Xcode needed"),
                        detail: L10n.t("Every build now produces an app bundle you can run, so trying Codenotch no longer starts with a developer setup.")
                    ),
                ]
            ),
            ReleaseNote(
                version: "1.6.0",
                headline: L10n.t("Reorder the rings, pick a display, and get told when a limit is close."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Drag to reorder the rings"),
                        detail: L10n.t("Settings splits into Connected and Not connected; drag a connected row by its handle to change the order the notch draws them in.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Pin the notch to one display, or show it on every one"),
                        detail: L10n.t("A Displays picker in Appearance offers the main display or all of them; a second picker pins a single notch to a named screen.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A ring says when it crosses 80% and 100%"),
                        detail: L10n.t("A system notification once per crossing, muted per provider from its own settings row.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("GitHub Copilot is a new ring"),
                        detail: L10n.t("Reads GitHub's Copilot quota endpoint using the GitHub CLI session already on the Mac.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Say when a session ends"),
                        detail: L10n.t("The notch opens itself for a few seconds and sounds a chime when an agent stops working or starts waiting on you; a click jumps to it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("⌥-drag the pill along its edge"),
                        detail: L10n.t("Nudge it clear of another menu-bar app anchored to the same spot; remembered per edge.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Choose an accent colour"),
                        detail: L10n.t("The device accent by default, or a fixed colour for the ring's positive state — the amber and red warning colours stay fixed regardless.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A countdown instead of a reset date"),
                        detail: L10n.t("Appearance's Reset time picker can show \"Resets in 3h 20m\" instead of a date and time.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Read Cursor from cursor-agent, and enterprise plans correctly"),
                        detail: L10n.t("A CLI-only Cursor login now gets a ring, and enterprise/team plans read their real usage instead of reporting nothing to meter.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Fewer keychain prompts for Claude and Antigravity"),
                        detail: L10n.t("Claude reads its own CLI's /usage first, touching the keychain only as a fallback; Antigravity's language server is asked before it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Sub-1% usage no longer reads as 0%"),
                        detail: L10n.t("A reading under one percent shows a tenth (\"<0.1%\") instead of rounding to nothing.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Contributors can build without Xcode signing"),
                        detail: L10n.t("make build and make test sign themselves automatically when the maintainer's certificate isn't present, and CI now runs the suite on every push and pull request.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.5.0",
                headline: L10n.t("Two more providers, and a live account plan that was silently dropped."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Grok is a new ring"),
                        detail: L10n.t("SuperGrok's weekly Grok Build allowance, read from the same billing endpoint the CLI uses, with the session in ~/.grok/auth.json.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("OpenCode's Go plan is a new ring"),
                        detail: L10n.t("Reads the Go plan's official usage endpoint with the key OpenCode itself stores on sign-in — no second sign-in.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A real Codex account went unmetered"),
                        detail: L10n.t("Codex's live reading only recognised a 5-hour and a 7-day window. A free-plan account's real limit was a 30-day one, which fell through unnoticed and showed as nothing metered on an account that was genuinely tracked.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Switching a provider off now really stops it"),
                        detail: L10n.t("Opening Settings could still read a switched-off provider's account, and a reply already in flight could restore a reading you had just asked it to forget.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Contributors can build without a certificate"),
                        detail: L10n.t("make build and make test now sign themselves automatically when the maintainer's Developer ID isn't present — no Apple account needed to work on this.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.4.1",
                headline: L10n.t("Waking from sleep no longer erases a reading."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("A ring survives waking your Mac"),
                        detail: L10n.t("A brief window right after sleep, where macOS won't allow a keychain prompt yet, was mistaken for being signed out — which erased the reading and left \"waiting for the first reading\" on screen. It now ages the number instead of throwing it away, and picks back up on its own.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.4.0",
                headline: L10n.t("Two more accounts, four community fixes, and honest duplicates."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Multiple Claude Code accounts"),
                        detail: L10n.t("Keep a work login apart with CLAUDE_CONFIG_DIR? It now gets its own ring, its own limits, and its own row in Settings, beside your personal one.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("GLM added"),
                        detail: L10n.t("Z.ai's Coding Plan reads live now too, with a key borrowed from whichever tool already holds one.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A stuck Claude ring recovers on its own"),
                        detail: L10n.t("One momentary failure — the Mac waking from sleep, most often — used to lock the ring until the app restarted. It now clears itself on the next check.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Cursor sessions stop reporting work that already ended"),
                        detail: L10n.t("A crashed or abandoned chat could read as \"still working\" for a day or more. It now notices when the writing has actually stopped.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A months-old duplicate can no longer win"),
                        detail: L10n.t("Claude Code files a new keychain entry on every token rotation. An account signed in for a while could pick an old, expired one at random and show \"waiting for the first reading\" forever.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A stray click no longer pins the notch open"),
                        detail: L10n.t("Clicking near the screen edge before the notch had even opened could leave it stuck open with nothing on screen explaining why.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.3.0",
                headline: L10n.t("Codex reads live, and Always show stays on."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Codex is read live instead of from a log"),
                        detail: L10n.t("The figure came from a file Codex writes during a turn, so it was as old as the last time you used it — three days stale in one case. Codenotch now asks Codex itself, and matches its own panel.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The Codex ring notices the desktop app"),
                        detail: L10n.t("It only ever watched the files the CLI and the VS Code extension write, so work done in the desktop app never made it spin.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Always show no longer turns itself off"),
                        detail: L10n.t("Clicking the notch toggled the same flag the setting used, so a stray click quietly put it back to showing on hover.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Far fewer keychain prompts"),
                        detail: L10n.t("Once a token expired, every check went back to the keychain — a prompt a minute. It now reads the secret only when the owning app has changed it, and never retries a refusal on a timer.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A paused limit is shown as paused"),
                        detail: L10n.t("Some limits are reached while the headline still shows room. The ring reads as spent and says when it lifts.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Long messages are no longer cut off"),
                        detail: L10n.t("A tooltip with something to explain reserved one line for it however much it said.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.2.0",
                headline: L10n.t("Every session, and a tooltip that fits on the screen."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Tooltips are no longer cut off"),
                        detail: L10n.t("A card is centred on the ring it belongs to, so the first and last providers threw half of it past the end of the panel — and what fell off was the title. The panel now keeps room for it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("As many sessions as your screen can hold"),
                        detail: L10n.t("The list was capped at four whatever you were running on. It is now solved for the display: ten on a large one, and \"and N more\" only when there is genuinely no room for the rest.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The ones that need you come first"),
                        detail: L10n.t("Waiting, then busy, then idle — so if anything is summarised away, it is what matters least.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.1.0",
                headline: L10n.t("Antigravity's real numbers, and a switch that stays off."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Antigravity shows its actual quota"),
                        detail: L10n.t("Google will not answer Codenotch directly, so it asks Antigravity's own language server instead — the same place Antigravity's usage panel gets its figure.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Usage reads both ways"),
                        detail: L10n.t("\"12% used · 88% left\", so a reading lines up with whichever end your vendor happens to show.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("A way back from a declined keychain prompt"),
                        detail: L10n.t("Declining no longer looks like being signed out, and Allow access… asks macOS again.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Switching a provider off now sticks"),
                        detail: L10n.t("It stopped being read but its last reading was kept, so the ring came back at the next launch.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Distant resets show a date"),
                        detail: L10n.t("A limit renewing in four weeks said \"Mon\", which read as this Monday. It says \"28 Sep\".")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.0",
                headline: L10n.t("The first release."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Put the notch anywhere"),
                        detail: L10n.t("Right, left, top or bottom. It keeps clear of the Dock and the menu bar, and follows when the Dock moves.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("It joins your Mac's own notch"),
                        detail: L10n.t("On the top edge it takes the hardware's shape, so the two read as one rather than as a bar parked underneath.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Claude, Cursor, Codex and Gemini"),
                        detail: L10n.t("Each read from the tool already signed in on this Mac. Codenotch never asks for a password.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Choose where Codenotch appears"),
                        detail: L10n.t("In the Dock, in the menu bar, or nowhere at all.")
                    )
                ]
            )
        ]
    }

    static func note(for version: String) -> ReleaseNote? {
        all.first { $0.version == version }
    }

    /// The note worth showing on this launch, if there is one.
    ///
    /// `notes` is a parameter so the rule can be tested against a fixed history
    /// rather than against whatever the app happens to ship this week.
    static func unseen(in version: String,
                       lastSeen: String?,
                       notes: [ReleaseNote] = ReleaseNotes.all) -> ReleaseNote? {
        guard lastSeen != version else { return nil }
        return notes.first { $0.version == version }
    }
}
