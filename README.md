<div align="center">

![Codenotch](docs/design/codenotch-banner.png)

[![CI](https://github.com/vinzdg/codenotch/actions/workflows/ci.yml/badge.svg)](https://github.com/vinzdg/codenotch/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS%2014.3%2B-black)
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

This is a personal fork of Codenotch, and it does not publish releases. A
build is produced by the [Package workflow](../../actions/workflows/package.yml):
open its latest run on the branch you want and download the
`Codenotch-<version>-<commit>` artifact. It holds one
`Codenotch-<version>-adhoc-universal.zip` and its `.sha256`; compare the two
before opening anything.

The build is ad-hoc signed rather than notarized, because there is no
Developer ID certificate behind this fork, so macOS quarantines the download.
Unzip it, drag the app to Applications, and clear the flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Codenotch.app
```

If macOS says the app is *damaged*, that is the quarantine flag rather than a bad download — run the command above.

Universal binary. macOS 14.3 or later. On macOS 26 it draws upstream's own
Liquid Glass; on macOS 15 it keeps the rest of upstream's native behaviour but
falls back to a material where the glass would be, because Liquid Glass starts
at 26; below that the same material fills in. To build and install a copy from
source instead, see [Building](#building).

## Windows

[![Download for Windows](docs/design/download-windows.svg)](../../releases/latest/download/Codenotch-Setup.exe)

A Windows port — Rust/Tauri 2, same design and providers — lives in [`windows/`](windows/README.md).
The button is the installer itself, named `Codenotch-Setup.exe` in every release for the same
reason the dmg keeps one name. It installs for the current user without administrator rights,
and fetches WebView2 if Windows does not already have it.

The installer is not code-signed, so the first time it runs SmartScreen says *Windows protected
your PC*. Choose **More info**, then **Run anyway**. Every Windows change also leaves an
installer on its [Windows Package run](../../actions/workflows/windows-package.yml).

## Connect your phone

The Codenotch phone app (iOS and Android) can show the same usage
percentages, reset times and session states as the notch on your Mac.
It reads only what the notch already displays — never tokens, credentials
or raw API responses.

To pair, open **Settings › Phone › Connect a Phone…** (or the menu item)
on your Mac. A QR code appears with a five-minute countdown; scan it with
the Codenotch phone app, or copy the link and paste it into the app. The
Mac and phone must be on the same Wi-Fi network — the server answers only
local-network addresses and rejects anything routed over the internet.

Each code is single-use and expires after five minutes. Reopening the
window always mints a fresh one.

To remove a paired phone, open **Settings › Phone**, find the device in
the list and click **Remove**. Its credentials are deleted immediately and
any subsequent request from that phone is rejected.

See [docs/phone-link-protocol.md](docs/phone-link-protocol.md) for the
wire-level details.

## What it reads

| Provider | Source | How |
|---|---|---|
| **Claude Code** | official | Claude Desktop's own cached usage response, where Desktop is running and signed into the same account. Then Claude Code's own `/usage`, asked of the installed `claude`. Then the OAuth token in the login keychain, against the endpoint that command uses. |
| **Cursor** | official | The editor's signed-in session in its local SQLite state, or the `cursor-agent` login in the keychain — no separate sign-in. |
| **Codex** | official | Using the local Codex sign-in. Shows the 5-hour and weekly limits when available, plus extra limit windows when the account has them. |
| **DeepSeek Platform** | derived from official Platform responses | Explicit sign-in in Codenotch's own WKWebView, then the Platform account summary and API-key/model usage endpoints. Shows funded/spent balance, 30-day tokens/cost, requests and API-key count. |
| **DeepSeek Harness** | official API balance + local session transcripts | Queries `GET https://api.deepseek.com/user/balance` with `DEEPSEEK_API_KEY` from `~/.dsh/.credentials.yaml` and sums cumulative transcripts in `~/.dsh/sessions`. Shows prepaid credit usage (`Credits`), scaling funded balance dynamically above `$2.00` USD and reporting 100% used when credits are depleted. Configurable note format (`remaining`, `spent`, `compact`) in Settings. See [DeepSeek Harness details](docs/providers/deepseek-harness.md). |
| **Antigravity** | official where licensed, otherwise a request count | Antigravity's local language server first, then Google's quota endpoint; a plain count when neither will answer for the account. |
| **GLM** | official | Z.ai's Coding Plan monitor endpoint, with a key borrowed from whichever coding tool already holds one — Claude Code's `settings.json`, ZCode, or OpenCode. |
| **MiniMax** | official where a Coding Plan key is used, derived from official Platform responses for the in-app sign-in | A Coding Plan key pasted in Settings, or explicit sign-in in Codenotch's own WKWebView. |
| **QianwenAI** | derived from official console responses | Explicit sign-in in Codenotch's own WKWebView, then the console's own Token Plan gateway. Shows the plan's credits window for whichever period the console reports — weekly or monthly. |
| **XyToken** | derived from the relay station's own responses | Explicit sign-in in Codenotch's own WKWebView, then the station's wallet call: `POST /api/user/auth/refresh` against the HttpOnly cookie, then `GET /api/subscription/self` with the short-lived bearer token it returns. Shows the daily window and the weekly arc, with reset times and usage pace. Administrator accounts that require a second factor are treated as waiting for the code, not signed out. |
| **Ollama (Local)** | local runtime | Automatically detected local models, RAM/VRAM, unload time and context. Optional response capture adds thinking and generation speed. |
| **LM Studio** | local runtime | Loaded models from LM Studio's own listing, what each one is doing (prompt, generating, queue) from its SDK socket, and speed, context use and tokens per day from its server log. No relay needed. |
| **oMLX** | local runtime | Loaded models from oMLX's own status listing, what each one is doing (prompt, generating, queue) from its admin activity endpoint, and speed and tokens from `~/.omlx/logs/server.log`. |
| **Grok** | official | The Grok CLI session in `~/.grok/auth.json`, against the same credits billing endpoint `/usage` uses. Once that session has expired it is renewed in memory from the file's own refresh token, the way the CLI would; the file itself is never written. |
| **OpenCode** | official | The Go plan's official usage endpoint, called with the `oc_sk_` console key OpenCode stores at `auth.json` `"opencode"` when that key is present. A leftover `opencode-go` `sk-` key is not used in that case. |
| **Command Code** | official | The GOAT plan's `/alpha` billing endpoints, with the key the Command Code app writes to `~/.commandcode/auth.json`. Further accounts are read from `~/.commandcode-<slug>` homes. |
| **GitHub Copilot** | official | GitHub's Copilot quota endpoint, authenticated with the GitHub CLI session already on the Mac (`gh auth login`). |
| **Kimi** | official | The Kimi Code CLI session in `~/.kimi-code/credentials/kimi-code.json`, against the same `/usages` endpoint the CLI's `/usage` asks. Shows the 5-hour rate window and the weekly or monthly quotas available on the account. |
| **Kiro** | official | The kiro-cli session already on this Mac, against the same `/usage` that command prints. Shows monthly credits. |
| **Amp** | official subscription percentages; derived free-allowance percentage | The Amp CLI login in `~/.local/share/amp/secrets.json`, against Amp's `userDisplayBalanceInfo` endpoint. Shows Agent and Orb usage, or the Free allowance and replenishment rate. See [Amp details](docs/providers/amp.md). |
| **Apify** | official | The `apify login` session already on this Mac (`~/.apify/auth.json`, or the token the CLI keeps in the keychain), or a token pasted in Settings or exported as `APIFY_TOKEN`, against the `/v2/users/me/limits` endpoint the Console's Billing page draws from. Shows this cycle's platform spend against the account's monthly usage limit. See [Apify details](docs/providers/apify.md). |
| **Kilo** | official | The Kilo CLI's own sign-in (`~/.local/share/kilo/auth.json`), against the same coding-plan quota and balance endpoints the CLI asks. Shows the plan's quota windows and the credit balance. |
| **Custom endpoints** | provider-reported or manual | Configure OpenAI-compatible, Anthropic Messages, or Google Gemini model discovery. Usage can be entered manually or read from a configured JSON endpoint; successful readings are kept locally as a daily hover graph. |

Most providers borrow a credential or session from a tool already on your Mac.
DeepSeek is the explicit browser-login exception: it never reads a browser's
cookies or credentials, and only makes requests after you choose **Sign in to
DeepSeek** from Codenotch. MiniMax is the same kind of exception — a key you
paste in Settings, or an explicit WKWebView sign-in. QianwenAI is a third: it
publishes no usage API and has no key to paste, so that WKWebView session is the
only way in. XyToken is a fourth, and the one this fork adds: its refresh cookie
is HttpOnly and rotates on every call, so the refresh-and-read sequence has to
run in that same WebView, with the bearer token it returns kept only for its own
fifteen minutes. None of them opens a browser's cookie store.

Ollama Cloud accepts an API key in Settings. Apify borrows the `apify login`
session when there is one and otherwise takes a token pasted in Settings or
exported as `APIFY_TOKEN`. Switching a provider off stops its usage polling
and forgets its readings; borrowed accounts stay signed in to the tools that
own them.

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

**Local LM Studio is detected automatically** on the port LM Studio's own settings name
(1234 unless you moved it). Configure the address or stop monitoring in **Settings → LM Studio**.
Each loaded language model gets a notch cell; embedding models are left out. The cell shows the
last response's **tok/s** and its ring fills with how much of the loaded **context** the last
request used. A white arc turns while the model reads a prompt or generates, and becomes a ring
of dots when requests are queued behind it. Hover for context used, tokens and requests today,
reasoning share, speculative-decoding acceptance, model size, quantization and context limit.

Nothing has to be pointed at Codenotch: what a model is doing comes from LM Studio's SDK socket
on the same port (the one `lms ps` uses), and speed and tokens come from `~/.lmstudio/server-logs`,
which LM Studio writes for every request from any client. Only counts and timings are read from
those files, never a prompt or a reply. Responses through the OpenAI-compatible endpoint carry no
clock, so their speed is timed from the generating phase and marked `~`. If LM Studio's server is
set to require an API token, paste one in Settings → LM Studio (or export `LM_API_TOKEN`); without
one, requests are sent with no Authorization header at all.
See [LM Studio details](docs/plans/2026-09-10-lm-studio-provider-plan.md).

**Local oMLX is detected automatically** on the port `~/.omlx/settings.json` names (8000 by
default). The API key is borrowed from the same file, or from `OMLX_API_KEY`, and is never
stored or logged by Codenotch. Configure the address or stop monitoring in **Settings → oMLX**.
See [oMLX details](docs/plans/2026-10-08-omlx-provider-plan.md).

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

An account you only use in the Claude desktop app has no directory of its own,
so it has no ring yet. While one is in use, the ring that is shown is named for
its own account (**Claude Gmail**, not just **Claude**), so you can tell which
one it is. To give the desktop account a ring, sign in to it once from Terminal
and restart Codenotch:

```sh
CLAUDE_CONFIG_DIR=~/.claude-desktop claude
```

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

Command Code has no setting for a second configuration directory: it keeps its
login in `$HOME/.commandcode/auth.json`. A second account therefore lives in a
second home. `~/.commandcode` stays the **Command Code** ring, and each
`~/.commandcode-<slug>` directory adds a **Command Code (slug)** ring with its
own limits and Settings row:

```sh
mkdir -p "$HOME/.commandcode-work"
HOME="$HOME/.commandcode-work" commandcode login
```

Choose the second account during sign-in, then restart Codenotch. The login
lands in `~/.commandcode-work/.commandcode/auth.json`, and that is the file
Codenotch reads; an `auth.json` placed directly in `~/.commandcode-work` is read
too. `COMMAND_CODE_API_KEY` names one account, so it applies to the default
ring only. Codenotch never copies, refreshes or writes these logins.

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

Clicking the notch while it is open keeps it open, so it stays put while you
read it; clicking it again lets it fold away as usual. That click has to land
on the body itself, since a ring takes its own click to refetch that provider
and the orb takes one to open Settings. Right-clicking offers the same thing as
a menu item, **Keep open**, ticked while the notch is being held open, which is
the surer way to release one that was kept open by accident. The item is
greyed out when Settings says Always show, because that choice is Settings' to
change.

In Settings → Appearance → Reset time, choose **Time remaining** for countdowns
like "Resets in 3 Days 3h". **Reset date** keeps the reset date and time, with
minutes shown when less than an hour remains.

Appearance also carries the ring's accent colour. The device accent is the
default; fixed presets are available for pink, red, orange, yellow, green,
teal, blue, indigo, purple and off-white.

The app itself can show a Dock icon, a menu bar item, or neither. The menu bar
item is the Codenotch icon until you switch on **Show limit information in
menu bar** under Settings → Appearance → App; then it shows the five-hour
limits of the providers you choose there — the provider's mark, the share used
and the time until it resets, like `72% · 2h 18m | 41% · 4h 05m`. Choosing
what the bar shows never changes what Codenotch reads, and with nothing chosen
the icon comes back. Its menu has the full readings either way.

## Updates

There is none. This fork ships with an empty update feed and automatic checks
off, so no copy of it can be replaced by upstream's appcast — or by anything
else. To move to a newer build, download the next artifact the same way and
drag it over the old copy in Applications; the quarantine flag needs clearing
again.

Upstream's own builds do update themselves through
[Sparkle](https://sparkle-project.org), which is what the `Updater`, the update
card in the notch, and the `SU*` keys in `project.yml` are for. In this fork
those paths stay in the source and never run.

## Building

```sh
brew install xcodegen create-dmg   # once
make run                # generate, build, launch a Debug build
make test               # unit tests
```

No signing identity is required for either. `make release` — which archives,
notarizes, and produces a signed auto-update feed — needs a Developer ID
certificate and an App Store Connect notary profile. This fork has neither, so
it ships through `make package-adhoc` instead: one universal Release build,
ad-hoc signed, zipped with its checksum. Xcode 15.4 can run it too, which is how
the compatibility path gets checked, but the artifact handed to anyone else has
to come from the macOS 26 SDK (Xcode 26): only that toolchain compiles the
native Liquid Glass branches, so an older build would look right and still fall
back on a new Mac. The Package workflow is where the published artifact is
built. See
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

**Claude Desktop's cache:** Claude Desktop is a Chromium app, so the usage
response its own panel draws is written to an HTTP cache file under
`~/Library/Application Support/Claude`. Reading it is how the ring stays right
for people who work in Desktop rather than in the terminal — the two Claude
Code paths below both go dark when `claude "/usage"` stops printing the windows
and the keychain token has not been re-minted since Claude Code last ran, which
is an ordinary state for a Desktop user. It is strictly read-only, and narrow:
only entries whose cached URL is *this account's* `/api/organizations/<id>/usage`
are opened at all, matched on the organization Claude Code records for the
profile, so one account's numbers can never land on another's ring. No token, no
cookie, no credential and no request to Anthropic are involved. A snapshot older
than 30 minutes is not shown as live — it drops through to the paths below, and
the last good reading ages and dims as any other would. Two minutes, not thirty,
while a session is running or while you are looking at the ring: that is when
the figure is moving, and a cache is the one source that cannot tell you it
has. Chromium's cache format
is private and may change; if it does, the source goes quiet and the existing
ones take over. Bodies are `content-encoding: zstd` and macOS ships no decoder,
so a decode-only build of Zstandard is vendored under
[`Sources/Vendor/zstd`](Sources/Vendor/zstd) (BSD-3-Clause).

**Claude's unused resets (macOS):** the hover card shows the remaining resets
and their expiry, using the same section as Codex. Open **Settings → Usage**
in Claude Desktop for the same account to populate its reset data. That data
is read from Desktop's usage cache and is labeled as cached with the time it
was last observed. Ordinary usage refreshes do not re-date it; old usage
windows still fall back to the CLI/OAuth sources after 30 minutes. Used, paused, future,
and expired grants are hidden. There is no built-in promotion date or assumed
entitlement. As checked on September 23, 2026, the OAuth usage endpoint does
not expose the grants (`ineligible_reason: surface`), so a CLI/OAuth-only
setup cannot show them yet. Codenotch displays availability only; redeem a
reset in Claude. See [the provider notes](docs/providers/claude-resets.md).

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

**How current the figures are.** Your usage cannot move while nothing is
running, so the schedule spends its budget where the number actually changes:
every 30 seconds while a session is working, every 5 minutes while none is, and
at once when a limit window rolls over. Three things outside the schedule also
ask, because each one is a moment the figure is either about to change or about
to be read: a session *stopping* (one reading, so the total you just earned is
on the bar within a second or two rather than up to five minutes later),
opening the menu bar item's menu, and putting the pointer on a ring. The last
two are spaced — hovering four rings in four seconds is one reading, not four.

The reset countdown is drawn against a clock, not against the last reading, so
it is right to the second whether or not anything has been fetched: the card
counts down once a second while it is open, and the menu bar item counts the
last minute of a window down in seconds.

Even at its freshest, a *percentage* is something that was read at some point
rather than a live wire: a look re-reads it, and what comes back may still be a
figure the provider itself published moments earlier. **Settings › General ›
Readings › Ask the provider every time you look** takes that as far as it goes —
a look then refuses every reading a provider is holding, however new, and asks
the provider. It is off by default because it is not strictly better: it spends
a request each time, and a provider that rate-limits answers one request too
many by refusing the next few minutes of them, which leaves the figure older
than the cache would have. Worth turning on to check Codenotch against a
provider's own dashboard, and worth turning off again after. **Refresh now** and
a click on a ring always ask this way — those are somebody's own clicks, not a
schedule.

**Logs:** the app has no window, so anything worth diagnosing goes to the
unified log.

```sh
/usr/bin/log stream --predicate 'subsystem == "com.vinz.codenotch"' --level debug
```

That stream is also where a **refusal** is recorded. When a browser-session
provider — XyToken, DeepSeek, QianwenAI, Qoder, MiniMax, Perplexity — asks you
to sign in again, the app is acting on a response the site returned, and the
line says which one:

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem == "com.vinz.codenotch"' | grep -E 'needsAuth|needsMfa'
```

It carries the provider id, the HTTP status, and the site's own error body
where that is safe to record:

```
xytoken needsAuth: HTTP 401 request=XY20261022023237926895330150e9dd6YmQk4ZHz {"success":false,"message":"Unauthorized","code":"AUTH_SESSION_REVOKED"}
```
`request=` is the station's own `X-Request-Id` for the response that refused the
app. It is the handle its server log can be searched by, and it is the first
thing to quote when a session ends for a reason this side cannot see. The
`session ->` line below carries the same id for the last refresh that succeeded,
so a working session and a dying one can both be found on the station's side.

Those codes are the difference between an account problem and an app problem:

| Code | What it means |
|---|---|
| `AUTH_UNAUTHORIZED` | The session is gone or has expired — signing in again is the whole fix. |
| `AUTH_SESSION_REVOKED` | The session was ended from somewhere else: **Sign out other sessions** on another device, a per-session revoke on the station's Login sessions page, or the station's own defence against a refresh token being replayed. Compare the log's timestamp against that page before assuming the app did it. |
| `AUTH_ORIGIN_FORBIDDEN`, `AUTH_SESSION_MISMATCH` | The request is the problem, not the account — worth reporting with the log line. |
| `AUTH_REFRESH_RACE` | Two clients rotated the same cookie at once. The app retries once, so a line here means the retry lost as well. |

A refusal that asks for a **second factor** is written as `needsMfa:` instead,
and it is not a lost login:

```
xytoken needsMfa: ADMIN_MFA_REQUIRED HTTP 403 request=XY20261029053233… {"success":false,"message":"需要完成多因素认证","data":{"methods":["2fa"],"need_setup":false,"require_admin_mfa":true},"code":"ADMIN_MFA_REQUIRED"}
```

XyToken moved administrator MFA to a per-role requirement, and a session that
has not verified yet is still a live session — the station's own Login sessions
page keeps listing it, last active, which is exactly what makes this look like a
random logout. Nothing on this side can answer it: open **Sign in**, complete the
code in the window that opens, and the app commits the sign-in as usual. The app
does the same thing it does for any refusal — the panel says sign in again and
Sign in opens the sheet — so this line is the only place that distinguishes the
two, and it is the one to read before assuming the session was revoked.

A request that fails for any other reason is written the same way, as
`request failed: HTTP <status> …`, and a fetch the WebView could not complete at
all arrives as `HTTP 0` carrying the script's own error text. That used to be an
anonymous "JavaScript exception" — a rejected `fetch`, which is what a suspended
WebView looks like after a wake, said nothing about which part had failed.

When a site's script refreshes the session, one more line records what the
station says its lifetime is:

```
xytoken session -> created=1789… last_active=1792… expires=1792… request=XY20261022023237…
```

`last_active` moving is the session being kept alive; `expires` is the station's
own answer to "how long is this good for", which is worth reading before
believing any assumption about it.

DeepSeek and QianwenAI return account detail alongside the numbers, so their
bodies are never written to the log; for those the line stops at the status.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Vinz
