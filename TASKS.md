# Codenotch — Tasks

Full detail in [`docs/plans/2026-08-28-usage-notch-plan.md`](docs/plans/2026-08-28-usage-notch-plan.md).
Design spec in [`docs/specs/2026-08-28-usage-notch-design.md`](docs/specs/2026-08-28-usage-notch-design.md).

## M0 — Project skeleton
- [x] `project.yml` (XcodeGen: app + unit test target, `LSUIElement`)
- [x] `Makefile` (`gen` / `build` / `test` / `run` / `clean`)
- [x] `.gitignore`, `README.md`, docs, design frames committed
- [x] `Sources/Info.plist`
- [x] `Sources/App/CodenotchMain.swift` + `AppDelegate` — launches with no window
- [x] `make run` starts a Dock-less agent process

## M1 — The notch surface
- [x] `NotchGeometry` — target screen, right-edge anchor rect (vertically centred)
- [x] `SideNotchShape` — vertical pill, inverse rounded corners top and bottom
- [x] `NotchPanel` — non-activating `NSPanel`, `.statusBar` level, all spaces, click-through outside the path
- [x] `NotchWindowController` — re-anchor on screen-parameter changes
- [x] The panel frame is rounded to whole points so the notch sits flush against
      the bezel — see "The floating notch" below
- [x] A slow cursor poll backs up the mouse-moved monitors, so a notch that
      appears or resizes under a parked pointer still picks up the hover
- [x] Shape check against `docs/design/frame-124-hover-tooltip.png`

## M2 — Provider cells (static data)
- [x] `DesignSystem/Palette.swift` — colours **sampled from the frame**, which
      disagrees with the hexes written in the spec (see "Corrections" below)
- [x] `DesignSystem/Typography.swift` + `Design.swift` — one `scale` drives every size
- [x] `UsageBand` — `usedFraction` → colour band (thresholds taken from the frame)
- [x] `ProviderRing` — arc from 12 o'clock, clockwise, animatable trim
- [x] `ProviderCell` — ring + glyph + percent label
- [x] `NotchRootView` — data-driven stack, 1–5 cells
- [x] Provider glyphs, traced from the frame (Claude, OpenAI, and the third
      mark, which is Perplexity's)
- [x] Fixtures at 73% / 21% / 52% to match the mockup

## M3 — Hover tooltip
- [x] Hover state driven from a cursor monitor, not `NSTrackingArea` — the panel
      ignores mouse events until the cursor is over it, so tracking areas never
      see the crossing that would switch event handling on
- [x] `TooltipCard` — header, one `LimitWindowRow` per window, 4pt track bars
- [x] `TooltipTail` — triangle aligned to the hovered cell's centre
- [x] Positioning left of the notch; the panel reserves slack so the first and
      last cells' cards still fit (covered by a test)
- [x] 180ms spring in, 250ms grace out so the pointer can cross the gap
- [x] Hit region expands only while the tooltip is showing

## M4 — Data layer
- [x] `Snapshot` / `LimitWindow` / `Fidelity` / `Status` value types
- [x] `UsageProvider` protocol
- [x] `UsageStore` — snapshots, refresh scheduling, staleness. A `@MainActor`
      `ObservableObject` rather than an actor: it exists to publish into SwiftUI,
      and the concurrency lives in the providers it calls.
- [x] **`ClaudeOAuthProvider`** — reads Claude Code's OAuth token from the login
      keychain and calls `GET https://api.anthropic.com/api/oauth/usage`, the
      same endpoint `/usage` uses. Returns Anthropic's own `session` and
      `weekly_all` percentages, so it is `.official`. **Chosen over the planned
      `ClaudeCodeLocalProvider`** — see "Why not the local files" below.
- [x] **`PerplexityWebProvider`** — reads `/rest/rate-limit/all` from inside a
      WKWebView the user signs into themselves. See "Why Perplexity needs a
      browser" below
- [x] `PerplexityUsage` pinned to a recorded response — `PerplexityUsageTests`
      is what fails first if the endpoint changes
- [x] `LimitWindow.usedFraction` and `.resetsAt` are optional, because Perplexity
      reports neither
- [x] **`WebSessionProvider`** — the browser plumbing written once; `Sites`
      carries the per-site origin, script and parser
- [x] **Cursor** via the same route, pinned by `CursorUsageTests`
- [x] Cursor's glyph, flattened from its own SVG rather than traced from the
      design frame — exact at any size. See "Flattening an SVG" below
- [ ] `ManualProvider` — user-declared limits, app-side counter
- [x] Refresh on a timer and on wake — 60s while a session is running, 5 min when
      nothing is. Usage cannot move while nothing is using it, so polling hard
      through a quiet afternoon only spends rate-limit budget
- [x] `Refresh now` in the right-click menu, so a stale notch can be retried
      without relaunching the app

  The menu is popped from `NotchPanel.sendEvent`, not from the content view.
  Setting `hostingView.menu` is not enough: the hit test resolves to one of
  SwiftUI's own subviews, and `NSView.menu` is not inherited, so AppKit ends up
  asking a view that has no menu. `NSWindow.sendEvent` sees the event first and
  is the only reliable place to catch it. (An earlier `menu(for:)` override was
  deleted as "redundant" — it was not, and right-click silently stopped working.)
- [x] `UsageArchive` — the last good reading survives a relaunch, so a cold start
      that cannot reach the endpoint opens on dated numbers instead of a blank
      ring. Restored readings always come back `.stale` and the tooltip header
      carries their age
- [x] Status rendering — `.stale` dims, `.needsAuth` shows a dash and a prompt to
      sign in, `.derived`/`.manual` get "~"
- [x] Tests: reset maths, colour bands, 60-minute reset-copy edge, most-constrained
      window, panel geometry, layout proportions, and the `/api/oauth/usage`
      response shape (the tests that fail first if Anthropic changes it)

### Why not the local files

The plan's first adapter was to parse `~/.claude/projects/**/*.jsonl` into a
rolling 5-hour window. The corpus is there — 15,838 assistant messages with
per-message token counts, back to mid-June, enough to reconstruct 70 windows —
but it carries **no limit and no window metadata**: no rate-limit headers, no
cached usage response, and there is no `claude usage` subcommand. A percentage
from it needs an invented denominator, which is why the spec grades it
`.derived`.

The OAuth endpoint gives the real number instead. The trade is that it is not a
published API and can change without notice, so `UsageResponseTests` pins the
shape and every failure path degrades to a status rather than a guess. The local
parser is still the right fallback if the endpoint goes away.

### Flattening an SVG

Cursor's mark arrived as an SVG, which is better than the frame traces: a real
vector rather than a 46px screenshot. It goes through the same `GlyphOutline`
mechanism — flattened to polygons, normalised into a unit box, filled even-odd so
the arrow stays cut out of the cube.

The one trap, and it is a well-known one: **SVG arc flags cannot be tokenised as
numbers.** In `a.998.998 0 00-.998 0` the `00` is the large-arc and sweep flags —
two single digits with no separator — and a generic number regex reads it as the
single value `0`, after which every remaining argument shifts by one and the path
falls apart. The flattener scans by position and asks for a flag as one
character, never as a number.

### Codex

Replaced Perplexity in the lineup, and fills the OpenAI slot the design frame
always had.

Codex needs **no credential and no network**: it records its own rate-limit
snapshots into the rollout log of each thread, so `CodexLocalProvider` reads them
straight off disk — the cheapest and most honest source of any provider here. The
newest rollout is found through Codex's thread index (`state_5.sqlite`, opened
`mode=ro` because it is WAL) rather than by walking a sessions tree holding 2750
files, and only the tail of it is read.

The first real turn settled the shape, and it differs from the published schema
in a way that mattered:

```json
"rate_limits": { "limit_id": "codex", "plan_type": "free",
  "primary": { "used_percent": 0.0, "window_minutes": 43200,
               "resets_at": 1790585719 },
  "secondary": null,
  "credits": { "has_credits": false, "unlimited": false, "balance": null } }
```

- The reset is **`resets_at`, an absolute epoch** — not the `resets_in_seconds`
  countdown the schema described. Reading only the countdown loses the reset time
  silently: the window still renders, just with no "resets in" copy, which looks
  like a layout quirk rather than a parsing miss.
- `secondary` is `null` on this plan, so there is one window, not two.
- `window_minutes: 43200` is 30 days, so the label reads "Monthly limit".

Both reset forms are read now, so a build emitting the other one still works, and
`CodexUsageTests` is pinned to the recording like every other parser.

**Until that turn ran the cell showed a dash, which was correct.** Codex had not
been used since February and had recorded no snapshot; a dash and "Codex has not
recorded a usage snapshot yet" is what "we do not know" looks like.

**Activity is a heuristic, and says so.** Codex publishes no status field — no
equivalent of Claude Code's `status` or Cursor's `unfinishedRunAt`. What it does
do is append to the rollout while a turn runs, so a file written seconds ago
means work is happening. `CodexActivityMonitor` errs short: the ring stops eight
seconds after the last write rather than claiming activity it cannot see. If
Codex grows a real status field, that should replace this.

Perplexity's adapter is kept but unregistered. `WebSessionProvider` is the
working pattern for a site behind bot management, and re-registering is one line.

### Cursor

Its documented APIs — Admin, Analytics — are team-scoped and need an admin key,
so an individual's own usage is only where the dashboard reads it:
`GET https://cursor.com/api/usage-summary`.

**It reads the editor's session, not a browser one.** The first version signed
into cursor.com inside the app's WebView, which quietly created a *second*
Cursor account — so the notch honestly reported zero usage belonging to somebody
who was not the user. The two identities were only visible side by side:

```
editor state.vscdb : google-oauth2|user_01JT4P1FS4AB8WA4N7QVSYZRTT  (raphaelvinz.rv@…, "Vinz")
WebView /api/auth/me:              user_01JXH6KPZ5D7XZHMEQ181QRG2S  (xurfa9@…,        "Xurfa")
```

