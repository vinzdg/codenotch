# Codenotch for Windows

A Windows port of [Codenotch](https://github.com/vinzdg/codenotch) — the usage notch that
sits on the edge of your screen and answers two questions at a glance:
**how much of my AI allowance is left**, and **is Claude still working**.

Same design language as the macOS original (inverse-rounded pill, colour-graded rings,
hover card with per-window bars), rebuilt for Windows in Rust + Tauri 2 / WebView2.
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

Settings → Appearance → Taskbar can place compact usage indicators in free space
on the left side of the primary taskbar or before the system tray. This is opt-in;
Original notch restores the screen-edge display. Hover shows account limits and
reset times, left-click requests a refresh of that account, and right-click opens
Settings. The width control adjusts the space used by the indicators.

Claude and Codex display the weekly percentage. Available 5-hour and weekly quotas
have independent arcs; a weekly-only Codex plan has one outer arc, even when the
provider calls that bucket `primary`. Claude Enterprise accounts publishing only a
spend limit display that limit. Activity is assigned only to an identified
account; unknown ownership never animates a different account's indicator.

Size, theme, warning thresholds, colour transition, remaining/used display and weekly-ring position/style
reuse the existing appearance settings. The weekly option controls an additional
ring; an account with only a weekly quota keeps its one primary ring. Floating-notch
visibility, adaptive pill, edge and screen controls are disabled in taskbar mode.
Changes apply while the app runs. Large indicators are bounded by the taskbar height
and available width. Use Outside to keep the weekly arc around the 5-hour arc.
Remaining mode reverses meter fill and numbers; warning colours still reflect used
quota. Claude indicators hide stale or expired quota arcs; details retain dated
historical readings and the last reported reset. Clicks respect the existing
five-minute attempt floor, reset-boundary exception and each account's backoff.

The strip uses an owned native child window and DirectComposition. It does not
inject code, subclass Explorer or alter its controls. UI Automation finds free
space; full screen apps, hidden taskbars or missing space hide the strip. Separate
WebView windows show the details without clipping them to the taskbar. The strip
is recreated after Explorer restarts. This relies on Explorer's internal layout;
custom shells, vertical taskbars and secondary taskbars are not supported.

## What it shows

| Cell | Source | How it reads it |
|---|---|---|
| **Claude** | `GET https://api.anthropic.com/api/oauth/usage` with the token Claude Code keeps in `~/.claude/.credentials.json` | Session / weekly windows with a five-minute request-attempt floor per account, including manual refresh. 429 back-off honours the full Retry-After (seconds or HTTP-date), with per-account deadlines persisted across restarts; stale readings dimmed with their age. Renews that token by running the standalone `claude -p` shortly before it expires (Claude Code inside the desktop app never writes this file), and never sends an expired one. A thin arc spins inside the ring while a Claude session is working, and pulses amber when one is waiting on you (Claude Code hooks + transcript watcher, desktop app included). |
| **Codex** | The local Codex sign-in in `~/.codex/auth.json` (read only, never refreshed), falling back to the newest session snapshot | Live primary/secondary windows (5h + weekly on paid plans, a monthly window on free) while Codex is signed in; Spark and Code review appear on the hover card when Codex reports them; otherwise the last snapshot, marked stale by its own timestamp. |
| **Cursor** | The editor's own session from `state.vscdb` → `cursor.com/api/usage-summary` | Included usage / API usage / on-demand, reset at billing-cycle end. Nothing to sign into: it borrows the editor's session, so there is only ever one account. |
| **Grok** | The Grok CLI's own session in `~/.grok/auth.json` (read only, never refreshed) → `cli-chat-proxy.grok.com/v1/billing?format=credits`, the endpoint that CLI's own `/usage` asks | The weekly Grok Build allowance, with the account on the hover card. Only a session minted by `auth.x.ai` is used — the file can also hold a customer IdP token meant for that customer's private proxy. A fresh weekly period reads 0 %, not "unmetered". |
| **GitHub Copilot** | The GitHub CLI's own session, read only: `GH_TOKEN`/`GITHUB_TOKEN` when set, else `oauth_token` in `%APPDATA%\GitHub CLI\hosts.yml`, else `gh auth token` run hidden (the token may live in Credential Manager) → `api.github.com/copilot_internal/user`, the quota endpoint GitHub's own editors ask | Premium requests on the ring, with chat requests and completions on the hover card; all reset on the first of the month. An `unlimited` quota, or one with no entitlement, draws nothing. The account and plan are named on the card. Sign in with `gh auth login`; Codenotch never starts a sign-in itself. |
| **OpenCode** | OpenCode's own sign-in, read only: the `opencode-go` key in `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage`, or — since OpenCode 1.18 — the OAuth sign-in in `opencode.db` (`credential` table) → `opencode.ai/inference/go/v1/usage` | The Go plan's 5-hour, weekly and monthly windows. A sign-in without a Go plan shows "No OpenCode Go subscription" instead of a ring; Zen pay-as-you-go credit has no balance or usage API, so it is not shown. Working-state and per-session model/cost come from the local `opencode.db` `session_v2` table (read-only, WAL-aware) — see OpenCode Desktop sessions below. |
| **Command Code** | The Command Code app's `~/.commandcode/auth.json` key, or `COMMAND_CODE_API_KEY`, read only; its official `/alpha` billing endpoints | GOAT plan monthly spend on the ring, with 5-hour and weekly limits on the hover card. Sign in through the Command Code app. |
| **Antigravity** | Official `agy` CLI `/usage` print when installed; otherwise the existing local `language_server` bridge, Google Cloud Code API, or transcript model count | Official four quota rows (Gemini & Claude/GPT 5h/weekly) without running the full IDE. When CLI is absent, falls back to legacy local bridge/API. |
| **OpenCode Go** | `GET https://opencode.ai/zen/go/v1/usage` | Reads the `opencode-go` key in OpenCode's `auth.json`, or `OPENCODE_APIKEY` when set. The environment key takes precedence. Shows rolling 5-hour, weekly and monthly usage. This is a separate subscription from the Z.ai GLM Coding Plan; its key must not be sent to Z.ai's monitor endpoint. |
| **Qoder** | `getUsageInfo()` on the account plane of the official [`@qoder-ai/qoder-agent-sdk`](https://docs.qoder.com/cli/sdk/overview), through the bundled `qoder-usage.cjs` sidecar, reusing the local signed-in `qodercli` session (`qodercliAuth()`) | Plan usage ring (the account's own total where the plan bucket is empty) with the renewal date (`expiresAt`), add-on and organization rows when the account carries them, credits left in the card note. The read is a documented account query: no inference is started and no credits are spent to ask. Qoder Desktop's own DPAPI vault is never opened or decrypted. |

Providers that are not installed simply do not get a cell.

### Codex quota recovery

The direct usage endpoint remains the first choice. If it fails, Codenotch can
ask an installed **native** `codex.exe` via the documented
[`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)
app-server method before falling back to a rollout snapshot. The desktop's
`%LOCALAPPDATA%\OpenAI\Codex\bin` installation is checked as well as native CLI
candidates. No `.cmd`/Node wrapper is launched. The owned process is hidden,
limited to 20 seconds, and terminated/reaped after the read; no inference or
login command is sent. Existing HTTP 429 backoff and five-minute polling remain.

The main ring/tray selects only core `primary`, never a weekly, Spark or
code-review replacement. If `primary` is absent the headline stays blank;
`secondary` remains available to the separate weekly ring. App-server
multi-bucket replies prefer `codex`. Rollout fallback ignores explicitly different
bucket ids and, like macOS, reads the latest eight non-archived paths from
`state_5.sqlite` using a read-only, WAL-aware connection (50 ms busy timeout).
This finds resumed threads without scanning every session file. If the index
is unavailable, the original three-date-directory scan remains the fallback;
old resumed threads cannot be discovered through that scan alone. Missing data is
not a zero. Percentages retain the existing **used** semantics; this is quota
utilization, not an exact token count or a model-specific allowance.

Why launch a process at all? A borrowed stored-token HTTP read can fail while
the installed Codex client can still authenticate. The native client owns its
managed OAuth lifecycle and can recover live quotas without Codenotch copying
its refresh logic. This is not guaranteed for externally managed credentials
that require a host app: if it cannot read the quota, the usual stale/missing
rollout status remains. Unlike the old unconditional wrapper-based path, this
recovery runs only after HTTP failure, directly owns a native executable, and
does not use `taskkill` or launch a Node/cmd tree. Codenotch sends no login or
explicit token-refresh request; Codex may perform its own normal managed refresh.

Regression checks: `cargo test --locked` and `node --test test-codex-headline.cjs`
from `windows/`. Tests use synthetic quota fixtures, not account credentials.
The optional `cargo test --release --locked codex::tests::live_native_quota -- --ignored`
checks the actual native transport against an already signed-in local client;
it prints no account credentials or quota values and is not run by CI.

### Reset cards

The Windows app can show a short card when any active provider — Claude,
Codex, Cursor, GLM, OpenCode, Grok, Antigravity, Qoder — renews a quota window it was
using. Each provider's own windows are watched independently and by their own
id, not by a fixed duration, so this needs no per-provider list to stay
current. Each window needs at least 10% usage before its reset counts, and a
fresh reading must confirm the change, so the card can appear on the next
poll rather than instantly. Saved, stale and first-launch readings do not
trigger a card, and a provider's own cooldown after firing keeps a jittery
reading from reporting the same reset twice.

The card uses the notch's appearance and follows its configured screen, edge,
size and theme, positioned from the notch's own measured on-screen rectangle
rather than an assumed offset — a taskbar docked to that edge, or the notch
dragged along it, cannot leave the card off by itself. It also appears when
the notch is set to **Hide**, without changing that setting. General →
Notifications has one switch for every provider's reset cards (on by
default), a switch for the notification sound, and a **Preview card** button.
When more than one window renews together, their cards appear one after the
other. The Windows app must be running to observe and show a reset.

### Claude sign-in

When Claude is signed out, its card offers **Sign in**, which opens the standalone
Claude Code CLI's browser login (`claude auth login --claudeai`). It is offered on
the default `~/.claude` account only. Settings → Accounts also provides sign-in for
named profiles, passing each profile's directory to the official CLI.
Finish in the browser; if it
displays a code, paste it in the opened terminal, not in Codenotch. The card
refreshes after the CLI exits without restarting the widget. The native CLI must
already be installed; missing CLI, cancellation and launch errors are shown.

This explicit action shares a busy guard with automatic token renewal. Only the
CLI handles OAuth and writes credentials; Codenotch does not receive login codes
or expose tokens through UI IPC. The interactive child has a 15-minute timeout.
To read Claude again, click its ring or choose **Refresh now** from the notch's
right-click menu. HTTP 403 is reported as an access/network refusal rather than claiming
that a still-valid login has expired. Existing automatic renewal is unchanged.
Manual refresh respects the five-minute per-account attempt floor and any
rate-limit deadline. A newly crossed reset boundary permits one earlier attempt;
credential renewal still runs on the existing 60-second active loop.

Browser approval is only one part of sign-in: wait for the CLI terminal to report
`Login successful`. If it reports 403 afterwards, do not interpret that as a
successful login or repeatedly delete credentials. Check the CLI error and the
network/account access used by that CLI; browser and terminal connectivity can
differ. Keep authorization codes, tokens and raw debug logs out of issue reports.

The Claude quota arcs and headline require a fresh successful reading whose
reported reset has not passed. On sign-out or a stale/error response they show
no quota arc instead of presenting a cached percentage as current. The hover
card can retain the last known values, explicitly labelled as historical, with
their last reported reset time. A successful refresh restores the live reading;
this display rule does not bypass HTTP 403 or change OAuth, polling or backoff.

### Antigravity

- **Official CLI (Preferred)**: When the official Antigravity CLI (`agy.exe`) is installed (`%LOCALAPPDATA%\agy\bin\agy.exe` or on `PATH`) and signed in, Codenotch reads official quotas directly without keeping the full IDE running.
- **Execution**: Runs the official CLI in a hidden Windows pseudo-console, with a 70-second timeout and cleanup of its process tree. It does not need PowerShell scripts or a separate service.
- **Refresh**: Checks at startup and on hover/explicit request when readings are at least five minutes old; failed attempts are also limited to once per five minutes. It keeps previous readings on failure, without switching to legacy APIs. The CLI is not launched periodically while idle.
- **Fallback**: When the official CLI is not installed, Codenotch preserves the legacy local bridge (`language_server`), Credential Manager, and transcript model turn counting to maintain compatibility with existing installations.
- **Official CLI Reference**: Standalone `/usage` printing is described in the [official Antigravity CLI documentation](https://www.antigravity.google/docs/cli/headless). Note: no categorical Terms of Service guarantee is made.

Restart Codenotch after installing or removing `agy`: the source is selected at startup.
The CLI's text report is parsed defensively; an unsupported format or failed sign-in
shows an error or the last reading marked stale. Codenotch does not automate sign-in.

### OpenCode Desktop sessions

The Go windows are remote quota figures (documented in the table above). On top of them, the
working-state engine reads the local `opencode.db` (`session_v2`, opened read-only like every
other SQLite here): a non-idle, non-archived session whose `time_updated` moved within the last
two minutes appears on the card as *working*, named by its title and detailed with its model and
recorded cost. Those are the fields OpenCode itself writes — model ids, token counts, cost.

There is no local quota data to invent: no Go/Zen percentage, reset time, credit balance or
subscription state exists in the database or the Desktop logs on a machine (checked), so those
figures stay exclusive to the documented endpoints. A *waiting on you* state is not derived either
— OpenCode's pending-permission shape is not documented, and guessing a table layout would report
sessions that are not waiting.

### Qoder

- **Official SDK sidecar**: the usage read goes through `qoder-usage.cjs`, which uses the official
  `@qoder-ai/qoder-agent-sdk` `getUsageInfo()` on the daemon account plane — a documented read-only
  account query. It starts no inference and spends no credits; a hidden `node` process runs it with
  a two-minute timeout every five minutes (or on a ring click). The daemon it spawns takes around
  18 s to initialize on a cold start, which is why the budget is generous.
- **Sign in**: the sidecar reuses the local signed-in `qodercli` session (`qodercliAuth()`), which
  the daemon borrows read-only — its `auth()` answers `false` when there is no such sign-in, and
  the cell then says *sign in to qodercli* rather than guessing from an error message. Codenotch
  never reads or decrypts Qoder Desktop's own credential vault (`auth.v1.dat`, DPAPI) — borrowing
  another product's OS-protected vault is neither safe nor supported.
- **Setup** (one-time, per machine): Node.js on `PATH` (or `CODENOTCH_QODER_NODE` pointing at it),
  then in `%APPDATA%\codenotch\qoder-sdk\`:

  ```
  copy <repo>\windows\codenotch\qoder-usage.cjs  %APPDATA%\codenotch\qoder-sdk\
  cd %APPDATA%\codenotch\qoder-sdk
  npm install @qoder-ai/qoder-agent-sdk
  npm approve-scripts @qoder-ai/qoder-agent-sdk     # or: node node_modules\@qoder-ai\qoder-agent-sdk\scripts\postinstall.cjs
  ```

  npm blocks install scripts by default, and the SDK's postinstall is what lands its runtime —
  without it the daemon never starts. Other sidecar locations are probed too: next to the exe, in
  the bundle resources, or via `CODENOTCH_QODER_SIDECAR`. Without any of them the cell shows what
  to install instead of a ring.
  To sign in, the CLI itself is needed once: re-run the postinstall with `QODER_INSTALL_BUNDLED_CLI=1`
  (it fetches a ~209 MB `qodercli.exe` into the package's `dist\_bundled`) and run `qodercli login`,
  which opens the browser. The usage read does not need that binary afterwards.
- **What it shows**: the plan window on the ring — `userQuota` when that bucket carries numbers,
  otherwise the account's own `totalUsagePercentage` (labelled *Total usage*) — with `expiresAt` as
  the renewal watched for reset cards; `addOnQuota` and `orgResourcePackage` as extra card rows when
  the account carries them; the plan type and the credits left, quoted from whichever bucket
  actually meters, in the note.
- **What it deliberately does not show**: the SDK's `session` credits block — it meters the
  sidecar's own freshly-started daemon session (≈0 by construction), not the user's IDE sessions,
  and presenting it would be an invented number. A quota the plan does not publish reads as
  "nothing to meter", never as 0 %: a standard account reports an all-zero `userQuota` while its
  consumption sits in the add-on pool, so an empty bucket is skipped rather than drawn as a full
  ring. `expiresAt` also arrives as a far-future sentinel (year 9999) on plans that do not renew;
  anything past 2100 is read as no renewal date.


## Install / build

Download [`Codenotch-Setup.exe`](https://github.com/vinzdg/codenotch/releases/latest/download/Codenotch-Setup.exe)
from the latest release. It installs for the current user without administrator rights, puts
`codenotch-hook.exe` beside the app where **Install hooks** looks for it, and fetches WebView2 if
Windows does not already have it. The installer is not code-signed, so SmartScreen stops it the
first time with *Windows protected your PC*: choose **More info**, then **Run anyway**.

### Updates

Codenotch looks for a newer release about twenty seconds after it starts, and again whenever
**Check for updates** is pressed in Settings → General. It compares the installed version with
GitHub's latest release and confirms that release carries a Windows installer. When the maintainer
has published a signed `latest.json` feed for that same version, **Update** downloads and installs
it through Tauri. Otherwise **Download installer** opens the official GitHub asset for you to run.

Nothing about this nags. A check that fails — no network or no Windows installer yet — leaves the
app as it was and says so next to the version. Before the first completed check, the page makes
no "Up to date" claim. There is no dialogue and no badge.

Automatic updates use a minisign-signed archive; Tauri checks its signature against the public
key in `tauri.conf.json` before running it. The manually downloaded installer is unsigned, so
SmartScreen may warn, as it does for a first installation.

Before the first signed release, the key has to exist:

```powershell
npx --yes @tauri-apps/cli@2.11.4 signer generate -w $env:USERPROFILE\.tauri\codenotch.key
```

Put the **private** key in the repository secret `TAURI_SIGNING_PRIVATE_KEY` and its password in
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, and paste the **public** key into `plugins.updater.pubkey`
in `codenotch/tauri.conf.json`, replacing `REPLACE_WITH_TAURI_PUBLIC_KEY`. Until that is done the
app still checks GitHub releases and offers the manual installer. The packaging job builds an
ordinary installer without a signed feed, and a `v*` release job fails to flag the missing signing
configuration to the maintainer.

Keep the private key. Losing it means no installed copy can be updated again, because every one of
them checks against the public key it shipped with — they would all have to reinstall by hand.

To build from source instead — prerequisites: Rust (MSVC toolchain), WebView2 runtime (ships with Windows 11).

```powershell
# from this directory (the repo root here; `windows/` inside the upstream repo)
cargo build --release
.\target\release\codenotch.exe          # pill appears on the right edge of the primary monitor
.\target\release\codenotch.exe doctor   # self-diagnosis: credentials, data sources, icons, hooks
```

To build the installer the way the Windows Package workflow does:

```powershell
# the hook gets its own target dir, so the bundler never copies it onto itself
cargo build --release --locked -p codenotch-hook --target-dir target/hook
cd codenotch
npx @tauri-apps/cli@2 build --config tauri.bundle.conf.json
# → ..\target\release\bundle\nsis\Codenotch_<version>_x64-setup.exe
```

### Linux

The same crate builds and runs on Linux; the Win32 pieces already sat behind `cfg(windows)`,
and the rest of the port is portable Rust. Prerequisites on a Debian or Ubuntu machine:

```sh
sudo apt install build-essential pkg-config libssl-dev libwebkit2gtk-4.1-dev \
                 libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev
cargo build --release -p codenotch
./scripts/run-linux.sh          # pill appears on the right edge
./scripts/run-linux.sh doctor   # self-diagnosis, same as on Windows
```

`scripts/run-linux.sh` exists because of two things the desktop does not do by itself.
**Wayland does not let a client place its own windows**, and the notch has to sit on a
screen edge, so it runs as an X11 client under XWayland. And a shell started from a
**snap** — Ubuntu's VS Code, for one — exports that snap's library paths, which make a
binary built against the system glibc die with
`symbol lookup error: … undefined symbol: __libc_pthread_init`. The script unsets those
and sets `GDK_BACKEND=x11`; launched from the desktop rather than such a shell, the
binary runs on its own.

The tray needs GNOME's *AppIndicator Support* extension, as every Tauri tray does there.
The data folder follows the XDG directories (`~/.config/codenotch`), and providers are
found at their Linux paths: `~/.claude`, `~/.codex`, `~/.grok`,
`~/.config/Cursor/User/globalStorage/state.vscdb`.

What does not work yet, and degrades quietly rather than misbehaving:

| Feature | Why |
|---|---|
| Dragging the pill along its edge | Follows the mouse through `GetAsyncKeyState`; needs an X11 pointer query. |
| Seen-clears-it, and jumping back to the terminal | `focus.rs` reads the foreground window and the process tree through Toolhelp; `/proc` plus a window-manager call would replace it. |
| Antigravity | Its credential is read from the Windows Credential Manager; libsecret is the equivalent. |
| App icons taken from an installed `.exe` | The built-in provider SVGs cover every provider, so little is lost. |

Everything else — all providers, the hover card, the settings window, the tray menu, hooks,
start at sign-in (an XDG autostart entry rather than a registry value) — behaves as it does
on Windows.

Tray menu: the readings themselves — a line per provider with its headline figure, and under it
one line per limit window — then **Refresh all**, **Settings…** and **Quit Codenotch**. Clicking a
provider's line re-reads that provider. Everything else is in the settings window: which rings the
notch shows, its size, the weekly ring, which screen edge it sits on and which screen,
start with Windows, the language, Claude Code hooks, reset
position, and the data folder (`%APPDATA%\codenotch` — logs, persisted readings, icon overrides).

Notch: clicking a ring re-reads that provider, as on the Mac. Right-clicking the notch or its card
offers **Refresh now**, the provider's usage page (**Open claude.ai**, **Open chatgpt.com**, …) and
**Quit Codenotch**. Neither click nor the tray bypasses Claude's five-minute
per-account attempt floor or its rate-limit wait.

### Where the notch sits

The notch pins to one edge of one screen. Six dots come out beside the settings button while the
pointer is on it: hold them (or hold Alt anywhere on the notch) and drag, and the notch follows the
pointer round the screen's border — along an edge, and round each corner — and lands where it is
let go.
**Appearance → Edge** picks left, right, top or bottom: it stands upright on the left and right
edges with the hover card opening sideways, and lies flat on the top and bottom ones with the card
opening below or above. **Appearance → Screen** appears once more than one monitor is attached.

Carried well onto another monitor, 150 px past the one it is on, the notch goes there, across a
change of DPI between them too. The choice is stored as `notch_edge`, `notch_monitor` (the device
name, e.g. `\\.\DISPLAY2`) and `notch_along` (where along each edge, 0–1) in `config.json`. A monitor that is no longer
attached falls back to the primary one, so unplugging a screen cannot strand the notch off-screen;
**Recentre** centres it on the edge it is on, or on the primary screen's right-hand edge when the screen it was on is gone.

Folded (**Appearance → Show → Show on hover**), the notch rests as a small pill at the edge, in
**Theme**'s colour, with an edge that shows even against a backdrop of that colour.
**Appearance → Adaptive pill**, off unless switched on, makes it follow what is behind it instead:
light over a dark backdrop, black over a light one, the way the iPhone's home indicator does. To tell
which, Codenotch reads a thin strip of the screen beside the pill twice a second while it is folded,
and keeps only its average brightness, which is never stored or sent. With the switch off, the notch
open, or Show set to Always show, nothing is read.

**Appearance → Fold for full-screen apps**, on unless switched off, folds the notch to its pill while
a full-screen app — a video, a game, a slideshow — is in front on its screen, whatever Show says, as
the Mac's does. Hovering the pill still opens it, and leaving the app unfolds it again. Switch on or
off, the notch moves to the screen's very edge meanwhile, into the room the taskbar has made for the
app, and back when the taskbar returns.

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
├── codenotch/          the Windows app (pill, hover card, settings, providers)
└── codenotch-hook/     tiny helper Claude Code calls to report session events
```

A pull request that touches this tree is built and tested; the check is skipped
inside forks until the pull request is opened here.

## Relationship to upstream

This port follows the upstream design and provider semantics. It is developed at
[Im-Midi/codenotch-windows](https://github.com/Im-Midi/codenotch-windows) and offered to the
upstream project as its `windows/` tree; the two are kept in sync. Session detection
originated in [Im-Midi/Pac-Man](https://github.com/Im-Midi/Pac-Man) (MIT).

## License

MIT — see `LICENSE`. The Codenotch design and name belong to the upstream author.
