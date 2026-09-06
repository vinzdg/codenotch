# Codenotch

A macOS app that pins a small black notch to a screen edge, showing how much of
each coding assistant's usage limit you have burned — and whether it is still
working, done, or waiting on you.

![Collapsed notch with hover tooltip](docs/design/frame-124-hover-tooltip.png)

Hover a ring for its limit windows and when they reset. Claude's ring shows the
same **current session** window Claude Code's own `/usage` leads with, so the
two never disagree.

## What it reads

| Provider | Source | How |
|---|---|---|
| **Claude Code** | official | The OAuth token in the login keychain, against the same endpoint Claude Code's own `/usage` uses. |
| **Cursor** | official | The editor's own signed-in session, read from its local SQLite state — no separate sign-in. |
| **Codex** | official | Codex's own app server, asked live for the current rate limits. Falls back to its rollout log when Codex isn't running. |
| **Antigravity** | official where licensed, otherwise a request count | Antigravity's local language server first, then Google's quota endpoint; a plain count when neither will answer for the account. |
| **GLM** | official | Z.ai's Coding Plan monitor endpoint, with a key borrowed from whichever coding tool already holds one — Claude Code's `settings.json`, ZCode, or OpenCode. |
| **Grok** | official | grok.com's own Usage card RPC (`GetGrokCreditsConfig`), called from inside a signed-in WebView — the weekly SuperGrok pool. Sign in once via Right-click → Sign in to Grok… |

Codenotch never signs in anywhere. Every reading is borrowed from a credential
or session a tool on your Mac already holds — install and sign in to any of
them, and its ring appears. Switching a provider off in Settings stops its
credential being read at all and forgets the readings taken from it; it does
not sign you out of the tool that owns the account, and the row says so.

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

## Placement

The notch lives on any of the four screen edges. Right and left keep a
vertical column; top and bottom lay the readings out side by side. It pins
itself to the *usable* edge, so a bottom notch rests on the Dock and follows
when the Dock hides or moves. On a Mac with a hardware notch, the top
placement takes its exact shape, so the two read as one rather than as a bar
parked underneath it.

At rest it is a small pill on the screen edge that unfolds when the pointer
reaches it — configurable in Settings to always show, or to hide entirely.
Settings live in an orb below the notch: an arc at rest, a gear on hover.

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
[CONTRIBUTING.md](CONTRIBUTING.md).

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

**Keychain:** the app is signed with a stable Developer ID identity so the
one-time "Always Allow" grant on Claude Code's and Antigravity's keychain
items survives rebuilds. The secret itself is read only when the owning app
has actually changed it — checked via the item's modification date, which
isn't behind the same access prompt as the credential — so a valid grant does
not mean a prompt on every poll.

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

[MIT](LICENSE)