`CursorCredentials` now reads `cursorAuth/accessToken` and
`cursorAuth/stripeMembershipAuthId` out of the editor's SQLite global-state
store, opened read-only and `immutable` so a running editor is never blocked,
and sends them as `WorkosCursorSessionToken=<account>::<token>`. Bearer auth on
the same token is rejected; the cookie pair is what works. There is only ever one
account this way — the one being used — and no sign-in to keep alive.

**Cursor meters an allowance, not requests.** The recorded response:

```json
{ "billingCycleEnd": "2026-09-24T03:32:15.933Z", "membershipType": "free",
  "individualUsage": { "plan": {
      "used": 0, "limit": 0, "remaining": 0,
      "breakdown": { "included": 0, "bonus": 19, "total": 19 },
      "autoPercentUsed": 0, "apiPercentUsed": 19, "totalPercentUsed": 9.5 } } }
```

`used` and `limit` are **both zero on a free plan while real usage is
happening**, because the allowance arrives as `breakdown.bonus` rather than as a
dollar limit. Reading them reported 0% for an account 10% through its month —
a number that was true of the field and false about the world. The dashboard's
"Your included usage · N% used" is `totalPercentUsed`, and that is what the ring
now shows. `apiPercentUsed` gets its own row when it has been touched.

### Why Perplexity needs a browser

The plan was to lift the session cookie out of Chrome. That cannot work, and the
reason is worth writing down before someone tries again.

`perplexity.ai` is behind Cloudflare bot management. An unauthenticated probe:

```
$ curl -sD- https://www.perplexity.ai/rest/rate-limit/all
HTTP/2 403
cf-mitigated: challenge
server: cloudflare
```

A session cookie does not fix this. The `cf_clearance` that accompanies it is
bound to the TLS and HTTP/2 fingerprint of the browser that earned it, so a
`URLSession` request is challenged whatever cookies it carries. Making it pass
would mean impersonating Chrome's fingerprint — that is defeating bot detection,
not reading your own usage, and it is not something this app will do.

So the request is made *by a browser*. `PerplexityWebProvider` owns a WKWebView
with the app's own persistent data store; **Right-click the notch → Sign in to
Perplexity…** opens it, the user signs in (and answers a Cloudflare challenge
themselves if asked), and refreshes then run a same-origin `fetch` inside that
page. Nothing is lifted out of Chrome or Safari, no fingerprint is faked, and no
challenge is ever answered on the user's behalf.

Two deliberate restraints:

- The provider makes **no** network request until a sign-in has succeeded once.
  Quietly loading perplexity.ai in a hidden WebView every minute for someone who
  never asked for it would be wasteful and, reasonably, indistinguishable from
  automation.
- `PerplexityUsage` reports a window only when it finds *both* a count and a
  limit. Half a quota tells you nothing, and filling in the other half with a
  default is the one thing this app must never do.

The recorded response settles how Perplexity can be shown at all:

```json
{ "free_queries": { "available": true,
                    "remaining_detail": { "kind": "exact", "remaining": 10 } },
  "model_specific_limits": {},
  "remaining_agentic_research": 0,
  "remaining_labs": 0,
  "remaining_pro": 2,
  "remaining_research": 0,
  "sources": { "source_to_limit": { … connector quotas … } } }
```

It reports **only what is left** — no totals, and no reset times. There is
therefore no denominator for a percentage and no countdown to show, and working
either out would mean inventing the number. So the Perplexity cell prints the
**count** (`2`) with no arc, and its tooltip rows read "2 left" with no bar and
no reset copy. An empty bar would say "none used", which is not what "we were
never told the limit" means.

That is why `LimitWindow.usedFraction` and `.resetsAt` became optional: the model
now has a way to say "not stated" instead of defaulting to zero or to a date a
week out, which is what the first version did.

**Known imprecision:** `NotchLayout.cardHeight` still budgets a bar per window,
so the hover region for a bar-less card is taller than the card itself. The
failure mode is a slightly sticky tooltip, never one that closes early.

### `evaluateJavaScript` does not await

The first WebView fetch failed with an opaque error because it used
`evaluateJavaScript` on an async body. That returns whatever the last expression
evaluates to and never awaits it, so an `async` IIFE hands back an unresolved
Promise — an unsupported type — and the whole thing surfaces as a generic
failure. `callAsyncJavaScript(_:arguments:in:contentWorld:)` runs the body as an
async function and awaits it, which is what was needed.

Two lessons kept in the code: every failure path now logs *which* step failed
rather than collapsing to `badResponse(status: 0)`, and the raw body is logged
before it is parsed so a parser can be written against a recording.

### Why it looked like signing in after every restart

Two unrelated faults with the same symptom — cells asking to be signed in the
morning after a reboot.

**Cursor and Codex: the wrong SQLite open.** Both keep state in another app's
database, both in WAL mode, and the two ways of opening one read-only each fail
in a different situation:

```
mode=ro     : unable to open database file   <- no -shm sidecar
immutable=1 : OK, 2752 threads
```

`immutable=1` ignores the write-ahead log, so a running app's recent writes are
invisible — that is how a live agent looks idle and a rotated token looks
current. `mode=ro` sees the log but needs the `-shm` sidecar, and **that file
exists only while the owning app is running**. After a restart, with Codex closed
and checkpointed, a read-only open fails outright — so the notch reported "no
Codex threads on this machine" for a machine with 2752 of them.

`SQLiteStore` now tries `mode=ro` first and falls back to `immutable=1`. The
fallback is only ever reached when there is no write-ahead log left to miss,
which is exactly when ignoring it costs nothing.

**Claude: an expired token treated as being signed out.** The access token lives
about eight hours, and this app deliberately does not refresh it — minting one
would mean writing a credential it does not own and racing Claude Code for it.
So after a night the token is stale until Claude Code next runs.

The old code treated that as `needsAuth`, which *supersedes history*: the
remembered reading was discarded and the cell demanded a sign-in that was never
actually required. An aged-out token now reports `credentialExpired`, which reads
as staleness — the last reading stays, dimmed and dated, and the cell quietly
comes back to life the next time Claude Code runs. Being genuinely signed out
still clears it, because then the old number really is unreliable.

### The keychain prompt

The app reads Claude Code's keychain item, so macOS asks permission the first
time. The keychain's ACL remembers *which signed binary* was allowed, so the app
is signed with a stable Developer ID identity (`project.yml`) — an unsigned or
ad-hoc build gets a new identity every rebuild and the prompt would come back
after every `make run`. Click **Always Allow** once and it sticks. A refusal
backs the provider off for five minutes so a denied prompt cannot spam.

## M4b — Is it working? (agent activity)

Answers "do I need to go and look" without going and looking. Claude Code and
Cursor both feed it, through one display model.

- [x] `AgentSession` — one display model; each monitor does its own parsing
- [x] `ClaudeSessionRecord` — decodes `~/.claude/sessions/<pid>.json`, which
      Claude Code writes on every state change. `status` is `busy` / `waiting` /
      `idle`, and a waiting session carries `waitingFor`
- [x] `CursorActivityMonitor` — Cursor publishes no session registry, so its
      working state comes from `composerHeaders` in the editor's own SQLite
      store. See "Reading Cursor's working state" below
- [x] `ProcessLiveness` — a crashed session leaves its file behind saying `busy`
      forever, so the pid is checked, and its start time is compared against the
      record to survive pid reuse
- [x] `SessionMonitor` — watches the directory with a `DispatchSource` rather than
      polling, so a state change shows up immediately. A slow timer runs alongside
      purely to notice processes that died without touching the directory, which
      no file event will ever report
- [x] `ActivitySummary` — reduces every live session to one state, with `waiting`
      outranking `busy`: it is the only state that is asking you for something
- [x] The indicator lives **inside the provider's own ring**, not in a cell of its
      own: a thin arc in the gap between the glyph and the inside edge of the
      track. It spins while busy and becomes a full pulsing ring while waiting.
      Reduce Motion drops both animations and keeps the colour
- [x] Session list appended to that provider's tooltip, under a rule — every
      session by name, where it is running, what it is waiting for, and how long
      it has been in that state
- [x] Claude Code sessions belong to the Claude cell only; other providers get no
      activity rather than a borrowed one
- [x] Tests: status and `tempo` mapping, `procStart` timezone, pid-reuse guard
      inputs, summary precedence, label widths, elapsed copy
- [ ] Notify on `waiting` (deliberately not built — colour and pulse only, per the
      design call. The hook is `ActivitySummary.waitingSessions`)
- [ ] Click a session to focus its terminal window

### Why it is inside the ring

It started as a cell of its own, which put two ring-shaped things in the notch
that looked alike and meant different things — usage in one, activity in the
other. Folding it into the provider's ring means every ring in the notch is that
provider's ring. Three things keep the two facts apart inside it: a different
radius, a much thinner stroke, and a neutral colour. Working is **white** on
purpose — the outer ring's colour already encodes how much of the limit is gone,
so a green or amber inner arc could be misread as part of that scale. Waiting is
the exception and takes amber, because it is the one state asking for something.

Staleness dimming applies to the usage reading only. Whether Claude is working is
known first-hand from a local file, so it stays at full strength even when the
percentage behind it has gone stale.

### The floating notch

A hairline of wallpaper down the right-hand side made the notch read as floating
rather than welded to the bezel. The cause was two halves of the same mistake:

```
wanted {{1465.675, 481.909}, {334.325, 205.183}}
got    {{1465,     482    }, {335,     205    }}
```

Every measurement is derived from the design frame's pixel ratios, so the panel
size is fractional. AppKit rounds window frames to whole points, which *widened*
the panel — while the SwiftUI content was hard-framed to its exact fractional
size and anchored left, so it no longer filled the window it lived in and stopped
about 0.7pt short of the edge.

