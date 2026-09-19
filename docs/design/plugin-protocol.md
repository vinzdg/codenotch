# Codenotch provider plugin protocol, v1

How an external tool registers a usage provider that Codenotch polls and
renders natively. Any language can implement a plugin: registration is a JSON
file, data is JSON on stdout.

Reference implementation: the CodeMie CLI in
[`codemie-ai/codemie-code`](https://github.com/codemie-ai/codemie-code) —
`codemie install codenotch --budget-plugin` installs Codenotch and registers
two providers whose exec is the CLI itself (`codemie codenotch snapshot`).
Plugins live with their vendors, not in this repository.

## Registration

A plugin is a directory:

```
~/Library/Application Support/Codenotch/Plugins/<id>/
    plugin.json      # manifest, required
    glyph.png        # optional asset referenced by the manifest
```

Writing that directory registers the plugin; deleting it unregisters.
Codenotch scans at launch and watches the directory — both take effect while
the app runs. Replacing `plugin.json` re-reads the plugin (treated as remove +
add).

Registration is not execution. A new or changed plugin is not run: it appears
in Settings → Accounts under "Plugins awaiting approval", showing the display
name, the full exec path and arguments, and a SHA-256 over the `plugin.json`
bytes followed by the executable's bytes. The row also offers to open the
manifest and reveal the plugin folder, so the decision can be made from the
files themselves, not from the plugin's own description of them. Enabling it
approves that exact build — any change to either file re-pends the plugin —
and approvals persist, so reinstalling identical bytes needs no second
approval. Plugin rows in Settings carry a "Plugin" badge, so an external
provider never reads as a built-in.

The plugins directory, each plugin directory, and each `plugin.json` must be
owned by the user, must not be symlinks, and must not be group- or
world-writable; anything else is skipped. Executables may additionally be
root-owned (system binaries like `/bin/sh` are legitimate plugin targets) but
the same symlink and writability rules apply.

The watcher covers the plugins root and one subdirectory level, so manifest
edits and in-tree binary swaps are detected within about half a second. An
exec binary outside the plugin tree (or nested deeper) that is overwritten in
place is caught at the next launch scan — and the approval pins the bytes as
they are at approval time, so a swapped binary re-pends rather than runs.

For development the root can be overridden with the `CODENOTCH_PLUGINS_DIR`
environment variable, in debug builds only.

### Manifest (`plugin.json`)

```json
{
  "schema": 1,
  "id": "codemie-budget",
  "displayName": "CodeMie Budget",
  "version": "0.1.0",
  "exec": {
    "path": "/usr/local/bin/codemie-codenotch",
    "args": ["snapshot", "--provider", "codemie-budget"],
    "timeoutSeconds": 20
  },
  "glyph": { "image": "glyph.png", "opticalScale": 1.0 },
  "signIn": {
    "guidance": "Run `codemie profile login` in Terminal.",
    "run": ["/usr/local/bin/codemie", "profile", "login"]
  },
  "activity": { "type": "claudeSessions", "configDir": "~/.claude" }
}
```

| field | required | meaning |
|---|---|---|
| `schema` | yes | Must be `1`. |
| `id` | yes | `^[a-z0-9][a-z0-9-]*$`, ≤ 64 chars. The join key for ordering, connection state, archive, notifications. Must be stable across releases and must not equal a built-in provider id. |
| `displayName` | yes | Shown in the notch tooltip and the settings row. 1–40 characters, no control characters, and no case-insensitive match for a built-in provider's name (compared after trimming). |
| `version` | yes | Free-form, for diagnostics. |
| `exec.path` | yes | Absolute path to an executable that exists, is executable, and passes the trust check (not a symlink, not group/world-writable, owned by the user or root). |
| `exec.args` | yes | Arguments producing the snapshot payload on stdout. |
| `exec.timeoutSeconds` | no | Default 20, clamped to 30. On expiry the plugin gets SIGTERM, then SIGKILL 2 s later; the reading degrades to stale. |
| `glyph.image` | no | Image file inside the plugin directory (PNG or PDF); the path must resolve — after `..` and symlink resolution — to a file inside that directory. Monochrome mark rendered as a template, per `docs/design/provider-assets.md`. Without it a generic puzzle-piece symbol is drawn. |
| `glyph.opticalScale` | no | Default 1.0 — even the mark's ink out with the built-ins (see `ProviderGlyph.opticalScale`). |
| `signIn.guidance` | no | Shown on the settings row when the provider reports `needsAuth`. |
| `signIn.run` | no | Command spawned detached when the user clicks Sign in on the row. The executable is validated like `exec` (absolute, existing, executable, trusted). |
| `activity` | no | Attach a live-activity monitor so sessions spin this provider's ring. Currently one type: `claudeSessions` with `configDir` (Claude Code config directory; `~` is expanded). |

Validation failures are logged and the plugin is skipped; one bad manifest
never affects other plugins.

### Running the plugin

The child gets exactly this environment — nothing is inherited from Codenotch,
for both `exec` and `signIn.run`:

| variable | value |
|---|---|
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin` — fixed allowlist |
| `HOME`, `USER`, `LOGNAME`, `TMPDIR` | the user's own |
| `LANG` | `en_US.UTF-8` |

stdin is `/dev/null`. stdout is capped at 1 MiB and stderr at 64 KiB; crossing
either cap SIGKILLs the plugin and fails the fetch — a flooded stdout drops the
reading as a bad response, a flooded stderr reports as the plugin's error.

## Snapshot payload (stdout, exit 0)

```json
{
  "fidelity": "official",
  "plan": "CodeMie SSO",
  "headlineID": "budget",
  "weeklyID": null,
  "account": {
    "label": "you@example.com",
    "plan": "codemie-sso",
    "source": "CodeMie CLI",
    "manageURL": "https://codemie.example.com"
  },
  "windows": [
    {
      "id": "budget",
      "label": "CLI budget",
      "usedFraction": 0.0842,
      "group": null,
      "remaining": null,
      "used": null,
      "usedText": null,
      "detail": "$4.21 of $50.00",
      "money": { "currency": "USD", "spent": 4.21, "remaining": 45.79 },
      "resetsAt": "2026-10-01T00:00:00Z"
    }
  ]
}
```

| field | meaning |
|---|---|
| `fidelity` | `official` (default), `derived` or `manual` — Codenotch never dresses a derived number up as official; derived figures render with a `~`. |
| `plan` | Optional plan/tier name shown under the tooltip title. |
| `headlineID` | Which window the ring draws. Declare it — position is not meaning. |
| `weeklyID` | Optional second-ring window id. |
| `account` | Optional; shown in settings so users can see whose numbers these are. `source` names the tool that owns the credential. `manageURL` is handed straight to `NSWorkspace.open`, so anything that is not https is dropped. |
| `windows[].id` | Stable window id (`session`, `budget`, …). |
| `windows[].label` | Display label. |
| `windows[].usedFraction` | 0…1+; omit when the denominator is unknown rather than inventing one. |
| `windows[].remaining` / `used` / `usedText` / `detail` | Count-style readings, as on `LimitWindow`. |
| `windows[].money` | Money-metered window: exact `spent` and `remaining` in `currency`. The percentage is derived from these. |
| `windows[].resetsAt` | ISO-8601; drives reset notifications and refresh-at-rollover. |

The provider id, display name and glyph always come from the **manifest**, not
the payload — a plugin cannot rename itself under its settings row.

## Exit codes

| code | meaning | Codenotch behaviour |
|---|---|---|
| `0` | payload on stdout | render |
| `3` | not authenticated | needs-auth placeholder + `signIn.guidance` in settings |
| `4` | rate limited; optional `{"retryAfterSeconds": N}` on stdout | last reading kept, marked stale; backs off |
| `5` | nothing metered (reason on stderr) | shown as "unsupported" with the reason |
| other | failure (stderr tail kept) | last reading kept, marked stale; error shown |

stdout must contain only the payload — log to stderr.

## Conventions

- **Stateless invocations.** Each `exec` call is independent. Cache in the
  plugin's own directory (or the vendor's config home) when the upstream API
  needs mercy — never in Codenotch's directories.
- **Never block on interaction.** No prompts on stdin/stdout; stdin is
  `/dev/null`. Anything interactive belongs in the vendor's own CLI, reachable
  from `signIn.run`.
- **Keep ids stable.** Renaming `id` orphans the user's ordering and archive.
- **Glyph assets** follow `docs/design/provider-assets.md`: single-colour,
  cropped to the ink box, rendered as a template — tint comes from Codenotch.

## Unregistration

Delete the plugin directory (the vendor's uninstaller should). Codenotch drops
the provider, its cells and its archived reading; the ordering slot is
remembered, so reinstalling returns the ring to its place.
