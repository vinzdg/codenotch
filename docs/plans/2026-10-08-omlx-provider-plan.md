# oMLX monitoring plan

Prepared 2026-10-08 against Codenotch 1.22.0, as the second local runtime after
[LM Studio](2026-09-10-lm-studio-provider-plan.md), built the same way. Target
is oMLX 0.7.0 (bundle `app.omlx`, `omlx-server` on `127.0.0.1:8000`, state in
`~/.omlx`). The API key is never printed, logged, stored or quoted anywhere in
the code, the tests or these documents.

## What the user chose

1. The API key is borrowed from `~/.omlx/settings.json` (`auth.api_key`).
   `OMLX_API_KEY` wins when set. No `Authorization` header is sent when
   `auth.skip_api_key_verification` is true or no key exists.
2. What each model is doing comes from `/admin/api/activity`, through an admin
   session cookie.
3. Statistics come from the server log only: no SQLite history, no
   `/admin/api/usage`.
4. The glyph is oMLX's own `menubar-filled.svg`.

Identifiers that must not change: provider id `omlx`, cell id prefix
`omlx:model:`, preference key `omlxEndpoint`, default address
`http://127.0.0.1:8000`, bundle id `app.omlx`.

## What oMLX exposes (reconnaissance, 0.7.0, 2026-10-08, read-only)

| Source | What it gives | Auth | Used for |
| --- | --- | --- | --- |
| `~/.omlx/settings.json` (mode 0600) | `server.host`, `server.port`, `auth.api_key`, `auth.skip_api_key_verification`, `auth.allow_unauthenticated_inference`, `auth.sub_keys`, `logging.log_dir` (null means `~/.omlx/logs`) | file permissions | the key, the default address, the log directory |
| `GET /health` | `status`, `default_model`, `engine_pool` counts | none | a fingerprint, not used |
| `GET /v1/models/status` | every model with `loaded`, `is_loading`, `actual_size`, `estimated_size`, `engine_type`, `max_context_window`, `is_helper`, `is_hidden`, `source_model_id` for profiles | Bearer key; 401 `{"detail":...}` without | inventory, one cell per loaded generating model |
| `POST /admin/api/login` | `{"success":true}` and cookie `omlx_admin_session` (HttpOnly, SameSite=Lax, 24 h) | the main key only; sub keys answer 401 `{"detail":"Invalid API key"}` | opening the admin session |
| `GET /admin/api/activity` | per loaded model: `active_requests`, `waiting_requests`, `waiting`, `prefilling`, `generating`, `activities` | session cookie; 401 `{"detail":"Admin authentication required"}` without | phase and queue per model |
| `GET /api/status` | server-wide `active_requests`, `waiting_requests`, totals | Bearer key | not used (no per-model split) |
| `~/.omlx/logs/server.log` | one INFO line per model response from logger `omlx.server` | none | speed, tokens per model per day, last speed |

Recorded `/v1/models/status`, trimmed (quoted in `OMLXUsage`):

```json
{"final_ceiling":87827013104,"current_model_memory":31501724030,"model_count":2,"loaded_count":2,
 "load_seconds_per_gb_estimate":0.304,"load_time_observations":16,
 "models":[
  {"id":"Qwen3.8-27B-oQ8e-mtp","model_path":"/Users/istar/Models/Jundot/Qwen3.8-27B-oQ8e-mtp","loaded":true,"is_loading":false,
   "loading_started_at":null,"estimated_size":31501724030,"resident_estimated_size":31501724030,"distributed":false,"cluster":null,
   "actual_size":30203498392,"pinned":false,"engine_type":"vlm","model_type":"vlm","config_model_type":"qwen3_5","realtime_stt":false,
   "model_context_length":262144,"is_helper":false,"thinking_default":true,"preserve_thinking_default":true,"source_type":"local",
   "source_repo_id":null,"last_access":1791407364.46658,"max_context_window":262144,"model_alias":"qwen3.8-27b-oq8e","is_favorite":true,"is_hidden":false,"max_tokens":32768},
  {"id":"qwen3.8-27b-oq8e:nomtp","model_path":"/Users/istar/Models/Jundot/Qwen3.8-27B-oQ8e-mtp","loaded":true,"is_loading":false,
   "estimated_size":31501724030,"actual_size":30203498392,"engine_type":"vlm","model_type":"vlm","config_model_type":"qwen3_5",
   "model_context_length":262144,"is_helper":false,"source_type":"local","source_repo_id":null,"last_access":1791407364.46658,
   "source_model_id":"Qwen3.8-27B-oQ8e-mtp","profile_name":"nomtp","profile_api_name":"nomtp","profile_display_name":"oQ8e bez spekulacji (kontrola)",
   "max_context_window":262144,"model_alias":"qwen3.8-27b-oq8e","is_favorite":true,"is_hidden":false,"max_tokens":32768}]}
```