Both halves are fixed: `NotchGeometry.panelFrame` rounds out to whole points
itself, so `wanted == got`, and the root view reads its real width from a
`GeometryReader` instead of assuming the size it asked for.

### The clipped bottom flare

The notch's bottom flare was being cut off — a straight edge where there should
have been a curve into the bezel. The panel was sized for **zero** provider cells
while one was on screen, so the shape overran it by about 28pt and the bottom was
clipped away.

The cause is a Combine trap that `~/notch-app` already carries a comment about:

> `@Published` fires its sinks in `willSet`, so re-reading the model here would
> give the stale previous value.

The subscription that resizes the panel when the provider list changes did
exactly that — it reacted to `$snapshots`, then read `model.snapshots.count` back
and got the *old* array, which was still empty. `relocate(cellCount:)` now takes
the count from the emission instead.

Worth knowing how it was confirmed, because the first measurement was wrong. A
column two points in from the screen edge cuts across the narrowing flare, so it
reads short whether or not anything is clipped. The signal that actually settles
it is the **width of the last black row**: a shape that ends naturally tapers to
1px, and one that is clipped stops abruptly at several px wide.

```
before:  extent 172.5pt   top row 1px   bottom row 5px   <- straight cut
after:   extent 180.5pt   top row 1px   bottom row 1px   <- tapers to a point
```

### Reading Cursor's working state

Cursor has no equivalent of Claude Code's session registry, but its
`composerHeaders` rows carry the two facts that matter:

- `unfinishedRunAt` — a timestamp while a run is in flight, cleared when it ends.
- `hasBlockingPendingActions` / `hasPendingPlan` — set when it wants you.

Only composers in one of those states become sessions. An editor with forty idle
chats in its history is not forty things happening.

**The database is in WAL mode, and that is the whole trick.** Opening it with
`immutable=1` tells SQLite to ignore the write-ahead log, so it returns whatever
was true at the last checkpoint. Observed side by side during a real run:

```
immutable    : unfinishedRunAt 12:37:09   <- stale; that run had already finished
readonly+wal : unfinishedRunAt None       <- the truth
```

That would have made the spinner lag by minutes. It also turned up a latent bug
in `CursorCredentials`, which used `immutable=1` too and could therefore have
served a token the editor had already rotated. Both now open `mode=ro`.

Polled at 2s rather than watched: the writes land in the `-wal` sidecar, and a
file event says a byte moved, not that a run started.

### The headline that moved when a window reset

The ring is supposed to always mean "current session". It did — right up until
the session window reset, at which point it started showing the weekly instead.

Claude Code's own schema explains it:

> `"five_hour"` — present only while the API reports it **and its `resets_at`
> has not passed**

So the session entry drops out of `limits` the moment it rolls over, leaving
`weekly_all` alone in the array. The headline rule was `windows.first`, so the
weekly quietly slid into the session's place: the ring kept its shape and changed
its subject, at exactly the moment someone is most likely to be looking at it.

Two changes, because either alone would leave the trap set:

- **The named `five_hour` / `seven_day` objects are merged in**, not used only as
  a fallback. They still carry the window when the array has dropped it, so the
  session survives its own reset — reading 0% in a fresh window, which is the
  truth.
- **The headline is declared, not positional.** `ProviderSnapshot.headlineID`
  names the window the ring means (`session`, `included`, `primary`). If that
  window is genuinely absent the cell shows a dash rather than promoting another
  one. A blank is honest; a weekly percentage wearing the session's place is not.

This is the second time this exact drift appeared — the first was picking the
most-constrained window. Positional and "whichever is biggest" rules both let the
subject move. Naming it is what stops it.

### The bugs worth remembering

**Timezone.** `procStart` in the session file is a ctime string in **UTC** — "Fri Aug 28
05:15:20 2026" for a process that `ps` reports as starting at 12:15:20 local.
Parsing it as local time put it seven hours out, the pid-reuse guard concluded
the process was a different one, and the activity cell silently never appeared.
The liveness check now anchors on `startedAt`, which is unambiguous epoch
milliseconds, and `parseProcStart` pins the timezone to UTC.

**Rate limiting.** `GET /api/oauth/usage` returns **429** if you call it too
often — which repeated `make run` during development does easily, since every
launch fetches immediately.

The first attempt at a back-off did nothing, because the endpoint answers
`Retry-After: 0` and that was obeyed literally: "wait zero seconds" meant the
poll kept firing straight back into the limit it was sustaining. The server's
hint is now only allowed to *raise* the floor — the wait starts at 60s, doubles
per consecutive 429, and caps at 15 minutes so it always recovers unattended.

The back-off also had to outlive the process. Every relaunch started clean and
fired a request immediately, so a development loop of `make run` walked into the
limit each time and kept it alive — the app was the thing sustaining its own
punishment. `UsageArchive` now persists the deadline, and a relaunch during a
penalty waits rather than spending an attempt.

A 429 renders as staleness rather than an error: the last good reading is still
roughly true and there is nothing the user can do about it.

**`make test` was launching the app.** The unit bundle is hosted by the app, so
`xcodebuild test` runs `applicationDidFinishLaunching` for real — and every test
run therefore put a live request on the usage endpoint. Dozens of them, quietly,
while the rate limit was being diagnosed. The delegate now bails out when
`XCTestConfigurationFilePath` is set. Any host-app side effect has to be guarded
this way; tests must not do network I/O.

