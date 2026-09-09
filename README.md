<div align="center">

![Codenotch](docs/design/codenotch-banner.png)

[![CI](https://github.com/vinzdg/codenotch/actions/workflows/ci.yml/badge.svg)](https://github.com/vinzdg/codenotch/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black)
![Swift](https://img.shields.io/badge/swift-5-orange)
![License](https://img.shields.io/badge/license-MIT-green)

**A macOS app that pins a small black notch to a screen edge, showing how much
of each coding assistant's usage limit you have burned — and whether it is
still working, done, or waiting on you.**

![Collapsed notch with hover tooltip](docs/design/frame-124-hover-tooltip.png)

</div>

Hover a ring for its limit windows and when they reset. Claude's ring shows the
same **current session** window Claude Code's own `/usage` leads with, so the
two never disagree.

## Download

[**Latest release**](../../releases/latest) — signed, notarized, and updating
itself from then on. Take this one unless you have a reason not to.

To try unreleased `main` without an Xcode install, the [preview
build](../../releases/tag/preview) is rebuilt from every commit, and the
Package workflow keeps a per-commit disk image on each of its
[runs](../../actions/workflows/package.yml). Neither is notarized — they are
ad-hoc signed, because the Developer ID certificate exists on one machine — so
macOS quarantines the download. Clear the flag once, after dragging the app to
Applications:

```sh
xattr -dr com.apple.quarantine /Applications/Codenotch.app
```

If macOS says the app is *damaged*, that is the quarantine flag rather than a bad download — run the command above.

Universal binary. macOS 15 or later. To build and install a copy from source
instead, see [Building](#building).

## Windows

A Windows port — Rust/Tauri 2, same design and providers — lives in [`windows/`](windows/README.md).

## Linux (Arch, experimental)

The Rust/Tauri port under `windows/` is also the Linux codebase. It compiles on
Arch Linux. In Wayland sessions Codenotch automatically uses XWayland (when
`DISPLAY` is available), because edge pinning requires global window
coordinates that native Wayland intentionally does not expose. Set
`CODENOTCH_NATIVE_WAYLAND=1` to opt out, with the caveat that the compositor may
ignore the requested position.

Install the Tauri system dependencies, Rust and `just`:

```sh
sudo pacman -Syu
sudo pacman -S --needed \
  base-devel rustup just webkit2gtk-4.1 curl wget file openssl \
  appmenu-gtk-module libayatana-appindicator librsvg xdotool lsof
rustup default stable
```

The package list follows the official
[Tauri 2 Linux prerequisites](https://v2.tauri.app/start/prerequisites/).

Initialize the project, then choose one of the two Arch build recipes:

```sh
just setup
just arch build       # debug: windows/target/debug/{codenotch,codenotch-hook}
just arch release     # optimized: windows/target/release/{codenotch,codenotch-hook}
```

For a manual system-wide installation, build the release and install both
binaries together so the Claude hook can find the main application:

```sh
just arch release
sudo install -Dm755 windows/target/release/codenotch /usr/local/bin/codenotch
sudo install -Dm755 windows/target/release/codenotch-hook /usr/local/bin/codenotch-hook
codenotch doctor
codenotch
```

To remove this manual installation:

```sh
sudo rm -f /usr/local/bin/codenotch /usr/local/bin/codenotch-hook
```

This is currently a binary-only installation: it does not install a desktop
entry, autostart file or pacman package. Those belong to the Linux packaging
milestone described in
[`docs/plans/2026-09-09-linux-arch-installation-plan.md`](docs/plans/2026-09-09-linux-arch-installation-plan.md).

### Notch controls

When unpinned, Codenotch rests as a small black bar on the configured screen
edge. Hover over it to reveal the provider rings and usage card. Right-click
the bar or the expanded notch to change its screen side, vertical position,
size, visible providers, or to pin the full notch in place. These choices are
saved in `~/.config/codenotch/config.json` on Linux.

## What it reads

| Provider | Source | How |
|---|---|---|
| **Claude Code** | official | Claude Code's own `/usage`, asked of the installed `claude`. Falls back to the OAuth token in the login keychain, against the endpoint that command uses, when Claude Code isn't installed. |
| **Cursor** | official | The editor's signed-in session in its local SQLite state, or the `cursor-agent` login in the keychain — no separate sign-in. |
| **Codex** | official | ChatGPT's usage endpoint, using the local Codex sign-in. Shows the 5-hour and weekly limits when available. |
| **Antigravity** | official where licensed, otherwise a request count | Antigravity's local language server first, then Google's quota endpoint; a plain count when neither will answer for the account. |
| **GLM** | official | Z.ai's Coding Plan monitor endpoint, with a key borrowed from whichever coding tool already holds one — Claude Code's `settings.json`, ZCode, or OpenCode. |
| **Ollama (Local)** | local runtime | Automatically detected local models, RAM/VRAM, unload time and context. Optional response capture adds thinking and generation speed. |
| **Grok** | official | The Grok CLI session in `~/.grok/auth.json`, against the same credits billing endpoint `/usage` uses. |
| **OpenCode** | official | The Go plan's official usage endpoint, with the `opencode-go` key OpenCode itself stores on sign-in. |
| **Command Code** | official | The GOAT plan's `/alpha` billing endpoints, with the key the Command Code app writes to `~/.commandcode/auth.json`. |
| **GitHub Copilot** | official | GitHub's Copilot quota endpoint, authenticated with the GitHub CLI session already on the Mac (`gh auth login`). |

Most providers borrow a credential or session from a tool already on your Mac.
Ollama Cloud accepts an API key in Settings. Switching a provider off stops its
usage polling and forgets its readings; borrowed accounts stay signed in to
the tools that own them.

**Local Ollama is detected automatically.** Configure its address or stop monitoring in **Settings → Ollama**.
Each loaded model gets a notch cell; reorder or hide it in **Settings → Accounts**.
Hover for RAM/VRAM, unload time, context limit and quantization.

For generation speed (**tok/s**) and live **Thinking**, enable **Measure speed and thinking**
in Settings → Ollama, keep Codenotch open and connect through its local relay:

```sh
OLLAMA_HOST=http://127.0.0.1:11435 ollama run gemma4:e4b --think
```

Speed updates after completed native Ollama responses; thinking requires streamed
reasoning. Direct requests to Ollama's default port (`11434`) only provide model
detection. Monitoring never initiates inference or saves prompts, reasoning or replies.
See [Ollama details](docs/plans/2026-09-07-local-llm-provider-plan.md).

Settings lists the connected providers in the order the notch draws them, and
you can drag one by its handle to move it. The order is remembered across
launches. A provider you switch back on joins the end of that list rather than
reclaiming an older position, so nothing you cannot currently see jumps ahead
of something you placed deliberately.

It also answers **"is it still working?"** — a thin arc spins inside a
provider's ring while a session is busy, and becomes a pulsing amber ring when
one is blocked waiting on you. Hover for every live session by name, where it
is running, and what it wants.

Two Claude Code logins are two rings. Anyone who keeps a work account apart with
`CLAUDE_CONFIG_DIR=~/.claude-work claude` gets a **Claude (work)** ring beside the
personal one, with its own limits, its own sessions and its own row in Settings.
Any `~/.claude-<slug>` directory Claude Code has run against is found at launch;
the default `~/.claude` always comes first, the rest in alphabetical order, so the
rings never swap places.

Codex accounts work the same way: `~/.codex` stays the **Codex** ring, and each
used `~/.codex-<slug>` directory adds a **Codex (slug)** ring with its own limits,
activity and Settings row. Profiles are discovered at launch, default first,
then alphabetically. To connect a second account, sign in through Codex CLI
using a separate home directory:

```sh
mkdir -p "$HOME/.codex-work"
CODEX_HOME="$HOME/.codex-work" codex -c 'cli_auth_credentials_store="file"' login
```

Choose the second account during sign-in, then restart Codenotch. Run that
account's CLI sessions with `CODEX_HOME="$HOME/.codex-work" codex` as well.
Repeat with another name, such as `.codex-personal`, for more accounts.
Settings shows each account's email and profile directory; each ring can be
reordered or switched off independently. Switching one off forgets only its
Codenotch readings and leaves the Codex login intact.

Codenotch reads each profile's `auth.json`; keychain-only or API-key-only
logins cannot provide these ChatGPT account limits. It never copies, refreshes
or writes Codex credentials. If a login expires, use that profile's Codex CLI
to renew it. Directories outside the `~/.codex-<slug>` convention are not
discovered automatically, and adding a profile requires restarting Codenotch,
just as it does for Claude.

## When a session ends

The notch opens itself for five seconds when an agent stops working, or stops
to ask you something, and sounds the system alert. Clicking it while it is open
brings that session's application to the front.

The app, not the tab. A session publishes its pid and nothing else — no window,
no tab, no tty — so the app is found by walking up the process tree from the
agent to whatever launched it. Choosing the *tab* inside that app needs the
terminal's own scripting interface, and there is no general one: Terminal.app
and iTerm2 can match a tab by tty, Warp and Ghostty publish no scripting
dictionary at all. So the app is raised for everybody and the tooltip names the
session, which leaves the last hop one keystroke rather than working for two
terminals and silently doing nothing in a third.

Both halves switch off separately in Settings, because they fail differently:
the peek is no use behind a full-screen window, and the sound is no use in a
meeting. Each of the two events — finished, and waiting on you — picks its own
sound there, with a preview button beside it.

The sound is played as a file on the ordinary output rather than handed to
`NSSound` as a system alert. A system alert goes through the interface
sound-effects channel, which System Settings → Sound can switch off — and on a
Mac where it is off, `NSSound.play()` reports success and nothing is heard.

Only *leaving* busy counts. A question being answered is not a piece of work
ending, and a session whose file disappears mid-turn — which is what quitting
Claude Code looks like — is not announced at all, since there is no window left
to jump to. Nothing is announced from the first reading either: every session
already running at launch arrives with no history, and treating that as a
transition would ring once per open window on every start.

## Alerts

A provider's headline limit crossing **80%** — and reaching **100%** —
becomes a system notification: once per crossing, never repeated while it
stays crossed, and again only after the window has genuinely rolled over.
Each provider can be muted from its own row in Settings, and macOS permission
is asked on the first real alert rather than at launch.

## Placement

The notch lives on any of the four screen edges. Right and left keep a
vertical column; top and bottom lay the readings out side by side. It pins
itself to the physical screen edge, so showing or hiding the Dock does not
move it. Hold Option and drag to move along the selected edge; each edge
remembers its position. On a Mac with a hardware notch, the top
placement takes its exact shape, so the two read as one rather than as a bar
parked underneath it.

Along that edge it sits wherever you put it: hold ⌥ and drag the notch to
slide it, and each edge remembers where you left it, so moving the notch to the
top and back does not lose the place you chose on the right. **Recentre** in
Settings → Appearance puts the current edge back in the middle.

**Size** in the same place draws the whole notch — rings, text, tooltip and all
— smaller or larger. Medium is the size it was designed at.

At rest it is a small pill on the screen edge that unfolds when the pointer
reaches it — configurable in Settings to always show, or to hide entirely.
Settings live in an orb below the notch: an arc at rest, a gear on hover.

In Settings → Appearance → Reset time, choose **Time remaining** for countdowns
like "Resets in 3 Days 3h". **Reset date** keeps the reset date and time, with
minutes shown when less than an hour remains.

Appearance also carries the ring's accent colour. The device accent is the
default; fixed presets are available for pink, red, orange, yellow, green,
teal, blue, indigo, purple and off-white.

The app itself can show a Dock icon, a menu bar icon, or neither.

## Updates

Codenotch updates itself. [Sparkle](https://sparkle-project.org) checks daily
and installs in the background without prompting; Settings says so and can
switch it off. Every update is EdDSA-signed, so nothing installs that wasn't
built and signed by the maintainer.

## Building

```sh
brew install xcodegen   # once
make run                # generate, build, launch a Debug build
make test               # unit tests
```

No signing identity is required for either. `make release` — which archives,
notarizes, and produces a signed auto-update feed — needs a Developer ID
certificate and an App Store Connect notary profile, and is only ever run by
the maintainer to cut an official release. See
[CONTRIBUTING.md](CONTRIBUTING.md). CI runs the same unit tests unsigned via
`make test-ci`.

A Debug build is ad-hoc signed, which means it has no stable code identity, so
macOS cannot match it to a saved keychain "Always Allow" — the prompt to read a
tool's token returns on every launch. To make the grant stick during local
development, sign the built app with a stable self-signed identity:

```sh
Scripts/sign-local.sh   # signs /Applications/Codenotch.app (pass a path to override)
```

It creates a reusable `Codenotch Local Signing` certificate in your login
keychain (no Apple Developer account needed) and re-signs the app. Grant the
keychain prompt once more after signing; it will not ask again.

Run with `CODENOTCH_DEMO=1` to see fixed sample data instead of live readings.

## Architecture

Every provider implements `UsageProvider` (`Sources/Providers/`) and declares
its own `Fidelity` — `.official`, `.derived`, or `.manual` — so the UI never
presents a guess as if a vendor had published it. `UsageStore`
(`Sources/Model/`) polls them on a timer, keeps the last good reading across
launches, and degrades every failure to a visible status rather than a
made-up percentage.

The notch itself works in one-dimensional **stack space** (`along`/`across`)
regardless of which screen edge it's on; `NotchPlacement` is the only place
that maps that back onto real screen coordinates. `NotchLayout` holds every
measurement, quoted from `docs/design/frame-124-hover-tooltip.png` so the
layout can be checked against the design frame directly.

- Design spec: [`docs/specs/2026-08-28-usage-notch-design.md`](docs/specs/2026-08-28-usage-notch-design.md)
- Implementation history: [`TASKS.md`](TASKS.md)

## The honest caveat

No vendor publishes a clean "your session limit is N% used" API for any of
these tools. Each adapter reads whatever the owning app itself reads from —
an internal endpoint, a local database, a language server's own RPC — and
those can change without notice. Every adapter's response shape is pinned by
tests, and every failure degrades to a visible status (`stale`, `needsAuth`,
`error`) rather than an invented number.

**Keychain:** Claude's readings do not use it where Claude Code is installed.
Claude Code files a *new* keychain item on every token rotation, and the new
item's access list does not carry this app, so an "Always Allow" granted
against the old one stops working about an hour later — asking `claude` itself
avoids the question entirely. Where the keychain is still the source (no
Claude Code on the machine, or Antigravity), the app is signed with a stable
Developer ID identity so a grant survives rebuilds, and the secret is read
only when the owning app has actually changed it — checked via the item's
modification date, which isn't behind the same access prompt as the
credential — so a valid grant does not mean a prompt on every poll.

**Rate limits:** Claude's endpoint returns 429 if polled too hard, with an
unhelpful `Retry-After: 0`. The back-off treats that as a floor-raiser only —
60s, doubling per consecutive 429, capped at 15 minutes — and the deadline is
persisted, so relaunching during a penalty waits instead of spending an
attempt on it. Polling drops to every 5 minutes when nothing is running, and
right-clicking the notch offers **Refresh now**.

**Logs:** the app has no window, so anything worth diagnosing goes to the
unified log.

```sh
/usr/bin/log stream --predicate 'subsystem == "com.vinz.codenotch"' --level debug
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Vinz
