# DeepSeek Harness

Shows what this machine's DeepSeek Harness (`~/.dsh`) has spent and what prepaid balance remains, combining the official DeepSeek balance endpoint with local session transcripts priced using published `deepseek-flash` rates.

## What it reads

1. **Official API balance**:
   Reads `DEEPSEEK_API_KEY` from `~/.dsh/.credentials.yaml` (or the `DEEPSEEK_API_KEY` environment variable) and queries:
   ```
   GET https://api.deepseek.com/user/balance
   ```
   Using `total_balance` (USD) and `is_available`.

2. **Session transcripts**:
   The Harness writes one transcript per session:
   ```
   ~/.dsh/sessions/<project>/<session-id>/session.v4.jsonl.zstd
   ```

Each line is one JSON event; assistant steps carry a `usage` block:

```json
{"time":1792265428721,
 "data":{"usage":{"inputTokens":265134,"outputTokens":169,
                  "cacheReadTokens":0,"cacheWriteTokens":0,"totalTokens":265303}}}
```

`inputTokens` counts prompt tokens that **missed** the cache and `cacheReadTokens` the ones that
**hit** it — the two are disjoint (on this machine the cache-read total is two orders of magnitude
larger than the input total), so the three billable buckets are exactly those fields plus
`outputTokens`.

The file is a concatenation of zstd frames, one per line, so it is decoded frame by frame
(`ruzstd`'s `FrameDecoder` with `bytes_read_from_source`). `StreamingDecoder` stops at the first
frame and silently yields only the header line; that is a trap worth remembering.

## What it shows

| Window | Value | Meaning |
|---|---|---|
| **Credits** | `spent / funded` (`1.0` when depleted) | Headline ring showing prepaid credit utilization |

When `is_available: false` or `total_balance <= 0`, `used` is `1.0` (100% used / 0% remaining). When `spent + remaining` exceeds the base `$2.00` USD top-up, `funded` scales dynamically to the actual loaded amount (`(spent + remaining).max(2.00)`).

### Configurable display formats

In **Settings -> Accounts -> DeepSeek Harness -> Credit display**, three note formats are available:
* **Remaining balance & tokens (`remaining`, default)**: `$0.00 remaining of $2.00 · 39.1M tokens`
* **Spent, remaining & tokens (`spent`)**: `$2.00 of $2.00 used · $0.00 left · 39.1M tokens`
* **Compact (`compact`)**: `$2.00 / $2.00 USD ($0.00 left)`

All three formats and the `Credits` window label are localized across `en`, `es`, `pt-BR`, `ko`, `ru`, `uk`, `zh`, `zh-Hant`, and `ja`.

## Pricing

`deepseek-flash`, per 1M tokens, from the published table:

| Bucket | Off-peak | Peak |
|---|---|---|
| input, cache hit | $0.003 | $0.006 |
| input, cache miss | $0.15 | $0.30 |
| output | $0.60 | $1.20 |

Peak hours are **01:00–04:00 and 06:00–10:00 UTC, Monday–Friday**; everything else is off-peak,
including weekends. Chinese statutory holidays are billed off-peak by DeepSeek but are **not**
modelled here, so a holiday weekday is over-priced (by at most 2x) on those days.

## Failure behaviour

* No `~/.dsh/sessions` tree and no API balance -> `status: absent`, and the provider is hidden.
* If the API balance call fails offline, falls back to local transcript cost estimation (`derived: true`).
* A transcript that will not decode is skipped; the rest still count.

## Verified on this machine

Seven unit tests cover the rate table, the weekend rule, the cache-read bucket, the day boundary,
depleted balance reporting (100% used), top-ups above `$2.00` USD, and all three display formats:
`cargo test deepseek`.