**Diagnosing any of this needed logging.** An agent app has no window to print
into, so failures were invisible and the first attempts at a diagnosis were
guesses from screenshots. `Sources/App/Log.swift` fixes that:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.vinz.codenotch"' --level debug
```

Note `/usr/bin/log`, not `log` — zsh has a builtin of that name that swallows it.

**Nothing was remembered between launches.** Related, and worse: every launch
started from an empty ring, so a single failed cold fetch left the notch with no
number at all — even though a good reading had been on screen minutes earlier.
`UsageArchive` fixes that. The rule it must never break is that a remembered
reading is not presented as a live one: it comes back `.stale`, the ring dims,
and the tooltip header is dated.

## M5 — Settings + persistence
- [x] `Preferences` — which providers to show, launch at login. Stored as the
      *hidden* set rather than the shown one, so a provider added in a later
      version appears by default instead of silently staying dark
- [x] Settings window, reached from the orb below the notch
- [x] Launch at login via `SMAppService`, reading its state from the system
      rather than from our own store — the user can turn it off in System
      Settings, and a remembered `true` would then be a lie
- [x] Right-click menu: Keep open, Refresh now, Sign in…, Quit
- [ ] Drag-to-reorder providers
- [ ] Plan ceilings, auto-hide

### Accounts in settings

Codenotch runs **no OAuth flow of its own**. It borrows a credential each tool
already holds — Claude Code's keychain token, Cursor's editor session, Codex's
`auth.json` — so there is no account for it to connect, and a "Connect" button
would be theatre. What there *is* to show is whose readings these are:

```
Claude  Pro · via Claude Code
Cursor  raphaelvinz.rv@gmail.com · Free · via Cursor
Codex   raphaelvinz.rv@gmail.com · Free · via Codex
```

That is not decoration. Borrowing a credential means the account being read can
quietly differ from the account being used, and it did: a browser sign-in created
a second, empty Cursor account and the notch spent an afternoon faithfully
reporting somebody else's zero. A visible address would have caught it in
seconds. Each row also links to that provider's own usage page, so the number can
be checked against its source.

Claude's credential carries no address, only a plan — so the row says what it
knows and no more.

**A trap worth remembering.** `account()` was first added only as a protocol
*extension* with a `nil` default, and implemented on each provider. Methods that
exist solely in an extension are dispatched **statically**, so calling it through
`any UsageProvider` always landed on the default: every account reported as
absent, with no error anywhere. Declaring it as a protocol requirement restores
dynamic dispatch. `ProviderAccountDispatchTests` calls through the existential
specifically, because calling the concrete type directly would pass either way.

### The settings orb

Built from two reference frames rather than described in words, which settled a
question I would otherwise have got wrong: the control is **outside** the notch,
not a row inside it.

At rest it is a single stroked arc tucked into the corner the bottom flare
makes; hovered, the same circle fills in and takes a gear. Measuring both frames
showed the arc's endpoints lie *on* the hover circle — so they are one circle in
two states, which is what makes the change read as an object waking up rather
than one thing being swapped for another.

Sizes came off the frames: the notch body is the familiar 70pt in both, at 2px
per point, which fixes the scale and gives a 48pt circle. The first attempt used
36pt and looked visibly undersized against the reference.

It is a bare arc at rest for the same reason the notch folds away: a permanently
visible gear is a second thing competing with the readings, and the readings are
the point.

**The arc has to be concentric with the flare.** The first version centred the orb
on the notch body's axis, which put the arc near the corner without following it —
the curves diverged and it read as a stray mark. Fitting a circle through the
reference arc's centreline settled it:

```
notch flare : centre (edge - curlRadius, shapeBottom)  radius 38.5pt
resting arc : the same centre                          radius 28.5pt
filled disc : the same centre                          diameter 46.5pt
```

One centre, three radii. Because the arc shares the flare's centre of curvature
it parallels the edge exactly, at a constant 10pt gap, over the same twelve-to-
three quadrant the flare sweeps. `orbInsetFromEdge` is therefore `curlRadius`
rather than half the body width, and a test asserts that — get it wrong and the
symptom is subtle: it still looks like an arc near a corner, just not *this*
corner's arc.

## M6a — Folding away, and motion

- [x] The notch folds to a **pill** at the screen edge and unfolds on contact.
      Folded it is 10 x 72pt; the region that wakes it is deliberately larger,
      because a 10pt target on a screen edge is fiddly and the cost of being
      generous is only that it opens a little eagerly
- [x] Folding shut waits 0.45s — longer than the tooltip's grace, because it is a
      bigger movement and doing it the instant the pointer strays feels twitchy
- [x] **Click to pin** it open, so it stays put while you read it
- [x] Folded, only the pill takes the mouse. The rest of the panel is a hole —
      which matters far more folded than open, since being out of the way is the
      entire point
- [x] `NotchMotion` — one motion vocabulary rather than numbers scattered through
      views. Springs throughout: macOS motion reads as physical because things
      overshoot slightly and settle, and a panel that scales without any of that
      feels like a slideshow
- [x] Cells stagger in behind the shape, each trailing the one above, capped so a
      long list never drags
- [x] Readings **sweep** to their new value rather than snapping — a ring that
      jumps reads as a glitch, one that sweeps reads as a measurement. The
      percentage uses `contentTransition(.numericText())`
- [x] Reduce Motion removes the animation rather than shortening it
- [x] **Click a ring to refetch that provider.** Only that one: asking one cell
      for a fresh reading must not spend every other provider's rate-limit
      budget, and Claude's is easy to exhaust. A second click while one is in
      flight is ignored
- [x] The ring **presses in** while it works and gives one full turn, then
      settles at the new reading
- [x] The cursor becomes a **pointing hand** over a ring, and only there — the
      gap between cells is not a button, and the folded pill is a handle you
      hover rather than a target you aim at. Pushed and popped rather than
      `set`, so leaving restores whatever cursor the app underneath had chosen;
      stamping `.arrow` on the way out would wipe someone else's text caret
- [x] Pinning moved to a **"Keep open"** menu item. Click-to-pin had to go: every
      point inside the open notch maps to a cell, so once rings became buttons
      there was no click target left to unpin with
- [ ] Remember the pinned state across launches
- [ ] Auto-fold when a full-screen app is frontmost

The panel never resizes for the fold: animating a window frame is jerky, and the
reserved space is transparent anyway. Both states share a centre line, so folding
contracts in place instead of sliding up the screen.

### The tooltip that spilled when you moved quickly

Moving between cells fast showed contents sitting outside the card — and briefly,
two headers on top of each other. Two causes, and only the second one mattered.

**Clipping.** The card did not mask its own contents, so during a resize the rows
of a taller card hung outside a shorter background. `.clipShape` on the same
rounded rectangle fixes that, and it is still worth having for the case where one
provider's card resizes in place — Claude's grows a session list when an agent
starts. The tail stays outside the clip: it is part of the silhouette, not of the
contents.

**The contents interpolating.** SwiftUI was animating one provider's rows into
another's, sliding text through positions belonging to neither layout — which is
how "Cursor Usage" ended up printed over "Included usage" mid-flight.

The first fix was to give the *card* an identity, so one leaves and another
arrives. That removed the overlap and also removed what made it good: the card
travelling and resizing between cells is the nicest movement in the app, and
replacing it with a swap felt stiff.

So the identity moved inward. The card stays one object that morphs; its
**contents** get `.id(snapshot.id)` and `.transition(.identity)`, so they are
replaced outright rather than interpolated. The shell keeps gliding, the rows
swap cleanly inside it, and the clip covers the moment where new contents are
briefly larger than the frame still travelling toward them.

**Then the tail came loose.** Swapping the contents outright fixed the overlap
but made the card's height change instantly while its position still glided. The
tail is centred on that height, so it jumped while the card slid: the two halves
visibly came apart, and the whole thing read as stiff rather than liquid.

The height is now given explicitly — the same figure the hover region uses, so
what is drawn and what is reachable cannot drift — and travels on the same spring
as the position.

**And then the rows drifted.** Putting the contents inside a frame of that
animating height makes SwiftUI re-align them on every frame, so they slide
vertically inside the card and the top ones disappear under the clip. The fix is
the arrangement the notch fold already uses: lay the contents out once at their
natural size, never move them, and let the **mask** change size over them.

```swift
ZStack(alignment: .top) {
    RoundedRectangle(...).fill(Palette.card).frame(height: height)   // animates
    content.padding(...).frame(width: cardWidth, alignment: .topLeading)  // never moves
}
.frame(width: cardWidth, height: height, alignment: .top)
.clipShape(RoundedRectangle(...))
```

Nothing moves except the boundary, which is why the fold felt right and the first
three attempts at this did not.

Worth remembering as a general shape: when a morph misbehaves, the question is
usually *which part* should keep its identity, and *what* should be allowed to
move — not whether to abandon the morph. Three times here the answer was "fewer
things move than you think": the notch's contents do not move, the card's contents
do not move, only the masks do.

### `repeatForever` does not stop

The refresh spin was first written the obvious way: start a `repeatForever`
linear rotation when the fetch begins, cancel it when the fetch ends. It never
cancelled — the ring kept turning long after the answer had arrived.

Two things conspire. `repeatForever` does not stop when you set the value back,
and if the value you set is the one it is *already animating toward*, SwiftUI
sees no change, opens no transaction, and the repeat simply carries on. Setting
`spin = 360` to "finish the lap" was therefore a no-op on an animation whose
target was already 360.

A single finite turn has no cancellation problem at all:

```swift
withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) { spin += 360 }
```

360° is the same angle as 0°, so it lands exactly where the reading belongs, and
easing out means it settles rather than stopping dead. If a fetch outlasts the
turn the ring simply sits still until the answer arrives, which is calmer than
spinning indefinitely anyway.

The spin is applied to the **usage arc itself** rather than to an overlaid
spinner: the thing being refetched should be the thing that moves, and a second
arc on the same track only competes with it. The activity spinner stays where it
is, further in — it is a different fact.

### Two things the fold got wrong at first

**The contents were clipped to a box, not to the notch.** `.clipped()` masks to
the bounding rectangle, so as the shape shrank the cells simply sat on top of it
and appeared to slide out of the bottom. `.clipShape(SideNotchShape())` masks
them to the outline instead, so they are swallowed by it as it closes — which is
the only thing a notch can plausibly be doing. With the clip carrying the
concealment, the per-cell `scaleEffect` came out: two effects were fighting.

**The folded pill had square corners**, from this clamp:

```swift
let corner = min(cornerRadius, (height - 2 * curl) / 2, rect.width - curl)
```

`width - curl` is the obvious reading — leave room beside the flare — but the
flare is itself clamped to the width, so at 10pt wide `curl == width` and the
corner collapses to **zero**. The corner is now claimed first out of half the
width, and the flare takes what is left:

```swift
let wanted = max(0, min(cornerRadius, rect.width / 2))
let curl   = max(0, min(curlRadius, rect.height / 2, rect.width - wanted))
let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
```

At full width nothing changes — the design's flare is wider than half the body
and stays so, which `testTheOpenNotchIsUnchanged` pins by sampling the profile
rather than probing one point. A point 1pt below the top sits in a flare only
hundredths of a point wide; that is a fact about arcs, not a bug.

## M6 — Polish
- [ ] Threshold notifications (80% / 100%), per-provider mute
- [ ] Auto-hide: never / on fullscreen / on overlap
- [ ] Multi-display follow + unplug handling
- [ ] Reduced-motion / reduced-transparency
- [ ] App icon, final name, README screenshots

## Managing accounts from Settings

The ask was "adjust login and logout through settings". Taken literally there is
nothing to adjust: Codenotch runs no OAuth flow of its own, so it has no session
to end. What it has is a decision about *whether to read* each borrowed
credential, which is the same control under an honest name.

- [x] `Preferences.isConnected(_:)` / `setConnected(_:for:)`. The stored key is
      still `"hiddenProviders"` — renaming it would have silently re-enabled
      every provider a user had already switched off.
- [x] Disconnecting **stops the fetch**, it does not filter the result. That is
      the whole point: a hidden provider whose keychain item is still being read
      every two minutes has not been logged out of in any sense the user means.
      `UsageStore.refresh()` filters to live providers before calling any of
      them, `refresh(providerID:)` guards the same way, and `disconnected`'s
      `didSet` prunes existing readings so the ring goes immediately.
      Covered by `DisconnectedProviderTests`.
- [x] One **switch** per provider, both directions. Briefly replaced with
      Sign in / Sign out buttons — that was an over-correction, and reverted:
      the switch was already the right control, it just needed to *do* both
      things rather than only hide the row.
- [x] Switching **on** routes to auth rather than only setting a flag:
      `UsageStore.signIn(providerID:)` presents the provider's own modal
      (`.modal`), launches the owning app (`.openApp`), or reports that there is
      nothing to open (`.guidance` — Claude Code is a command, so the row's
      guidance is the whole answer). It opens nothing when the credential is
      already readable; a sign-in window over a signed-in account is noise.
- [x] Sign out does strictly more than disconnect: `UsageStore.signOut` also
      drops the archived reading (`UsageArchive.forget`), because a disconnect
      alone leaves the last numbers on disk and they return, dimmed, on the next
      launch. `SignOutTests.testTheReadingDoesNotComeBackOnTheNextLaunch` is the
      case a plain disconnect fails.
- [x] `WebSessionProvider.signOut()` clears its own cookies — the one true
      logout in the app, because that session is the only one Codenotch created.
      Scoped to the site's host: the data store is shared, so emptying it would
      sign the user out of every other web provider too. Nothing ships on this
      path today, but the button would silently lie without it.
- [x] Each row shows the account it reads (address and plan), with **Open** going
      to that vendor's own usage page.
- [x] Every row states what signing out does *not* reach
      (`SignInRoute.signOutCaveat`). Deleting Claude Code's keychain item or
      Cursor's `state.vscdb` row would be a true logout and is deliberately not
      offered: it would sign the user out of an app they did not ask us to touch.
- [x] `SignInRoute` gained `.modal(name:)`, so routing is exhaustive over the
      enum instead of inferred. A `WebSessionProvider` now carries it, and it is
      the one route where signing in and out are literally true — its caveat
      says the session really is ended, where the others say it is not.
      The button is hidden when the owning app is not installed, rather than
      doing nothing when pressed.
- [x] `signInRoute` and `account()` are **protocol requirements**, not extension
      members. Declaring them only in the extension dispatched statically and
      made every provider report the default — see the note above.

## What's New, once per version

- [x] `ReleaseNotes` — the history the app ships with, written in Swift rather
      than fetched from the appcast: it has to be there on a first launch with
      no network, and it belongs to the build it describes.
- [x] `WhatsNewWindowController` shows it once per version and records
      `lastSeenVersion` **when it is dismissed**, not when it opens — recorded
      on open, a crash in between swallows the one launch it was going to
      appear on. Closing by the red button counts as reading it.
- [x] A version with no note written shows nothing, and is *still* recorded.
      Left unrecorded it would surface later, long after it was current, the
      first time a note happened to exist for it. Silence beats an empty
      dialogue.
- [x] On a fresh install it comes first and Settings follows when it is
      dismissed. Two windows arriving together is one to dismiss before you can
      read either.
- [ ] **Write 1.0.0's copy.** `ReleaseNotes.all` carries a placeholder entry
      drawn from the unreleased work. `testTheCurrentVersionHasANote` fails the
      build if `MARKETING_VERSION` is bumped without an entry, so the ritual is
      caught rather than remembered.

Two things worth keeping in mind:

- **The list scrolls inside a fixed window.** A window that sizes itself to its
  content jumps between releases of different lengths, and a long release
  otherwise runs past the foot of the window and takes the Continue button with
  it — leaving a dialogue with no way out but the red button.
- **`ScrollView` draws nothing under `ImageRenderer`.** That is why the list is
  its own view, `WhatsNewChanges`: looking for it inside the dialogue would only
  ever have proved the renderer's limits.

## Shipping a notarized .dmg

`make release` does archive → export → dmg → notarize → staple → verify.

- [x] Hardened runtime on. Notarization requires it; it was off because nothing
      until now needed it. Verified it breaks nothing that matters here: all
      three providers fetched successfully under it, keychain read included.
      The App Sandbox stays **off** — it would block reading Cursor's
      `state.vscdb` and Codex's rollout logs, and Developer ID does not need it.
- [x] Release build exported with `method: developer-id`, which re-signs the
      bundle as a distributable. A Debug build is not one.
- [x] Secure timestamp present (`codesign -dvv` shows `Timestamp=`), which
      notarization rejects submissions without.
- [x] `verify-release` mounts the finished dmg and runs `spctl --assess`, which
      is what a customer's Gatekeeper actually runs. Before notarization it
      says `rejected / source=Unnotarized Developer ID` — that is the expected
      state, and it becomes `accepted` once the ticket is stapled.
- [ ] **Store notary credentials** — needs an app-specific password, so it has
      to be run by hand once:
      `xcrun notarytool store-credentials Codenotch --apple-id <id> --team-id 6WFPL8B9FB --password <app-specific-password>`

### Automatic updates

Sparkle 2, configured to install without asking.

- [x] `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` set in the plist.
      Both matter: without the first, Sparkle shows a "check for updates
      automatically?" prompt on first launch, which is the exact permission
      this is meant to avoid.
- [x] Updates are EdDSA-signed. Sparkle installs nothing the private key in the
      login keychain did not sign, so a compromised host cannot push code.
      **Back that key up** — losing it means no existing install can ever be
      updated again.
- [x] Verified Apple notarizes a bundle with Sparkle's helpers inside, which is
      a common rejection point. Accepted, stapled, `spctl` accepts the dmg.
- [x] Version now comes from `MARKETING_VERSION`. It was hardcoded in
      `Sources/Info.plist` — a trap twice over, because that file is *generated*
      from `project.yml`, so edits to it vanish on the next `make gen`, and
      because a pinned version means Sparkle never sees a build as newer and no
      customer ever gets an update.
- [x] Disclosed in Settings with a switch and a "Check now" button. An app that
      updates itself unprompted *and* reads other apps' credentials is the exact
      shape security tooling flags; the disclosure is what separates a
      background updater from something hiding.
- [ ] **`SUFeedURL` is a placeholder.** Everything else works; this is the one
      value that cannot be guessed. Host `appcast.xml` and the dmg somewhere
      stable (GitHub Releases and Pages both do), then point this at the
      appcast. Gumroad is not suitable — its download links are per-purchase.
- [ ] Bump `CURRENT_PROJECT_VERSION` every release. Sparkle compares it, not
      the marketing string.

### Arriving with nothing connected

- [x] First launch opens Settings, once. An agent app has no dock icon and no
      window: installed and started, it puts three empty rings on a screen edge
      and gives no reason to look at them. `Preferences.isFirstLaunch` is a
      stored flag, deliberately not inferred from "no readings yet" — that is
      also true of someone who switched everything off, and re-introducing the
      app to them every launch is worse than never introducing it.
- [x] `SettingsWindowController.surface` uses `orderFrontRegardless`. Without it
      the window opened *behind* whatever the user was working in: an app with
      no dock icon is not always permitted to pull itself forward, and
      `makeKeyAndOrderFront` plus `activate` silently lost that argument.
- [x] A setup note when no provider has a credential, saying the app reads tools
      already signed in on this Mac and never asks for a password.
- [x] The sheet scrolls. Its height is not a constant — the setup note appears
      only for someone with nothing connected, and rows grow a line when a
      provider has no account, so the fixed height cut the closing explanation
      for exactly the new user it was written for.
- [x] Dropped the sign-in prompt for Perplexity, a provider that no longer
      exists and could only ever have confused someone reading it.

### Deleting the app leaves its data behind

macOS does not remove `~/Library` when an app is trashed, so a reinstall comes
back with the old readings, the old choices and the old first-run flag — which
is what makes a reinstall look like the app is broken.

- [x] **Reset Codenotch…** in Settings: clears the defaults domain, caches,
      WebKit and HTTP storage, then quits. Behind a confirmation, and the alert
      says what it does *not* touch — "reset" could reasonably be read as
      signing you out of Claude Code or Cursor, which it cannot do.
- [x] Not automatic on reinstall. A reinstall is indistinguishable from an
      update, and wiping data on every Sparkle update would be catastrophic.

### Changing which account is read

Codenotch cannot switch the account. The credential belongs to Claude Code,
Cursor or Codex, and the most this can honestly do is open the thing that owns
it and then notice when the answer changes.

- [x] **The account shown was frozen at launch.** `store.providerSummaries` was
      read once into a `let`, so switching account in Cursor left the old
      address on screen until the app was restarted — which looks exactly like
      the app being unable to see the new account. It is a closure now, re-read
      whenever the sheet takes focus: switching happens in another app, so the
      user is always coming *back* here, which is precisely when the old value
      is wrong.
- [x] `UsageStore.openAccountSource` — the same destination as signing in, but
      unconditional. `signIn` short-circuits when a credential already exists,
      which is right for connecting and exactly wrong for switching, since you
      switch *while* signed in.
- [x] A **Switch…** link on each connected row, plus `SignInRoute.switchHint`
      naming where the account actually lives.
- [x] Claude's guidance names `/login`, since Claude Code is a command with no
      app to open.

### Gemini, via Antigravity

- [x] `ProviderGlyph.gemini` — the four-point spark, four unit-radius arcs each
      centred on a corner of the square, which pinches the waist to
      `sqrt(2) - 1`. Generated rather than traced, like `cursor`: the design
      frame predates this provider so there is nothing to trace, and being
      generated it is exact at any size. `GeminiGlyphTests` asserts the four
      points and four waists instead of trusting the eye.
- [x] Reconnaissance, against a real install (Antigravity 2.11.0). It settled
      four things, and contradicted the guess this provider would have been
      built on:
      * State lives in **`~/.gemini/antigravity`**, not Application Support —
        that folder holds only the Electron shell's browser profile.
      * There is **no `state.vscdb`**. Antigravity is not shaped like Cursor,
        so the provider cannot be a copy of `CursorLocalProvider`, which is
        exactly what a speculative version would have been.
      * Usage comes from `https://cloudcode-pa.googleapis.com/v1internal`, and
        the call carrying plan and quota is **`:loadCodeAssist`**.
      * The credential is a keychain item, service `gemini`, account
        `antigravity` — the same borrow-don't-own shape as every other provider
        here.
