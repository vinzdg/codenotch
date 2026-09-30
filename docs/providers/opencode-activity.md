# OpenCode activity for Custom Endpoints

Codenotch can show local OpenCode sessions on a Custom Endpoint and announce
when they need an approval or answer, or finish a turn. This uses OpenCode's
structured plugin events. It works with llama.cpp and other OpenAI-compatible
backends; it does not require an OpenCode Go subscription.

## Setup

1. Configure and enable your Custom Endpoint as usual. Fetch its models and
   select the model you use in OpenCode.
2. In the endpoint editor, under **OpenCode activity**, enter the exact provider
   key from your OpenCode configuration. For example, for
   `"model": "llamacpp/qwen-local"`, enter `llamacpp`. The selected endpoint model
   must match the OpenCode model key (`qwen-local` in this example). These are
   identifiers, not the provider's display name or its URL.
3. Click **Install OpenCode bridge**, save the endpoint, and restart OpenCode.
   The button installs the bundled plugin at
   `~/.config/opencode/plugins/codenotch.js` (or under `XDG_CONFIG_HOME` when set
   in Codenotch's environment). An earlier different file is backed up as a
   uniquely named `.backup` file; installing the same version again is a no-op.
4. Use Codenotch's existing session activity and notification settings to
   choose the indicator, sound, and notch or macOS notification channel.
   Start a new OpenCode turn to test the transition.

For terminal-specific XDG configuration, copy
`Sources/Resources/codenotch-opencode.mjs` to your actual OpenCode plugin
directory as `codenotch.js`. Install it once; do not load a second copy through
OpenCode's explicit `plugin` list. The plugin has no additional dependencies.

Clear the provider ID to disable monitoring for this endpoint. To stop the
producer entirely, remove only the installed `codenotch.js` and restart
OpenCode. Codenotch does not change OpenCode's model, permissions, prompts, or
API configuration.

## Signals and limitations

| OpenCode signal | Codenotch state |
| --- | --- |
| `session.status` with `busy` or `retry` | Working, unless a request remains pending |
| `permission.asked` / `permission.v2.asked` | Needs interaction: approval |
| `question.asked` / `question.v2.asked` | Needs interaction: answer |
| Matching permission reply or question reply/rejection | Working once the last request is resolved |
| `session.status` with `idle` | Turn finished, if previously working and no session error was observed |
| `session.error`, `session.deleted`, plugin disposal, dead process | Remove activity silently |

The deprecated `session.idle` duplicate is ignored. Arbitrary terminal stdin,
authentication prompts, and tools that ask questions outside OpenCode's
permission/question mechanism are not detected. This is turn-idle detection,
not proof that the model achieved the user's intended task. An emitted error
(including an abort reported as `session.error`) suppresses a completion alert.

Child-session activity is folded into its root: a helper can make the root
show an approval request, but ending a helper does not finish a working root.
Provider and model mapping is explicit; changing them mid-turn can move the
activity out of the configured endpoint. Empty selected model matches all
models for the configured provider. Avoid mapping the same provider/model to
multiple enabled endpoints unless you want it displayed in both.

OpenCode and Codenotch must run as the same local user. For remote OpenCode,
the local plugin directory, PID checks, and local status files are insufficient.
The llama.cpp server itself may be remote; it is OpenCode's location that
matters. A crashed producer is removed on the next scan; a living but hung
producer cannot be reliably distinguished from a long-running turn.

## Implementation

```text
OpenCode plugin event hook
  → codenotch-opencode.mjs: serialized event queue
  → atomic per-instance snapshot + ordered transition journal
  → OpenCodeActivityMonitor: AgentActivityMonitor
  → OpenCodeActivityBridge: explicit Custom Endpoint mapping
  → ActivityCoordinator.setSupplementalSessions(source: "opencode")
  → existing AgentSession and SessionCompletionWatcher
  → existing notification/indicator settings
```

The plugin writes JSON under
`~/Library/Application Support/Codenotch/OpenCode/`. Each instance carries a
UUID, PID, process start time, up to 64 session records and the last 256 state
changes. Files are atomically replaced with mode `0600` in a directory created
with mode `0700`. The data contains session IDs, parent IDs, titles, provider
and model IDs, timestamps, and state/reason. **Session titles may describe the
task.** Message bodies, question text, answers, tool arguments, and credentials
are not copied. Files left by a crash may persist until manually removed;
Codenotch checks liveness and does not treat them as active sessions.

The reader polls once per second, checks process identity, bounds input size
to 1 MiB per file, skips symlinks/invalid files, and reads up to 64 live
instances from the 512 newest candidates. It replays consecutive changes so
short waits and turns survive polling. Existing history at startup is seeded
silently. A journal gap or restart also seeds the current state silently,
rather than inventing a completion. More than 256 unseen changes can therefore
lose notifications. At 64 sessions, the producer evicts an idle/ended session;
if all are active, further sessions are not tracked until capacity is free.

No new lifecycle abstraction, terminal parsing, or CLI subprocess management
is added to Codenotch. The existing `.busy`, `.waiting`, `.idle` states and
notification preferences are reused. New UI strings currently fall back to
English in languages without translations.

## Verification

The integration was exercised with OpenCode **1.18.33**. The optional smoke
test starts an isolated OpenCode server and a synthetic localhost model, then
checks normal completion, a rejected tool approval, and an answered question.
It does not call a real inference endpoint or change the user's OpenCode
configuration. The approval test rejects the command before execution.

```sh
node --test Scripts/opencode/codenotch.test.js
node Scripts/opencode/smoke.mjs  # requires opencode in PATH, or OPENCODE_BIN
make test
```

Plugin tests cover ordering, v1/v2 events, concurrent requests, errors,
disposal, metadata filtering and journal bounds. Swift tests exercise the
existing completion watcher, rapid transitions, startup, gaps, process death,
invalid files, provider/model mapping, child sessions, endpoint migration and
installer backups. Source contracts were checked against OpenCode v1.18.33:
[plugin dispatch](https://github.com/anomalyco/opencode/blob/v1.18.33/packages/opencode/src/plugin/index.ts)
and the [plugin documentation](https://opencode.ai/docs/plugins/).
