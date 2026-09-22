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
name, the full exec command line (and the sign-in command, if any), and a
SHA-256 over the **whole plugin directory** — every file, in path order, by
content. The row also offers to open the manifest and reveal the plugin
folder, so the decision can be made from the files themselves, not from the
plugin's own description of them. Enabling it approves that exact directory:
any change to any file in it re-pends the plugin. The approval is kept in the
data-protection keychain, in an access group only code signed by this app's
team can reach — no other process can file, read or replace it. (A build
without that entitlement keeps no approvals between launches.) It lives
exactly as long as
the plugin directory does — deleting the directory forgets it, and
*Revoke…* on the plugin's settings row forgets it while leaving the files in
place. Reinstalling identical bytes asks again.

Plugin rows carry a "Plugin" badge in Settings; in the notch the ring wears a
puzzle-piece mark, the tooltip and reset card a "Plugin" capsule beside the
title, and notifications name the provider "… (plugin)". An external provider
never reads as a built-in.

The plugins directory, each plugin directory, and each `plugin.json` must be
owned by the user, must not be symlinks, and must not be group- or
world-writable; anything else is skipped. Every executable a manifest names
(`exec.path`, `signIn.run[0]`) must be a regular file, not a symlink, not
group/world-writable, and must either live **inside the plugin directory**,
where the hash covers it, or be one of **`/bin/sh`, `/bin/bash`,
`/usr/bin/osascript`** — root-owned system executables that consult nothing
user-writable to decide what to run. Other root-owned programs do:
`/bin/zsh` sources `~/.zshenv`, `/usr/bin/python3` imports the user site's
`usercustomize.py`, `/usr/bin/env` resolves through a PATH with Homebrew on
it, `/usr/bin/open` asks LaunchServices — code or choices the hash never
sees, so they are refused, as is a user-owned binary anywhere outside the
directory. A sign-in that needs a browser opens it from a script in the
tree. Every argument, read as a path, must stay inside the plugin
directory: the child runs with the plugin directory as its working
directory (the poll and the sign-in alike), so `run.sh` and
`<plugin dir>/run.sh` both mean the pinned file, and `../run.sh`,
`/Users/me/run.sh` or `lib/run.sh` through a symlink that leaves the
directory are refused. A symlink inside the directory may only point back
inside it. Every word of the command line is printable ASCII (no newlines
or tabs, no bidirectional overrides, no lookalike letters from other
scripts): the approval row prints the command line, each word
shell-quoted, as the thing being agreed to, and must show it for what it is.
Wrap a vendor CLI that lives elsewhere (a Homebrew or npm install) in a
script inside the plugin directory — that wrapper is what the approval pins
and what the user reads; what the wrapper goes on to run is the vendor's
code, and the approval cannot pin it.

The plugin directory is immutable by contract: anything written into it
after approval — a cache, a log — changes the hash and re-pends the plugin.
`.DS_Store` is the one file ignored. The directory is re-checked immediately
before every run (trust, validation, hash against the approval); a mismatch
refuses to run and re-pends. The watcher covers the plugins root and one
subdirectory level, so most edits show in Settings within about half a
second; the rest are caught at the next poll.

For development the root can be overridden with the `CODENOTCH_PLUGINS_DIR`
environment variable, in debug builds only.

### Manifest (`plugin.json`)