- [x] `AntigravityCredentials` — keychain service `gemini`, account
      `antigravity`. Two things it must get right: Go's `keyring` package
      base64-encodes behind a `go-keyring-base64:` marker rather than storing
      raw JSON, so without stripping that the value is not JSON at all; and the
      expiry is RFC 3339 **with an offset**, not UTC and not epoch
      milliseconds. Reading the timestamp as either is how a live token reads
      as long expired, which `procStart` already cost this project once.
- [x] `AntigravityProvider` — POSTs `:loadCodeAssist` with
      `pluginType: GEMINI`. Not `ANTIGRAVITY`: that is rejected outright with
      "Invalid value at 'metadata.plugin_type'", because the wire name lags the
      product name.
- [x] **It reports no usage figure, on purpose.** `loadCodeAssist` answers with
      tiers — which plan you are on, which you are not eligible for — and no
      numbers at all: no used, no limit, no reset. A signed-in install makes
      exactly two RPCs and neither carries a quota. So the cell names the plan
      and says there is nothing metered, the same answer Cursor's free plan
      gets. A confident 0% would be worse than an admitted blank.
- [x] **Correction: Google does publish a usage figure.** Antigravity's own
      `language_server` binary lists `v1internal:retrieveUserQuota` and
      `:retrieveUserQuotaSummary`, with `QuotaSummaryBucket`, `QuotaLimit` and
      `QuotaInfo` message types. The earlier conclusion was drawn from watching
      which calls Antigravity happened to make, which only ever showed the ones
      it made at startup. Reading the binary is what found the rest.
- [x] Both quota RPCs answer **403 #3501, "You do not have a valid license of
      this product"**, on an empty body that the server otherwise accepts —
      sending `metadata` or `quotaId` is rejected with "Unknown name", so the
      request is right and the *entitlement* is what is missing. It agrees with
      `loadCodeAssist`, which already listed this account's free tier under
      `ineligibleTiers` with `UNSUPPORTED_CLIENT`.
