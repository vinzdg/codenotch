# Plugin System Hardening — Design

Date: 2026-09-19
Status: Approved (design), pending implementation plan

## Background

A security review of the external plugin system (`Sources/Plugins/`) found that
any process running as the user can drop a `plugin.json` into
`~/Library/Application Support/Codenotch/Plugins` (or `CODENOTCH_PLUGINS_DIR`)
and have it picked up within ~0.5 s, auto-connected, and executed on every
refresh under Codenotch's identity. Concretely, in the current code:

- `PluginCoordinator.apply` auto-connects never-seen plugin ids
  (`PluginCoordinator.swift`), no consent step.
- `PluginManifest.validated` only checks `exec.path` is absolute, exists, and
  is executable — `/bin/sh` with `-c …` args passes. `signIn.run` is spawned
  with no validation at all (`ExternalPluginProvider.presentSignIn`).
- `spawnSync` never sets `process.environment`, so the child inherits
  Codenotch's whole environment (e.g. `GITHUB_TOKEN`).
- The timeout comes from the manifest with no ceiling; the watchdog only sends
  SIGTERM, and both pipes are read with unbounded `readDataToEndOfFile()`.
- `displayName` is unconstrained; `glyph.image` is joined with
  `appendingPathComponent` so `../` escapes the plugin folder; `manageURL`
  from the plugin payload reaches `NSWorkspace.open` unchecked.

This design implements the reviewer's full requested hardening list in one
pass, structured as extensions to the existing types (no new policy module).

## Decisions (from brainstorming)

- Approval UX: **Settings row only** — pending plugins appear as disabled rows
  labelled "Plugin" with exec path and hash; no modal, no notification.
- Approval hash: **SHA-256 over `plugin.json` bytes + exec binary bytes** —
  a silent binary swap re-triggers approval.
- Structure: extend `PluginManifest`, `PluginRegistry`,
  `ExternalPluginProvider`, `Preferences`, Settings in place.

## 1. Trust & approval

- New persisted store `pluginApprovals: [String: String]` (plugin id → pinned
  hash) in UserDefaults, accessed through `Preferences` alongside
  `connectedProviders`/`seenProviders`.
- Pinned hash = SHA-256 of the concatenation of the `plugin.json` file bytes
  and the exec binary file bytes. Computed on every scan result (registry
  already re-validates on every directory event, so hashing rides that path).
- `PluginCoordinator.apply` no longer calls `preferences.setConnected(true, …)`
  for novel plugins. For each added/changed plugin:
  - hash matches the stored approval → register `ExternalPluginProvider`,
    honor the existing connected toggle as for any provider;
  - otherwise → do **not** register the provider; expose the plugin as
    *pending approval* to Settings.
- Pending-approval rows in Settings are visibly labelled **"Plugin"** and show:
  displayName, id, full exec path + args, truncated SHA-256 (copyable in
  full), and an **Enable** button. Enabling pins the hash in
  `pluginApprovals`, marks the provider seen, and connects it.
- Any change to manifest or binary changes the hash → plugin returns to
  pending and its provider is deregistered until re-approved.
- Approvals persist across plugin removal/reinstall (identical hash =
  identical code, no re-prompt). Toggling a plugin off remains the ordinary
  connected toggle and does not revoke the approval.
- The launch path (`AppDelegate`'s initial provider array, fed from a launch
  scan) goes through the same approval check — no bootstrap bypass.

## 2. Folder & override trust (`PluginRegistry`)

Scan-time checks, fail closed with a logged reason:

- Refuse the plugins root and each plugin subdirectory that is a symlink,
  group/world-writable, or not owned by the current user.
- Same checks for `plugin.json` and the exec binary: not a symlink, owned by
  the current user, not group/world-writable.
- `CODENOTCH_PLUGINS_DIR` is honored only in `DEBUG` builds. Release builds
  ignore it and log once.

## 3. Execution hardening (`ExternalPluginProvider`)

- Child environment is replaced with an allowlist: `PATH`
  (`/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin`), `HOME`,
  `USER`, `LOGNAME`, `LANG`, `TMPDIR`. Nothing else is inherited. The same
  environment applies to `signIn.run` spawns.
- Timeout clamped to a 30 s ceiling (`min(manifest timeout, 30)`; default
  stays 20 s). On expiry: SIGTERM, then SIGKILL after a 2 s grace.
- Output caps: stdout 1 MB, stderr 64 KB, read in chunks instead of
  `readDataToEndOfFile()`. Exceeding a cap SIGKILLs the child and maps to an
  error (`badResponse` for stdout overflow, `PluginExecError.failed` for
  stderr overflow).
- `signIn.run` is validated like `exec`: absolute path, exists, executable,
  not a symlink, not group/world-writable. Validation happens in
  `PluginManifest.validated`.

## 4. Field validation (`PluginManifest`, `PluginSnapshotPayload`)

- `displayName`: trimmed; must be 1–40 characters; no control characters or
  newlines; rejected if it case-insensitively matches a built-in provider's
  display name. New `ValidationError` cases.
- `glyph.image`: the path is standardized and resolved (including symlinks);
  the result must stay inside the plugin directory — `../` escapes and
  symlink escapes are rejected. Existing existence check stays.
- `manageURL` (`PluginSnapshotPayload.providerAccount()`): only `https` URLs
  survive; anything else becomes nil before reaching `NSWorkspace.open`.

## 5. UX label, docs, tests

- All plugin rows in Settings (connected and pending) carry a "Plugin" badge
  so they never read as built-ins.
- `docs/design/plugin-protocol.md` updated: approval requirement, env
  allowlist, output caps, timeout ceiling, field validation rules.
- Tests (the project has an existing plugin test suite to extend):
  - new `PluginManifest` validation errors (displayName, glyph escape,
    signIn.run, folder/exec writability);
  - `PluginRegistry` rejection of symlinked / group-writable / non-owned
    folders using temp directories;
  - approval pin → register, hash change → re-pend flow;
  - env allowlist contents, timeout clamp, output-cap kill, SIGTERM→SIGKILL
    escalation (real spawns only where fast and deterministic, e.g.
    short-lived `/bin/sh` helpers; otherwise injected runners as today).

## Non-goals

- No sandbox-exec / seatbelt profile for plugin children.
- No modal alert or notification for pending plugins.
- No "revoke approval" UI beyond the existing connected toggle (approval
  pruning can be revisited if the reviewer asks).
