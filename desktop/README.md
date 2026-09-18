# Codenotch desktop (Windows and Linux)

The shared Rust/Tauri 2 crate for [Codenotch](https://github.com/vinzdg/codenotch) —
the usage notch that sits on the edge of your screen and answers two questions at a
glance: **how much of my AI allowance is left**, and **is Claude still working**.

Windows and Linux are front doors, not copies of this tree:

- [`windows/`](../windows/README.md) — installer and Windows build notes
- [`linux/`](../linux/README.md) — Mint / Cinnamon / X11, deps, and how to run

OS-specific helpers live in `codenotch/src/platform/` (`windows.rs` / `linux.rs`)
so providers stay unaware of the host. Same design language as the macOS original
(inverse-rounded pill, colour-graded rings, hover card with per-window bars).
No code is copied from the Swift app; the providers are reimplemented from their
documented behaviour and the wire formats.

## Claude accounts

Settings → Accounts lists every Claude account as a provider row of its own, as the Mac
does: `~/.claude` and each `~/.claude-<slug>` Claude Code has signed in to. A row is named
from its sign-in (Claude Gmail, Claude Acme), from its folder until it has one
(Claude (work)), and is plain Claude when it is the only account. A folder Claude Code
has not signed in to is not an account. Add a Claude account creates the next
`~/.claude-<n>` folder and opens the official Claude Code CLI sign-in in it, counting
down five minutes; a sign-in that does not finish removes the folder again. The
standalone CLI must be installed. Switching a row off stops reading that
account and keeps its sign-in. Authentication, cached readings and retry deadlines stay
separate, including after rate limiting or reconnection.

## Taskbar display

Settings → Appearance → Taskbar can place the notch's rings in free space on the
left side of the primary taskbar or before the system tray. This is opt-in;
Original notch restores the screen-edge display. Hover shows account limits and
reset times, left-click requests a refresh of that account, and right-click opens
Settings.

Each cell is a notch cell turned on its side: the same ring, reading, weekly ring,
activity arc and glyph, drawn in the notch's 56-unit box, with the notch's figure
beside the ring instead of under it. Every provider the notch shows is there, in the
notch's order, reading the same window. The strip is as wide as its cells; when the
free space is narrower, the whole row shrinks rather than dropping an account.

Size, theme, warning thresholds, colour transition, remaining/used display and weekly-ring position/style
reuse the existing appearance settings. Floating-notch visibility, adaptive pill,
edge and screen controls are disabled in taskbar mode. Changes apply while the app
runs. Large indicators are bounded by the taskbar height. Claude indicators hide
stale or expired quota arcs, as the notch does; details retain dated historical
readings and the last reported reset. Clicks respect the existing five-minute
attempt floor, reset-boundary exception and each account's backoff.

The strip uses an owned native child window and DirectComposition. It does not
inject code, subclass Explorer or alter its controls. UI Automation finds free
space; full screen apps, hidden taskbars or missing space hide the strip. Separate
WebView windows show the details without clipping them to the taskbar. The strip
is recreated after Explorer restarts. This relies on Explorer's internal layout;
custom shells, vertical taskbars and secondary taskbars are not supported.

## What it shows

| Cell | Source | How it reads it |
|---|---|---|
| **Claude** | `GET https://api.anthropic.com/api/oauth/usage` with the token Claude Code keeps in `~/.claude/.credentials.json` | Session / weekly windows, 429 back-off with a persisted deadline, stale readings dimmed with their age. Renews that token by running the standalone `claude -p` shortly before it expires (Claude Code inside the desktop app never writes this file), and never sends an expired one. A thin arc spins inside the ring while a Claude session is working, and pulses amber when one is waiting on you (Claude Code hooks + transcript watcher, desktop app included). |
| **Codex** | The local Codex sign-in in `~/.codex/auth.json` (read only, never refreshed), falling back to the newest session snapshot | Live primary/secondary windows (5h + weekly on paid plans, a monthly window on free) while Codex is signed in; Spark and Code review appear on the hover card when Codex reports them; otherwise the last snapshot, marked stale by its own timestamp. |
| **Cursor** | The editor's own session from `state.vscdb` → `cursor.com/api/usage-summary` | Included usage / API usage / on-demand, reset at billing-cycle end. Nothing to sign into: it borrows the editor's session, so there is only ever one account. |
| **Grok** | The Grok CLI's own session in `~/.grok/auth.json` (read only, never refreshed) → `cli-chat-proxy.grok.com/v1/billing?format=credits`, the endpoint that CLI's own `/usage` asks | The weekly Grok Build allowance, with the account on the hover card. Only a session minted by `auth.x.ai` is used — the file can also hold a customer IdP token meant for that customer's private proxy. A fresh weekly period reads 0 %, not "unmetered". |
| **Antigravity** | Official `agy` CLI `/usage` print when installed; otherwise the existing local `language_server` bridge, Google Cloud Code API, or transcript model count | Official four quota rows (Gemini & Claude/GPT 5h/weekly) without running the full IDE. When CLI is absent, falls back to legacy local bridge/API. |

Providers that are not installed simply do not get a cell.

### Antigravity

- **Official CLI (Preferred)**: When the official Antigravity CLI (`agy.exe`) is installed (`%LOCALAPPDATA%\agy\bin\agy.exe` or on `PATH`) and signed in, Codenotch reads official quotas directly without keeping the full IDE running.
- **Execution**: Runs the official CLI in a hidden Windows pseudo-console, with a 70-second timeout and cleanup of its process tree. It does not need PowerShell scripts or a separate service.
- **Refresh**: Checks at startup and on hover/explicit request when readings are at least five minutes old; failed attempts are also limited to once per five minutes. It keeps previous readings on failure, without switching to legacy APIs. The CLI is not launched periodically while idle.
- **Fallback**: When the official CLI is not installed, Codenotch preserves the legacy local bridge (`language_server`), Credential Manager, and transcript model turn counting to maintain compatibility with existing installations.
- **Official CLI Reference**: Standalone `/usage` printing is described in the [official Antigravity CLI documentation](https://www.antigravity.google/docs/cli/headless). Note: no categorical Terms of Service guarantee is made.

Restart Codenotch after installing or removing `agy`: the source is selected at startup.
The CLI's text report is parsed defensively; an unsupported format or failed sign-in
shows an error or the last reading marked stale. Codenotch does not automate sign-in.

## Install / build

Download [`Codenotch-Setup.exe`](https://github.com/vinzdg/codenotch/releases/latest/download/Codenotch-Setup.exe)
from the latest release. It installs for the current user without administrator rights, puts
`codenotch-hook.exe` beside the app where **Install hooks** looks for it, and fetches WebView2 if
Windows does not already have it. The installer is not code-signed, so SmartScreen stops it the
first time with *Windows protected your PC*: choose **More info**, then **Run anyway**.

To build from source instead — prerequisites: Rust (MSVC toolchain), WebView2 runtime (ships with Windows 11).

```powershell
# from this directory (`desktop/` in the upstream repo)
cargo build --release
.\target\release\codenotch.exe          # pill appears on the right edge of the primary monitor
.\target\release\codenotch.exe doctor   # self-diagnosis: credentials, data sources, icons, hooks
```

On Linux, see [`../linux/README.md`](../linux/README.md); `../linux/run.sh` is the same
`cargo run --release` from here.

To build the installer the way the Windows Package workflow does:

```powershell
# the hook gets its own target dir, so the bundler never copies it onto itself
cargo build --release --locked -p codenotch-hook --target-dir target/hook
cd codenotch
npx @tauri-apps/cli@2 build --config tauri.bundle.conf.json
# → ..\target\release\bundle\nsis\Codenotch_<version>_x64-setup.exe
```

Tray menu: the readings themselves — a line per provider with its headline figure, and under it
one line per limit window — then **Refresh all**, **Settings…** and **Quit Codenotch**. Clicking a
provider's line re-reads that provider. Everything else is in the settings window: which rings the
notch shows, its size, the weekly ring, which screen edge it sits on and which screen,
start with Windows, the language, Claude Code hooks, reset
position, and the data folder (`%APPDATA%\codenotch` — logs, persisted readings, icon overrides).

Notch: clicking a ring re-reads that provider, as on the Mac. Right-clicking the notch or its card
offers **Refresh now**, the provider's usage page (**Open claude.ai**, **Open chatgpt.com**, …) and
**Quit Codenotch**. Neither click, nor the tray, asks Claude again while its rate-limit wait runs.

### Where the notch sits

The notch pins to one edge of one screen. Six dots come out beside the settings button while the
pointer is on it: hold them (or hold Alt anywhere on the notch) and drag. On Windows the notch
follows the pointer round the screen's border — along an edge, and round each corner — and lands
where it is let go. On Linux the same two gestures slide the notch along the edge it is already
on and never hop to another side; the button state is an X11 pointer query, and the carry overlay
is not used.
**Appearance → Edge** picks left, right, top or bottom: it stands upright on the left and right
edges with the hover card opening sideways, and lies flat on the top and bottom ones with the card
opening below or above. **Appearance → Screen** appears once more than one monitor is attached.

Carried well onto another monitor, 150 px past the one it is on, the notch goes there, across a
change of DPI between them too. The choice is stored as `notch_edge`, `notch_monitor` (the device
name, e.g. `\\.\DISPLAY2`) and `notch_along` (where along each edge, 0–1) in `config.json`. A monitor that is no longer
attached falls back to the primary one, so unplugging a screen cannot strand the notch off-screen;
**Recentre** centres it on the edge it is on, or on the platform default (the right edge on Windows,
the top edge on Linux) when the screen it was on is gone.

On Linux, `scripts/run-linux.sh` (and [`../linux/run.sh`](../linux/README.md)) sets
`GDK_BACKEND=x11` and drops library paths a snap shell exports: Wayland will not let the notch
place its own window, and those paths make a binary built against the system glibc fail before
`main`. Launched from the desktop, the binary runs on its own. Autostart is an XDG desktop entry.
These still degrade quietly: seen-clears-it and jumping back to the terminal (`focus.rs` reads the
foreground window through Toolhelp), Antigravity's credential (Windows Credential Manager;
libsecret is the equivalent), and app icons taken from an installed `.exe` (the built-in provider
SVGs cover every provider).

### Icons

Provider marks are the SVGs from [`@lobehub/icons-static-svg`](https://github.com/lobehub/lobe-icons)
(MIT), embedded unmodified — see `codenotch/glyphs/NOTICE.md`. Drop your own
`claude|codex|cursor|gemini.svg` (or `.png`) into `%APPDATA%\codenotch\glyphs\` to override.
The marks remain the trademarks of their owners.

### Translations

Three surfaces draw their own text, so each keeps its own table:

| Surface | Table | Languages today |
|---|---|---|
| Tray menu | `codenotch/src/i18n.rs` (`tr`), `codenotch/src/traymenu.rs` (`label`) | en · ru · zh · ja · ko · uk · es |
| Hover card | `codenotch/ui/notch.html` (`TEXT`, `PATTERNS`, `UI`) | en · ru · zh · es |
| Settings window | `codenotch/ui/settings.html` (`STATIC_TEXT`, `STATUS_TEXT`) | en · ru · zh · ja · ko · es |

Help is welcome on the gaps, which fall back to English rather than breaking anything:

- the hover card has no Japanese, Korean or Ukrainian;
- the settings window has no Ukrainian, although the tray menu and the language picker have had it
  since Ukrainian was added;
- Korean has none of the window names the Mac's catalog carries — `Current session`, `Weekly limit`,
  `Monthly limit`, `5-hour Limit`, `Included usage`, `API usage` — because the catalog has no Korean
  to take them from.

Keys are the exact English string. A string the Mac also shows should be taken from
`Sources/Localizable.xcstrings` rather than translated afresh, so both platforms word it the same
way. One catalog feeding all three tables is the intended fix; until then a test in `traymenu.rs`
fails if the menu and the card stop naming the same window.

## Layout

```
.
├── codenotch/          the desktop app (pill, hover card, settings, providers)
│   └── src/platform/   Windows vs Linux: paths, autostart, pointer, default edge
└── codenotch-hook/     tiny helper Claude Code calls to report session events
```

A pull request that touches this tree is built and tested; the check is skipped
inside forks until the pull request is opened here.

## Relationship to upstream

This port follows the upstream design and provider semantics. The Windows side
originated at [Im-Midi/codenotch-windows](https://github.com/Im-Midi/codenotch-windows)
and is offered here as `desktop/` with `windows/` and `linux/` as front doors.
Session detection originated in [Im-Midi/Pac-Man](https://github.com/Im-Midi/Pac-Man) (MIT).

## License

MIT — see `LICENSE`. The Codenotch design and name belong to the upstream author.