- [x] The provider calls it anyway and parses the response, so a licensed
      account gets a real ring with no further work. The parser is written from
      the binary's message names rather than a real body, so it distrusts
      itself: no positive limit, or more used than the limit allows, and the
      bucket is dropped; an unfamiliar shape yields nothing and routes to the
      fallback rather than a ring built on a guess.
- [x] Searched the local files for a usage number, and there is none there:
      `loadCodeAssist` returns tiers only; `transcript.jsonl` carries
      `step_index`, `source`, `type`, `status`, `created_at`, `content` and no
      token counts; the conversation database has seven tables and not one
      token/usage/quota/limit column; `gen_metadata` is protobuf with no such
      fields; Electron storage is empty. The model call is
      `streamGenerateContent`, and whatever usage it returns dies with the
      stream. Claude, Cursor and Codex each publish a figure. Google does not.
- [x] `AntigravityActivity` counts what is left: model-answered steps in
      Antigravity's own transcripts, per local day. Only `source == "MODEL"`
      counts — user input and system checkpoints share the file and would
      inflate the number with work the model never did. `created_at` is UTC, so
      the day comparison is done on a local calendar; read as local it would
      drift counts across midnight by the offset, which is `procStart` all over
      again.
- [x] It is a **count, never a percentage**, and the ring stays empty. A
      fraction needs a limit, no limit is published, and a denominator we made
      up would put a confident ring on a guess.

### Gemini API key, via the tools' own logs

- [x] **There is no endpoint to ask.** A bare `GEMINI_API_KEY` is billed per
      token and Google publishes no usage or quota resource for one — unlike
      Claude, Cursor and Codex, which each answer with a figure. So this
      provider does not call anything. It adds up what the tools that spent the
      key already wrote down on this Mac.
- [x] **The key itself is never read**, and nothing here goes looking for it:
      not `~/.zshrc`, not an `.env`, not `opencode.json`, not `auth.json`, not
      the keychain. Knowing the key would not produce a number anyway, so
      reading it would be a prompt and a liability bought for nothing. The only
      credential-shaped thing touched is `~/.gemini/settings.json`, and only for
      `security.auth.selectedType`, which names *how* the calls were paid for.
- [x] Three sources, each with a **single definition of "tokens"** chosen from
      that tool's own source so nothing is counted twice:
      * **Gemini CLI** — `tokens.total` in
        `~/.gemini/tmp/<project>/chats/session-*.jsonl`. It is already
        input + output + thoughts + tool, and `cached` is a *subset* of `input`,
        so summing the parts would double-count the cache.
      * **OpenCode** — `tokens.total` from `opencode.db` when present and above
        zero, else `input + output + reasoning + cache.read + cache.write`.
        OpenCode's `input` excludes the cached part, so the components add up:
        a real row reads 96008 = 2834 + 51 + 17 + 93106 + 0.
      * **Hermes** — `input + cache_read + cache_write + output` from
        `session_model_usage`. Reasoning is **excluded here but not for
        OpenCode**, and that asymmetry is deliberate: Hermes's own
        `CanonicalUsage.total_tokens` counts reasoning inside `output_tokens`,
        so adding `reasoning_tokens` would bill those tokens twice, whereas
        OpenCode's `reasoning` is a separate quantity.
- [x] **The CLI's JSONL appends the same call twice.** Verified against Gemini
      CLI 0.58.0's bundled `ChatRecordingService`: a `gemini` record is written
      as soon as the answer starts, and written *again* with the same `id` once
      `usageMetadata` arrives. Read naively, 26 lines in a real session became
      26 calls where there were 15. So records are deduped by `id` with the last
      one winning, and everything else — the header line, `{"$set":...}` patches,
      `user` records, garbage — falls through.
- [x] **`{"$rewindTo":"<id>"}` is ignored on purpose.** Rewinding the
      conversation does not refund the call: those tokens were generated and
      billed. Honouring the rewind would make the notch quietly under-report
      exactly when someone is iterating hardest.
- [x] Buckets are **local month and local day**, not UTC. Every timestamp on
      disk is UTC, but the bill and the user's "today" are local, and the three
      rows in the tooltip have to agree on where the boundary is — so all three
      readers feed one routine, `GeminiTokenUsage.bucket`. Reading a UTC
      timestamp as local time here would repeat the bug `procStart` and
      `AntigravityActivity` each hit once already — the same mistake a third
      time.
- [x] Each reader pre-filters before it parses, because these files only grow:
      the CLI skips any session file whose modification date predates the start
      of the month (a file cannot hold records newer than its own mtime), and
      both databases push the same cut-off into SQL against the indexed time
      column. `json_extract` does the OpenCode filtering inside the system
      libsqlite3, so nothing extra is linked.
- [x] **Hermes rows are bucketed by `last_seen`**, whole. Its table stores one
      aggregate per session and model, not per call, so a session straddling
      midnight or month end lands entirely in the bucket of its last call. That
      is the same granularity Hermes's own `/usage` reports, and splitting it
      would mean inventing a distribution.
- [x] `.derived` with no budget, `.manual` once the user sets one. The ceiling
      in Settings is in **tokens, not money**: an API key publishes no limit, and
      prices change under an app that ships every few weeks, so a currency
      figure would go stale silently. Either way the tooltip keeps its `~` — the
      number is assembled here, not quoted from Google.
- [x] Counts are compacted for the ring (`651k`, `1.1M`). A 44 pt ring cannot
      hold seven digits, and below 10 000 the digits are printed verbatim so no
      existing request or credit count changes.
- [x] Busy detection watches **Gemini CLI only**, by modification date. The
      session file holds no pid, so `ProcessLiveness` has nothing to verify, but
      the CLI patches `lastUpdated` on every message — the same mtime substitute
      Antigravity and Cursor use. OpenCode's and Hermes's databases are written
      for reasons that have nothing to do with a Gemini call, so their mtimes
      would report work that is not this provider's.
- [x] **Two departures from the provider template**, both deliberate. The
      protocol extension's default `signInRoute` offers to sign in, and here
      there is nothing to sign into, so this provider overrides it with a
      `.guidance` message saying so and saying the key is never read; the
      default would have put a button in Settings that could only fail. And
      `lastTools` is `nonisolated(unsafe)` behind a `nonisolated func
      account()`, the bargain `GLMProvider.lastKnownPlan` already makes: the
      settings row asks for the account off the actor, and the worst a race can
      do is name yesterday's tools for one row-draw.
- [x] **The ring first shipped with the wrong mark.** `.antigravity` draws
      Antigravity's arch, not the Gemini sparkle — the arch is the editor's own
      logo, and the row next to it already wears it. The sparkle was sitting in
      `GlyphOutline.gemini`, generated and referenced by nothing since the
      Antigravity provider took the name. It could not simply reclaim the raw
      value `gemini`: that string is an archive key, so a new case
      `geminiSpark = "gemini-spark"` was added instead. A `gemini-api` snapshot
      archived before this change still decodes as the arch and draws it until
      the next poll overwrites it; one stale ring for one refresh is not worth a
      migration.
- [x] **Cloud Monitoring was considered and set aside.** It really does publish
      official per-project counters, including
      `generate_content_usage_output_token_count`, which would be a `.official`
      reading. It needs gcloud application-default credentials and a token
      refresh this app does not do, and the whole design here is to borrow a
      credential another tool already holds rather than to acquire one. Worth
      revisiting if the app ever grows a Google sign-in for another reason.

### Choosing how much the notch shows

- [x] Three modes, not the two asked for. The default is neither "always" nor
      "hidden" — at rest the notch is already a pill that opens on contact, and
      offering only the extremes would have deleted the behaviour the app was
      designed around. `NotchVisibility` is `alwaysShow` / `onHover` / `hidden`.
- [x] "Always show" is pinning. `setExpanded(false)` already refuses to fold a
      pinned notch, so the hover machinery needs no special case; it simply
      never gets its way.
- [x] Switching to "Show on hover" folds immediately rather than waiting for the
      pointer to leave — it may already be elsewhere, and then nothing would
      ever arrive to close it and the mode would look identical to "always".
- [x] "Hide" orders the panel out rather than making it transparent. An
      invisible panel still holding the screen edge would go on swallowing the
      pointer.
- [x] **An escape hatch, because hiding removes every way back.** No dock icon,
      no menu bar item and no notch leaves nothing to click.
      `applicationShouldHandleReopen` opens Settings, so launching the app again
      from Applications or Spotlight gets it back, and the Hide option says so
      in the sheet.
- [x] An unrecognised stored value falls back to `onHover`, never to hidden: a
      corrupt or future-written preference must not make a working install look
      like one that failed to start.

### The settings window's shape

- [x] One page of **grouped sections**: Integrations, The notch, Startup,
      Updates, Advanced. Tabs were tried first and reverted — they hid three
      quarters of the settings behind a click for an app with about a screenful
      in total. The grouping was what was missing, not the separation.
      A `Form` with `.formStyle(.grouped)` is what macOS itself uses, so each
      section is a titled rounded group and the whole structure is visible at
      once.
- [x] Reset is alone in its own section, and last. It used to sit a few pixels
      under a row of account switches, which is one slip from erasing
      everything.
- [x] The "Codenotch never signs in" explanation moved into Integrations,
      beside the switches it explains, rather than stranded under a page about
      something else.
- [x] 500 x 660. Without a row of tab titles to fit, the width is set by the
      account rows; the height by wanting Startup and Updates visible without
      scrolling, since four providers push everything below them a long way
      down. It still scrolls, because the content is not a constant — the setup
      note appears only for someone with nothing connected, and an account row
      grows a line when there is no credential to read.

### Before charging for it

- [ ] **`deploymentTarget` is macOS 26.0.** Nothing else on this list matters as
      much: it excludes every Mac not on the newest OS. Worth checking what
      actually requires it before shipping a paid build.
