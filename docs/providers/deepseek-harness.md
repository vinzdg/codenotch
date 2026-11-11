# DeepSeek Harness

Shows what this machine's DeepSeek Harness (`~/.dsh`) has spent today, priced with the
published `deepseek-flash` rates.

## What it reads

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
| **Today** | `cost / $2.00` | headline ring; derived, drawn with the `~` prefix |
| **Tokens today** | count | pure count (`totalTokens` summed for today) |

`note` spells out the estimate: `~$0.20 of $2.00 · 39062k tokens · 1 session`.

There is no vendor limit to divide by — DeepSeek bills per token and the Harness publishes no
session or weekly quota — so the ring is **derived** (`fidelity = .derived`), and
`DAILY_BUDGET_USD` in `src/deepseek_harness.rs` is the operator's own budget, not a fact about the
service. Resets at local midnight.

## Pricing

`deepseek-flash`, per 1M tokens, from the published table:

| Bucket | Off-peak | Peak |
|---|---|---|
| input, cache hit | $0.003 | $0.006 |
| input, cache miss | $0.15 | $0.30 |
| output | $0.60 | $1.20 |

Peak hours are **01:00–04:00 and 06:00–10:00 UTC, Monday–Friday**; everything else is off-peak,
including weekends. Chinese statutory holidays are billed off-peak by DeepSeek but are **not**
modelled here, so a holiday weekday is over-priced (by at most 2×) on those days.

## Failure behaviour

* No `~/.dsh/sessions` tree → `status: absent`, and the provider is hidden.
* A transcript that will not decode is skipped; the rest still count.
* A reading taken before midnight is persisted with `status: stale` so it cannot pass for today's.

## Verified on this machine

An independent Python computation over the same transcripts agreed exactly:

```
Rust:   39062k tokens, $0.20
Python: 39,062,765 tokens, $0.2022
```

Five unit tests cover the rate table, the weekend rule, the cache-read bucket, the day boundary
and the snapshot shape: `cargo test deepseek`.
