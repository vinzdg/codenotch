# Provider plugins — design

2026-09-18 · status: prototype

## Context

Codenotch's providers are compile-time: every adapter is a Swift class behind
`UsageProvider`, listed once in `AppDelegate` and handed to `UsageStore`. That
makes a new provider a pull request against the app — fine for Claude or Codex,
wrong for vendor tooling that has its own release cycle and its own credentials.

The motivating case is CodeMie (`codemie-ai/codemie-code`): its CLI manages
agents (`codemie-claude`, …) behind enterprise SSO, and its Claude statusline
shows live budget from the CodeMie backend (spend is metered by LiteLLM).
CodeMie wants a `codemie-codenotch` command that registers itself, after which
Codenotch renders CodeMie budget and per-bucket spending natively — ring,
tooltip, settings row, notifications — without CodeMie code living in this repo.

## Decision

**Out-of-process plugins: a manifest registers a provider; Codenotch executes
the plugin's CLI on each poll and renders the JSON it prints.**

A plugin is a directory in
`~/Library/Application Support/Codenotch/Plugins/<id>/` containing a
`plugin.json` manifest and its assets (glyph image). The vendor's installer
writes that directory — that *is* registration; deleting it is unregistration.
Codenotch scans the directory at launch and watches it with a `DispatchSource`,
so register/unregister take effect while the app runs.

For each valid manifest Codenotch instantiates one `ExternalPluginProvider`, an
actor implementing `UsageProvider`. Each poll spawns
`<exec.path> <exec.args>` with null stdin and a watchdog, parses a JSON
snapshot payload from stdout, and maps it to a `ProviderSnapshot` — after which
the entire existing pipeline (ring, tooltip money rows, ordering,
connect/disconnect, threshold/reset/limit notifications, status-item menu,
phone projection) works unchanged, because it is all keyed off the string id
and the snapshot shape.

The full manifest schema and wire protocol are specified in
[`docs/design/plugin-protocol.md`](../design/plugin-protocol.md); that document
is the contract third parties implement against.

### What a plugin never does

- **Run code inside Codenotch.** No dylib loading — a plugin crash is a failed
  exec, not an app crash, and the hardened runtime's library validation never
  comes into play.