- [ ] App icon — the dmg currently shows the generic application icon.
- [ ] `MARKETING_VERSION` is still `0.1.0`.
- [ ] The archive keeps a `perplexity` entry from a provider that no longer
      exists. Harmless (snapshots are built from `providers`, so it is ignored)
      but it never gets collected.

## Renaming to Codenotch

- [x] Every occurrence renamed, including the bundle identifier
      (`com.vinz.codenotch`), scheme, target, test target and log subsystem.
      `UsageStore`, `UsageProvider`, `UsageBand` and friends keep their names on
      purpose: they are about *usage*, not about the app, and renaming them
      would be a rebrand leaking into the domain model.
- [x] **Settings migrate across the bundle id.** A bundle identifier *is* the
      name of the defaults domain, so renaming silently moved every choice to a
      new empty one — connections, the notch's mode, archived readings, all
      apparently lost. `Preferences.migrateFromPreviousName` copies the old
      domain once, guarded on `hasLaunchedBefore` being absent so it can never
      overwrite settings changed after the rename.
- [x] The app icon, generated from the 2000px artwork into all ten macOS sizes.
      Inset to 824 within a 1024 canvas: that is the macOS icon grid, and used
      full-bleed it would sit visibly larger than every neighbour in the Dock.
- [ ] `/Applications/UsageNotch.app` is still installed. Nothing removes it —
      the new build is a different app as far as macOS is concerned.
- [ ] The Sparkle feed still points at `vinzdg.github.io/usage-notch/`. Valid
      while the repo keeps that name; rename the repo and this must follow.
- [ ] The keychain will prompt again on first run. The ACL is keyed on the
      app's designated requirement, which contains the bundle identifier, so a
      renamed app is a different applicant even with the same signature.

## Which edge the notch lives on

- [x] `NotchEdge` — right (the default), left, top or bottom, stored like
      `NotchVisibility` and switched from a segmented picker beside it.
- [x] `NotchPlacement` — the one place that knows which way round the axes are.
      Everything else works in **stack space**: `along` runs the length of the
      provider stack, `across` measures *inward from the bezel*, so zero is
      always the screen edge. `NotchLayout` needed almost no change for this —
      its maths was already one-dimensional, it just called that dimension Y.
      The renames (`bodyDepth`, `shapeLength`, `ringCenter`, `slack(for:)`) say
      out loud what was already true.
- [x] The notch is pinned to **`visibleFrame`**, not `frame`, so it rests on top
      of the Dock and below the menu bar rather than behind them — and moves
      when the Dock hides. Centring along the other axis stays on `frame`: a
      Dock at the bottom is nowhere near a right-edge notch, and centring on the
      visible area would slide that notch up and down every time the Dock hid
      itself, for no reason anyone could see.
- [x] `SideNotchShape` is still written once, for the right edge, and
      transformed onto the others. Four hand-written variants would mean four
      copies of the corner-versus-flare clamping, and three of them would never
      be the one under the cursor when it broke.
- [x] **Moving between edges is faded across, not cut.** Changing the placement
      moves the panel, turns the shape on its side and relays the whole stack in
      one frame. Done in view that is a jump no animation can smooth over, and
      animating a panel across a corner reads as a bug rather than a choice — so
      the notch goes out where it was, crosses while there is nothing to see,
      and then **opens** where it now is — the same unfold hovering uses, so a
      move ends the way reaching for it does rather than with a bar appearing at
      full size. A sequence token guards it, because clicking through the picker
      starts a move before the last has landed and a stale completion would drop
      the notch on an edge the user had already moved on from.

      Two things the sequencing depends on. It lands at **full alpha**, folded —
      the opening is the animation, and fading in underneath it would be two at
      once. And there is a real beat between landing and opening: set shut and
      open again inside one turn and SwiftUI coalesces the pair, nothing
      interpolates, and the notch arrives at full size having animated nothing.
      Traced, rather than assumed: fade out to t=0.16, land folded at 0.165,
      open at 0.226.

      The stored edge is applied to the model *before* the panel is first shown.
      The preference sink delivers on the next run loop turn, by which time the
      notch is already up on the default edge — so without that, every launch on
      any other edge opened with a flash of the right-hand one and then
      crossfaded away from it.
- [ ] Per-screen placement, drag-to-place, remembering a placement per Dock
      position. Deliberately out: one global choice, like the visibility mode.

### Turning the stack is not a rotation

Four cells stacked vertically make the notch 401pt long, so a top or bottom
notch has to lay them out side by side. That is a second layout, not the first
one turned, and two things follow that pure rotation would have got wrong:

- **The notch is deeper.** The percent label sits below its ring. Down a side
  edge that spends the stack's *length*. Across a horizontal one the label has
  nowhere to go but into the notch's *depth*, and the frame's 70pt no longer
  fits a ring, a gap and a line of type. `bodyDepth(for:)` is a function for
  this reason.
- **The ring sits somewhere else in its cell.** On a side edge the ring leads
  the cell and the label follows it down; on a horizontal one the label is out
  of the way, so the cell is the ring alone and the ring sits in its middle.
  Get this wrong and the drawn rings stop lining up with the centres
  `ringCenter` hands to the hover bands and the tooltip tails — everything
  still *works*, it is just pointing at the wrong provider.

- **A cell claims less of the stack.** `cellExtent` is the ring, the gap and
  the label — all three of which are on the stack when it runs down a side edge.
  Across a horizontal one the label has moved into the depth, so the cell is the
  ring alone. Keeping the vertical figure so the pitch would match was the wrong
  instinct: it leaves 27pt of nothing between every pair of rings, *on top of*
  the `cellSpacing` the frame already puts there, and the top and bottom bars
  read as far too spread out. `cellAlong(for:)` is what a cell actually claims,
  and `testTheGapBetweenRingsIsTheFramesSpacingOnEveryEdge` pins the thing that
  matters — the clear space between two rings is the frame's own spacing,
  whichever way the stack runs. Four readings across: 445pt down to 336pt.

The tooltip also needs its room somewhere new. Beside the stack it needed none
at the ends; below it, centred on its cell, half a card has to fit past each
end or the first and last providers' cards are clipped. That is what
`slack(for:)` is doing, and `testTheCardFitsThePanelAtEveryCellOnAHorizontalEdge`
is what fails if it stops being enough.

### Becoming the Mac's own notch

A top-edge notch that stops below the menu bar reads as a bar parked under the
hardware rather than as part of it. On a Mac that has a notch of its own, this
one now runs up to the true top of the screen — `panelFrame` anchors to
`frame.maxY` rather than `visibleFrame.maxY` when `NSScreen` reports one. Where
there is no notch to join, it still sits below the menu bar: covering menu items
buys nothing there.

`NSScreen` never states the notch directly. `auxiliaryTopLeftArea` and
`auxiliaryTopRightArea` are the two menu-bar strips *either side* of it, so the
width is what is left over, and `safeAreaInsets.top` is the height. On this
machine: **220 x 38pt**.

**The shape becomes the hardware notch's shape**, which took two wrong turns to
arrive at. The flares — the inverse curves that make this shape read as growing
out of an edge — are exactly wrong here: a MacBook's notch does not taper. It is
a straight-sided black rectangle hanging from the top with two rounded bottom
corners. So a flush top notch drops the flares entirely (`SideNotchShape.flush`,
which is just `flare: 0` through the same path) and keeps only the corner
rounding on its inner face. The display's own notch then stops being a separate
object inside ours and the whole thing simply looks *wider and deeper*.

The two wrong turns are worth recording, because both looked reasonable:

- **A full-width slab across the hardware's band, flares below it.** Widest at
  the very top and tapering down — the opposite of the hardware's silhouette. It
  read as a rectangle stuck on top of a notch.
- **A column of the notch's exact width, fillets opening outward, then the bar.**
  Geometrically a lovely join, and completely wrong: it makes the notch look
  like it has grown a *separate* wider bar underneath, rather than like the
  notch itself being bigger.

Three things still have to follow:

- **The hardware's band is a hole in the screen.** Pixels there are not dimmed
  or clipped, they are not on the display. `contentInset` pushes every reading
  below it and the shape grows deeper by the same amount — including folded, or
  the resting pill would be a 10pt sliver drawn inside a 38pt hole.
- **The bar has to be wider than the hardware.** A single ring makes a shape
  about 194pt across against a 220pt notch: the hardware would stick out either
  side of the thing that is supposed to be it. `endSpread` widens it to the
  notch plus a corner radius at each side, evenly, so the readings stay centred.
- **The corner holds its size as it opens.** `canonicalPath` clamps the corner
  to half the *current* depth, which is right for a shape that only ever has
  one size and wrong for one that grows. At the hardware's own 38pt the clamp
  bites at 19pt, so the resting shape is nearly a pill at its foot and opening
  it reads as a rounded tab morphing into a bar rather than the notch
  stretching. `joining` caps it at half the hardware's height instead — the most
  the resting shape can carry — so every frame of the expansion is the same
  shape, only bigger. The cap also has a floor of its own: a corner *squarer*
  than the hardware's would poke the resting shape's corners out past the hole
  and show them as two nubs either side of the notch.

  Everything the orb does then hangs off `drawnCornerRadius` rather than the
  nominal `cornerRadius`. It traces the corner that is drawn, not the one that
  was asked for.