Recorded `/admin/api/activity` while idle, trimmed (quoted in `OMLXLink`):

```json
{"active_models":{"models":[{"id":"Qwen3.8-27B-oQ8e-mtp","estimated_size":31501724030,"estimated_size_formatted":"29.34GB",
  "actual_size":30203498392,"actual_size_formatted":"28.13GB","pinned":false,"is_loading":false,"loading_elapsed_seconds":null,
  "loading_estimated_seconds":null,"loading_remaining_seconds_estimate":null,"active_requests":0,"waiting_requests":0,
  "waiting":[],"activities":[],"prefilling":[],"generating":[],"idle_seconds":44455.94,"ttl_remaining_seconds":null,"dflash":null,"cluster":null}],
 "model_memory_used":35344391664,"model_memory_max":88573582832,
 "memory_pressure":{"enabled":true,"current_bytes":35344391664,"soft_bytes":79716224548,"hard_bytes":84144903690,"current_formatted":"32.9GB","soft_formatted":"74.2GB","hard_formatted":"78.4GB","pressure_level":"ok"},
 "total_active_requests":0,"total_waiting_requests":0}}
```

The busy shapes were read from `admin/routes.py` (`_build_active_models_data`)
and not recorded live: `waiting` items carry `request_id`, `queue_position`,
`elapsed_seconds`, `prompt_tokens`; `prefilling` items carry `request_id`,
`processed`, `total`, `speed`, `eta`, `elapsed`, `detail`; `generating` items
carry `request_id`, `elapsed_seconds`, `generated_tokens`, `tokens_per_second`,
`last_activity_age_seconds`, `prompt_tokens`, `max_tokens`; `activities` is an
engine-reported list for non-streaming engines. Only models that are `loaded`
or `is_loading` appear.

Findings that shaped the design:

- `/admin/api/stats` echoes the API key in its body. It is never called.
- `/v1/models` lists aliases (`qwen3.8-27b-oq8e`), not canonical ids. The log
  and the activity endpoint both use the canonical `id`, so cells are keyed on it.
- Entries with `source_model_id` are profiles of a loaded model and share its
  engine and memory. They would double every cell, so they are folded into
  their source model.
- `engine_type` is `batched` (text), `vlm`, `reranker`, `audio_tts`,
  `audio_stt`, `audio_sts` or an embedding type. Only the first two generate.
- Unlike LM Studio, oMLX reports resident bytes after load (`actual_size`), so
  the memory is an allocation, not a nominal model size.
- Every response is logged with oMLX's own tok/s, so no phase timing is needed
  and a performance is never approximate.
- Successful API calls are not logged, only rejections are (a `GET /v1/models`
  without a key logs a WARNING). Prompts are never in the log.
- oMLX rotates the log at midnight by renaming the live file to
  `server.log.YYYY-MM-DD` and starting a new `server.log`, keeping
  `logging.retention_days` (7) backups. LM Studio instead opens a new file, so
  its tail could not be reused.

Log line format: `%(asctime)s - %(name)s - %(levelname)s - [%(request_id)s] - %(message)s`,
local time without an offset, comma milliseconds. Four per-response prefixes
are accepted, all with the shape `model=…, N tokens in Ns (N tok/s)`:

| Prefix | Endpoint | `prompt:` count |
| --- | --- | --- |
| `Chat completion: ` | `/v1/chat/completions` | yes |
| `Completion: ` | legacy `/v1/completions` | yes |
| `Anthropic message: ` | `/v1/messages`, what Claude Code uses | no |
| `Responses API: ` | `/v1/responses` | no |