- **Hand its credentials to Codenotch.** The plugin process reads whatever it
  needs (CodeMie's SSO files, in the prototype) and only numbers cross the
  boundary, on stdout. Codenotch's keychain prompts and credential caches are
  untouched.
- **Draw UI.** The plugin declares windows, money, resets, an account and a
  glyph asset; Codenotch renders everything with the same components as the
  built-ins, so a plugin cannot look alien — and cannot draw at all when its
  numbers make no sense (it says `needsAuth` instead).

### Trust model

Plugins execute with the user's privileges, exactly like the CLIs the app
already spawns (`claude`, `kiro`, cursor-agent). Registration requires write
access to the user's own `Application Support` directory, which any user-level
installer already has — the manifest channel grants no new privileges.
Manifests are validated before use: schema version, id shape
(`^[a-z0-9][a-z0-9-]*$`), no collision with a built-in provider id, `exec.path`
absolute and executable, glyph file present.

## Alternatives considered

**Loopback HTTP push.** The plugin (or a hook) POSTs snapshots to a server in
the app — the pattern of the Windows `codenotch-hook` and the two SwiftNIO
servers already in this codebase. Rejected as the primary channel: it needs a
long-running plugin daemon, port management, and a request-auth story, while
Codenotch polls on its own cadence anyway and a pushed number would wait for
the same render pass as an exec'd one. A small loopback "nudge" endpoint
(asking Codenotch to refresh one provider now) remains a compatible future
addition — the manifest is the registry either way.

**In-process bundle plugins.** `NSBundle` loading of vendor dylibs. Rejected:
the hardened runtime requires same-Team-ID signatures on every loaded dylib,
and a vendor bug would take down the app. The trust boundary also stops being
explainable.

## Design

### Lifecycle

1. `PluginRegistry` scans the plugins directory at launch, validates each
   `plugin.json`, loads glyph images into `PluginGlyphStore`, and reports the
   valid set. Launch-time results join the `reconcile(discoveredIDs:)` call so
   ordering and connection state reconcile exactly like built-ins.
2. `PluginCoordinator` (AppDelegate-owned) turns each manifest into an
   `ExternalPluginProvider` and calls `UsageStore.register`. A plugin id never
   seen before is connected by default — registering a plugin is an explicit
   user act, unlike discovering a `~/.claude-work` directory — by
   `preferences.setConnected(true, for:)`; a toggle-off afterwards persists
   through the normal `connectedProviders` mechanism.
3. The registry watches the directory. A manifest appearing, disappearing, or
   changing produces register/deregister pairs: `UsageStore.deregister` drops
   the provider, its snapshots, its archived reading, and any in-flight fetch;
   ordering keeps the id so a reinstalled plugin returns to its slot — the same
   semantics as a vanished Claude profile.
4. A manifest may declare `activity: { "type": "claudeSessions", "configDir" }`.
   The coordinator then attaches the existing `ClaudeSessionMonitor`
   (`<configDir>/sessions` + `<configDir>/projects`) under the plugin's id via
   `ActivityCoordinator.setMonitor(_:for:)`, so live sessions spin the plugin's
   ring and flip the store to fast polling — the same treatment a built-in
   Claude profile gets.

### The provider

`ExternalPluginProvider` is an actor (cloud providers fetch off the main
thread; a wedged plugin must not stall the UI — the store's `refreshDeadline`
essay applies unchanged). It implements every `UsageProvider` requirement:

- `fetchSnapshot()` spawns the process (injected closure in tests, the
  `ClaudeUsageCLI` pattern), maps exit codes to `UsageProviderError`
  (`3` → `needsAuth`, `4` → `rateLimited`, `5` → `nothingMetered`, other →
  error with the stderr tail), parses the payload into a `ProviderSnapshot`
  whose `id`/`displayName`/`glyph` come from the manifest, never from the
  wire — a plugin cannot rename itself underneath its settings row.
- `account()` returns the account from the last successful payload, so the
  settings row shows whose numbers these are (CodeMie's `userEmail`).
- `signInRoute` is `.guidance(manifest.signIn.guidance)`; `presentSignIn()`
  additionally spawns `manifest.signIn.run` detached when declared, so
  "Sign in" on the settings row can kick off `codemie profile login`.
- `signOut()` / `forgetCachedCredential()` are no-ops: the credential belongs
  to the plugin, and Codenotch holds nothing of it.

### The glyph

`ProviderGlyph` is a closed `Codable` enum persisted inside `UsageArchive`, so
it cannot grow per-plugin cases without corrupting archives on downgrade. One
new case — `external` — is added instead. Wherever a glyph is drawn,
`ProviderGlyphView` now also takes the provider id; for `.external` it resolves
the image from `PluginGlyphStore` (loaded from the plugin directory,
template-rendered, per-`opticalScale` from the manifest), falling back to a
generic puzzle-piece SF Symbol when the plugin is gone but an archived reading
remains. Glyph rules for plugin authors (monochrome, template, ink-boxed) are
the same as for built-ins — see `docs/design/provider-assets.md`.

### Error and staleness behaviour

Nothing new is invented: exec failures flow through
`UsageStore.status(for:)` into the existing statuses. A plugin that exits `3`
gets the needs-auth treatment (placeholder + sign-in guidance in settings); a
crash or timeout degrades to the last good reading marked stale, exactly like a
built-in provider whose endpoint is down.

## The prototype plugins

The plugin ships with its vendor, not with Codenotch: the CodeMie CLI
(`codemie-ai/codemie-code`) carries a hidden `codemie codenotch snapshot`
bridge command, and `codemie install codenotch --budget-plugin` installs this
app and registers two providers whose exec is the CLI itself. Nothing extra
is built or installed — the bridge rides the CLI's normal npm release cycle
and reads CodeMie's own config and SSO credential store first-hand.

- **`codemie-budget`** — the CodeMie budget card. Reads
  `~/.codemie/codemie-cli.config.json` (`CODEMIE_HOME` override) for the active
  profile's `baseUrl`, `workspace.codeMieUrl` and `userEmail`; authenticates
  with CodeMie's own SSO credential store
  (`~/.codemie/credentials/{sso|jwt-sso}-<sha256(codeMieUrl)>.enc`,
  AES-256-GCM with the legacy CBC fallback, key derived from
  hostname+platform+arch exactly as CodeMie's statusline does — note
  `os.hostname()`, not `ProcessInfo.hostName`, whose `.local` Bonjour form
  derives the wrong key); calls
  `GET {baseUrl}/v1/analytics/budget_usage` — the statusline's endpoint — and
  renders every budget bucket on the account as a money window, led by a
  synthesized **Total budget** headline summing them (spent, remaining and the
  earliest reset date).
- **`codemie-claude`** — a Claude-family card fed by the same SSO profile:
  every budget row belonging to the account becomes a window
  (`bucket-cli` headline — the bucket `codemie-claude` sessions spend from —
  plus platform/premium buckets), so session spending shows the way the usual
  Claude provider shows its session window. Its manifest declares
  `activity: claudeSessions` on `~/.claude`, because `codemie-claude` execs the
  real Claude Code, which files sessions there — live activity and spending end
  up on one ring.

Both share config, credential and HTTP code; a 60 s on-disk cache
(`~/.codemie/codenotch-budget-cache.json`, own schema) keeps the app's polling
cadence from hammering the backend, mirroring the statusline's caching.

## Testing

- Main app, swift-testing (`Tests/Plugin*Tests.swift`,
  `Tests/ExternalPluginProviderTests.swift`, `Tests/UsageStorePluginTests.swift`):
  manifest validation, payload→snapshot mapping, provider exit-code mapping,
  the real spawn incl. timeout kill, registry scan/watch, store
  register/deregister, `.external` glyph Codable round-trip. Swift-testing
  rather than the house XCTest for one environmental reason: this workspace
  has no Xcode.app, and the Command Line Tools ship no `XCTest.framework`, so
  XCTest files cannot even compile here — while swift-testing runs both via
  CLT `swift test` and inside the Xcode test target CI uses. The rest of the
  suite is untouched XCTest.
- Plugin package, SwiftPM tests: config parsing, credential decrypt
  round-trips (GCM + CBC, host-derived key), budget-row matching, snapshot JSON
  shape per provider, exit codes without auth, cache TTL/stale behaviour, and
  register validity/idempotency.
- Cross end-to-end (machine-local recipe): fixture `CODEMIE_HOME` with
  GCM-encrypted SSO credentials + an HTTP stub serving `budget_usage` →
  `codemie-codenotch register --plugins-dir /tmp/...` → the app's own
  `PluginRegistry` scans and validates both manifests, glyphs load into
  `PluginGlyphStore`, and `ExternalPluginProvider` spawns the real binary to
  rendered snapshots (exact money windows for both providers, plus the
  exit-3 → `needsAuth` path). The harness lives in `.local-build/LocalE2E/`
  (untracked scratch build), not in the committed suite, because it depends on
  a built plugin binary at a machine path.

## Out of scope for the prototype

Loopback refresh-nudge endpoint; plugin-supplied settings UI; encrypted
transport (nothing listens on a network); signing/notarization and
distribution of plugin binaries; a Windows port of the plugin runtime.
