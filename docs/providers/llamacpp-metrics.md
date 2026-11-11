# llama.cpp Custom Endpoint metrics

With the **llama.cpp** usage preset selected, the reading beneath the icon is
the server's average generation throughput in **tok/s**. The tooltip shows:

- Average generation speed
- Active requests
- Queued requests
- Tokens since server start (prompt plus generated tokens)

The existing `/metrics` request supplies all four readings. No extra request,
proxy, prompt capture, or OpenCode plugin update is required. The readings
refresh on the app's adaptive Custom Endpoint schedule (normally 30 seconds
while agents are working and five minutes when idle). Hovering, finishing work,
or manually refreshing can request an earlier reading. They describe the server, not an individual OpenCode
session. The OpenCode activity monitor still independently supplies working,
waiting and completion state.

| Reading | Prometheus metric |
| --- | --- |
| Average generation speed | `llamacpp:predicted_tokens_seconds` |
| Active requests | `llamacpp:requests_processing` |
| Queued requests | `llamacpp:requests_deferred` |
| Token total | `llamacpp:prompt_tokens_total` + `llamacpp:tokens_predicted_total` |

The speed is the average reported by the installed llama.cpp version; it is
not presented as instantaneous or per-response speed. Missing or invalid
gauges show **—**, while measured zero remains **0**. Ambiguous multi-series
speed gauges are not summed. Invalid counters retain the existing unavailable
reading behavior. A server restart replaces totals instead of accumulating
them as daily usage. No quota or context percentage is inferred from speed.

Existing llama.cpp endpoints adopt this display automatically. vLLM and other
usage presets retain their previous display. No endpoint preferences are
migrated or rewritten.

See the upstream [metrics documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#get-metrics-prometheus-compatible-metrics-exporter).