```
2026-10-07 23:09:35,762 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ8e-mtp, 430 tokens in 10.97s (42.8 tok/s), prompt: 68, finish_reason=stop, max_tokens=32768, request_max_tokens=None, stream_model_ttft=0.91s, stream_visible_ttft=0.97s
2026-10-07 17:12:01,118 - omlx.server - INFO - [-] - Chat completion: model=Qwen3.8-27B-oQ4e-mtp, 112 tokens in 3.41s (32.8 tok/s), prompt: 2534, finish_reason=length, max_tokens=32768, request_max_tokens=None
```

Diffusion models write `(N tok/s e2e, output=N tok/s, ...)`, so the first
number before ` tok/s` is taken. `stream_model_ttft` may be `unavailable`.

## Design

Provider id `omlx` (a persistence key; do not rename). Cells are
`omlx:model:<canonical id>`, one per loaded generating model. `OMLXIdentity`
(`providerID`, `cellID(instance:)`) lives in `OMLXLocalProvider.swift` and is
used everywhere the id is needed.

- `OMLXCredentials`, `OMLXEndpoint`, `OMLXError`: the key (`OMLX_API_KEY`, else
  `auth.api_key` unless key verification is skipped), re-read on every call so
  a key rotated in oMLX's dashboard is picked up; the default address from
  `server.host` and `server.port` when the host is loopback (a LAN-only bind
  is not guessed); the log directory (`logging.log_dir` or `~/.omlx/logs`).
- `OMLXLocalProvider` + `OMLXUsage`: `GET v1/models/status` on the configured
  loopback address, answered from memory for five seconds, with a Bearer header
  only when a key exists. A loaded model becomes a cell unless it is a helper,
  hidden, a profile, or an embedding, reranker or `audio_` engine. 401/403
  becomes `OMLXError.needsKey`, shown in Settings, never as a sign-out. The
  memory is `actual_size` when positive, else `estimated_size`.
- `OMLXLink`: its own `URLSession` with cookies on and no redirects, 3 s
  timeouts. It logs into the admin session once and retries a 401 on the
  activity read once. A 401 from the login itself means the key is missing or
  is a sub key and becomes `needsKey`. The login body never reaches a log line.
- `OMLXMetrics`: polls the activity every 0.5 s. `prefilling` maps to the
  prompt phase, `generating` or a non-empty `activities` to the generating
  phase, `waiting` to the queue. A model doing none of these is absent, so
  `isBusy` is true exactly when there are activities. On `needsKey` the status
  names `~/.omlx/settings.json` and polling backs off 10 s. When the server is
  down it backs off 2 s as LM Studio does.
- `OMLXServerLog` + `OMLXLogTail`: byte parser that rejects a line on its first
  bytes and reads in 4 MB slices with a pending partial line. `OMLXLogTail` is
  a separate class because of the midnight rename: history reads the dated
  files oldest first and then `server.log`, and a poll treats the file as
  rotated when `server.log` shrinks or its inode changes. The generation time
  is derived as tokens divided by tok/s so the figure agrees with oMLX's own,
  since its elapsed time includes the prompt phase. `OMLXMetrics` fills the
  ledger and the last logged speed per cell from history, dated by the log's own
  timestamps, and live lines update both.
- Per-source fleet maps: `NotchFleet` and `NotchViewModel` hold activities and
  ledgers per provider id, so two runtimes never overwrite each other. Cell ids
  are namespaced, so the merged activity map has no collisions.
- Settings → oMLX: monitoring switch, address, status, and a statement of what
  is read from where. There is no key field: the key is borrowed, not owned.
- `UsageStore.isBusy` includes a busy oMLX model, so cloud polling speeds up
  for local work too.

Not done, deliberately:

- TTL and unload time (`ttl_remaining_seconds` is null today).
- Per-client attribution (the log names the model, not the caller).
- MTP acceptance rate (the `MTP[...] accept=` log lines).
- `usage.sqlite3` history, which would add a SQLite reader for little over the log.
- A `/api/status` fallback when the admin session is refused.
- A Custom Endpoints preset for oMLX.
- A release-note entry, which belongs to the next release.

## Verification

Recorded payloads from this Mac are quoted in `OMLXUsage`, `OMLXLink` and
`OMLXServerLog`, and used as the test fixtures. The test fixtures use a
placeholder key, never a real one. The opt-in live checks
(`TEST_RUNNER_CODENOTCH_OMLX_LIVE=1`) read the real log history and log in to
the admin session once. The result of the full suite is recorded with the
release that ships this connector.