- **The settings orb loses the pocket it lived in.** It normally nestles into
  the cutout the far flare makes: concentric with it, one `orbGap` inside, and
  surrounded by the notch's own black on two sides. A flush bar has no cutout —
  its far corner is convex — so an orb centred there sits *inside* the black,
  which is exactly where the gear was appearing. It hangs off that corner
  instead, `orbCornerOffset` away on each axis: clear of the corner by the same
  gap, plus its own radius so the disc never overlaps the bar, taken diagonally
  so it reads as belonging to the corner rather than to one edge. The resting
  arc keeps its radius and faces the other way — `restingTrim(for:convex:)` is
  the same quadrant through half a circle.

  The arc, though, stays back on the corner: tracing the notch's contour is its
  whole job, and pushing it out with the button leaves it floating away from the
  thing it is meant to trace. So on a flush bar the two part company — which
  they never do inside a flare's pocket, where the arc is simply the outer edge
  of the same orb. The handle's hit region became the union of a zone around
  each, since the arc is what you can see and the button is what you are
  reaching for, and one zone cannot cover both.

  And it has to turn about the point the corner *actually* turns about. The
  shape's body starts a flare in from each end, and the corner is rounded off
  that body — not off the shape's outer bound. Subtracting only the corner's
  radius slid the arc a whole fillet along the bar, and the gap it is supposed
  to hold opened from 9pt at one end to 19pt at the other, which is what stopped
  it reading as a curve drawn around the corner. `ArcConcentricityTests`
  measures that gap off the drawn path at ten angles rather than restating the
  formula — restating it in two places is how the error survived as long as it
  did.

  Worth knowing: out there the button is a black disc on whatever happens to be
  behind it, where the flared version always had the notch's black around it. On
  a light background it reads well; on a dark one only the gear does.

**Moulded into the frame, not cut out of it.** A bar that meets the screen's
top edge with a raw square corner reads as pasted on. `bezelFillet` puts a small
inverse corner at that join — deliberately a fraction of `curlRadius`, since a
full flare is what made the first two attempts taper into something that was not
the hardware's shape at all. `testTheFrameCornerBarelyNarrowsTheBar` pins that
distinction: it may take at most a tenth of the bar's width.

**And the readings sit the frame's own margin below the hardware.** The
hardware's bottom edge *is* the bezel as far as the contents are concerned, so a
ring clears it by `ringMargin` — exactly the distance it sits from the screen
edge on every other placement. Nothing on top of that.

Getting there took an over-correction. The real fault was a bug: the cells were
`.overlay(alignment: .leading)`, which *centres* on the cross axis, so making the
shape deeper to clear the hole simply centred the contents in the deeper shape.
They sat 19pt from the top instead of 38, and the top of every ring was inside
the hole. The fix is the alignment — the overlay now aligns to the corner where
the stack starts *and* the bezel is, then pads by `contentInset` — but a
deliberate extra gap went in alongside it, and once the alignment was right that
gap was padding the readings twice, leaving them adrift of the notch they belong
to. It has gone.

`testTheHardwaresBandHoldsNothingButBlack` renders the real view and checks that
nothing but black is drawn in that band, which is the only way to catch the
alignment fault — the arithmetic was right the whole time.

**Folded away, it becomes the hardware notch.** The resting pill is the wrong
object on this edge: it hangs below the hardware as a separate little tab, which
is the very seam the placement exists to remove. So where a display notch is
being joined, the fold target is that notch's own width and height. On a real
display that means the app shows *nothing at all* at rest — it is the notch —
and reaching for it makes the notch itself grow wider and deeper. The hit region
follows from the resting shape rather than from the pill, plus the usual
generous band, because either one is a small target on a screen edge.

**And it reserves only what it draws.** `shapeLength` had a whole `curlRadius`
of flare allowance at each end baked into it, which is right for a notch that
flares out to the bezel and wrong for a flush one that draws only the small
frame corner. The difference — some 56pt across the pair — was dead black
either side of the readings, and it is what made the top bar look too wide.
`flare` is now what the ends actually take, and `testItReservesOnlyWhatItDraws`
measures the drawn path against the reserved figure rather than trusting either.

Worth saying plainly: on a notched Mac in "show on hover" this leaves no visible
indication the app is running. That is the intent — the notch is a natural thing
to point at — but it is a real trade-off, and "always show" is the answer for
anyone who wants the readings on screen.

A note for whoever debugs this next: **the hardware notch does not appear in
screen captures.** macOS draws the menu bar across the full width and the hole
hides the middle, so `screencapture` shows menu-bar background there. A
screenshot can prove our shape reaches y = 0; the join itself has to be looked
at on the actual display.

### The lone ring that was not in the middle

Spotted by eye, not by a test: with one provider, a horizontal notch had
visibly more space to the left of the ring than to the right. 7.3pt of it.

`padTop` and `padBottom` are not the same number and down a side edge they
should not be — `padTop` is the body's top to the first *ring*, `padBottom` is
the last *label* to the body's foot, so they are padding different things.
Turned horizontal, the label is no longer on this axis and both ends pad the
same thing: a cell. Carrying the difference over was meaningless, and it pushed
the whole stack off centre. With four rings it read as a slightly heavy left
end; with one it was just wrong.

`padStart(for:)` / `padEnd(for:)` keep the frame's two numbers down a side edge
and use their mean across a horizontal one, so the bar is exactly as long as it
would have been and the content sits in the middle of it.

### The window that shrank itself to nothing

The first working build drew the notch perfectly on the left and right and
**nothing at all** on the top and bottom — and the app died a few hundred
milliseconds after launch. The panel's frame was right in the log, the layout
maths was right in every unit test, and rendering `NotchRootView` headlessly
with `ImageRenderer` produced a correct picture on all four edges. So the view
was fine and the geometry was fine, which left the window.

Logging the frame after every `setFrame` and on every `didResize` showed what
was actually happening: after the last frame *we* asked for, the window walked
itself down in steps nobody requested — 522pt of height to 266, to 10, to zero,
losing 51pt of width each time — and then AppKit threw "more Update Constraints
in Window passes than there are views in the window" and took the process with
it. It was converging on 10x10.

10x10 is `GeometryReader`'s ideal size. Setting an `NSHostingView` as a window's
`contentView` gives SwiftUI a say in the window's frame, and this view's root is
a `GeometryReader`, so the size it advertises is meaningless. On a tall narrow
panel that never surfaced; on a wide shallow one AppKit acted on it.

The fix takes the channel away rather than arguing with it: `NotchContainerView`
is the content view and the hosting view lives inside it on an autoresizing
mask. The panel's size comes from `NotchGeometry` and from nowhere else, which
is what every hit region in `NotchWindowController` already assumed. The
container forwards `hitTest` to its subview and never answers for itself — a
plain `NSView` claims every point in its bounds, and most of this panel is empty
space reserved for the tooltip, so that would have turned the hole the notch
depends on into a wall.

### The orb had to turn too

The settings arc is a segment of the **same circle the far flare curves
around**, one gap inside it — that is what makes it follow the contour of the
edge instead of sitting near it. So the quadrant it occupies is not decoration:
it faces back along the stack, toward the notch it hangs off, and outward,
toward the bezel it merges into. On the right edge that is twelve o'clock round
to three. `OrbOrientationTests` pins those two directions rather than the four
numbers, so the reason survives the next person to touch it.

## Why the icon was not in the Dock

Not an icon problem at all: the app had no Dock tile for an icon to sit on.

- [x] `NSApp.setActivationPolicy(.regular)` in `AppDelegate`. **This line, not
      the Info.plist, is what decides.** It is applied at launch and overrides
      `LSUIElement` either way — removing the plist key alone left the app still
      registered as a `UIElement`, with no Dock tile, which looked exactly like
      the icon having failed to install. `lsappinfo` now reports `Foreground`.
- [x] `LSUIElement` removed from `project.yml` as well, so the two agree.
- [x] `applicationShouldTerminateAfterLastWindowClosed` returns false. A Dock
      app quits by default when its last window closes, which here would kill
      the notch — the actual product — every time someone shut the settings
      window they had just opened.
- [x] Clicking the Dock icon opens settings, via the `applicationShouldHandle
      Reopen` hook added for the Hide option. The notch stays where it is.

## Decisions needed
- [ ] Final app name (`Codenotch` is a placeholder)
- [x] ~~Which service is the third glyph in the mockup?~~ Perplexity — its mark,
      traced off the frame, matches. Wired up as `ProviderGlyph.third`.
- [ ] Plan ceilings: configured by hand, or inferred from observed peak usage?
- [ ] Are web-session adapters (ChatGPT et al.) in scope for v1, accepting the fragility?
      Claude now answers this for itself: the OAuth endpoint is in, so the same
      question is live for OpenAI and Perplexity.
- [ ] `Design.scale` — the frame fixes only proportions, so the absolute size is
      a free parameter. It is anchored on the spec's 44pt ring, which puts the
      notch at 70 x 401pt. One constant changes it.

## Corrections to the spec

The frame is the source of truth and it disagrees with the prose spec in three
places. The code follows the frame:

- **Colour bands.** The spec's table says 50–79% is yellow, then says the mockup
  "shows exactly this: 73% orange". Both cannot be true. The frame renders 21%
  green, 52% yellow, 73% orange, so the thresholds are 50% and 70%.
- **Hexes.** Sampled from the frame: track `#303030` (bars `#2D2D2D`), green
  `#00FF88`, yellow `#F2FF00`, orange `#FF3F00`. The spec lists `#3A3A3A`,
  `#28E07B`, `#F5E400`, `#FF4500`.
- **Card fill and radius.** `#000000` at 18.5pt, not `#0A0A0A` at 16pt.
- **Which window the ring shows.** The spec asks for the *most-constrained*
  window — whichever limit is highest. In practice that made the headline number
  silently change meaning: session 22% / weekly 24% showed 24, then session 27% /
  weekly 24% showed 27. A number that means one thing beats a number that is
  occasionally more alarming, and Claude's own usage panel always leads with the
  session, so the two now agree. The ring shows `windows.first`, which is the
  same row the tooltip lists first; every window is still in the tooltip. The
  cost, accepted deliberately: a weekly limit creeping up gets no headline
  warning.

One place the code deliberately does *not* follow the frame: the frame's tooltip
reads "73% Used", but the spec requires a "~" on any number the app derived
rather than read from a vendor. The fixture is `.derived`, so it renders
"~73% Used".