```json
{
  "schema": 1,
  "id": "plugin-codemie-budget",
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
| `id` | yes | `^plugin-[a-z0-9][a-z0-9-]*$`, ≤ 64 chars in all. The join key for ordering, connection state, archive, notifications. Must be stable across releases. The `plugin-` namespace is reserved for plugins, so an id can never collide with a built-in provider, now or later; a manifest whose id or display name matches a provider present at the time — built-in or a custom endpoint the user has added — is refused, and re-checked whenever that set changes. |
| `displayName` | yes | Shown in the notch tooltip and the settings row. 1–40 characters, no control characters, and not a built-in provider's name — compared as a skeleton, so lookalike scripts, accents, digits and invisible characters do not get "Claude" past the check. |
| `version` | yes | Free-form, for diagnostics. |
| `exec.path` | yes | Absolute path to an executable that exists, is executable, and passes the trust check (not a symlink, not group/world-writable) — inside the plugin directory, or one of `/bin/sh`, `/bin/bash`, `/usr/bin/osascript`. |
| `exec.args` | yes | Arguments producing the snapshot payload on stdout. Every argument, read as a path, must stay inside the plugin directory (relative ones resolve there); printable ASCII only. |
| `exec.timeoutSeconds` | no | Default 20, clamped to 30. On expiry the plugin gets SIGTERM, then SIGKILL 2 s later; the reading degrades to stale. |
| `glyph.image` | no | Image file inside the plugin directory (PNG or PDF); the path must resolve — after `..` and symlink resolution — to a file inside that directory. Monochrome mark rendered as a template, per `docs/design/provider-assets.md`. Without it a generic puzzle-piece symbol is drawn. |
| `glyph.opticalScale` | no | Default 1.0 — even the mark's ink out with the built-ins (see `ProviderGlyph.opticalScale`). |
| `signIn.guidance` | no | Shown on the settings row when the provider reports `needsAuth`. |
| `signIn.run` | no | Command spawned detached when the user clicks Sign in on the row. Validated exactly like `exec` — executable placement and argument containment included — and shown on the approval row. |
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

stdin is `/dev/null`; the working directory is the plugin directory. stdout is
capped at 1 MiB and stderr at 64 KiB; crossing either cap SIGKILLs the plugin
and fails the fetch — a flooded stdout drops the reading as a bad response, a
flooded stderr reports as the plugin's error.

### What the approval guarantees

Nothing registers without a click in Settings. The click pins every file in
the plugin directory and the out-of-tree interpreter it names, and any change
to those asks again. The approval record lives in the data-protection
keychain, which no process outside this app's signing team can file, read or
replace — where the build carries the `keychain-access-groups` entitlement
(`$(AppIdentifierPrefix)com.vinz.codenotch`, and for Developer ID a
provisioning profile that grants it). A build without it keeps no approvals
between launches: every plugin asks again, and one log line at launch says
why. There is no fallback to the login keychain — every attribute of an item
there, the entry naming its creator included, is written by whoever creates
it, so it cannot say who did.

What the approval cannot guarantee: what an in-tree wrapper goes on to run
(a wrapper around a Homebrew or npm install runs whatever is installed
there), and the window between the pre-run hash and the spawn, where a
tamper that lands is one poll's worth of code and a tamper that misses
re-pends the plugin.

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

The payload is bounded rather than trusted: at most 16 windows are read; ids,
labels, groups, currencies and plan names are cut to 64 characters, free text
(`usedText`, `detail`, account fields) to 200; `usedFraction` is clamped to
0…10, money to 0…10⁹, counts to ≥ 0; NaN and infinities are dropped;
`resetsAt` and `duration` more than a year from now are dropped;
`retryAfterSeconds` is clamped to 1…3600.

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
  vendor's config home or `$TMPDIR` when the upstream API needs mercy — never
  in the plugin directory (that re-pends the plugin) and never in Codenotch's
  directories.
- **Never block on interaction.** No prompts on stdin/stdout; stdin is
  `/dev/null`. Anything interactive belongs in the vendor's own CLI, reachable
  from `signIn.run`.
- **Keep ids stable.** Renaming `id` orphans the user's ordering and archive.
- **Glyph assets** follow `docs/design/provider-assets.md`: single-colour,
  cropped to the ink box, rendered as a template — tint comes from Codenotch.

## Unregistration

Delete the plugin directory (the vendor's uninstaller should). Codenotch drops
the provider, its cells, its archived reading and its approval; the ordering
slot is remembered, so a reinstall — once approved again — returns the ring to
its place.
