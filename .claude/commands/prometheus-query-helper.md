---
description: Turn a plain-English monitoring intent into a validated PromQL query with rationale, cardinality notes, and example alerts. Read-only, generates a markdown report.
argument-hint: "INTENT=\"<what you want to measure>\" [PROM_URL=...] [METRIC_HINT=...] [REPORT_DIR=...]"
---

# /prometheus-query-helper — Intent → PromQL

Convert a description of what you want to observe into idiomatic PromQL, explain each part, and (optionally) validate the query against a Prometheus server. **Read-only** — only `GET` API calls are made; no recording rules or alerts are written.

## Prerequisites

- Nothing required for query construction — the workflow can produce PromQL from intent alone.
- Optional: `curl` + a reachable Prometheus HTTP API (`/api/v1/query`, `/api/v1/label/__name__/values`) to validate against real metric names and cardinality.
- Optional: `jq` for readable API output.

## Inputs

- **INTENT** *(required)* — what you want to measure, in plain English (e.g. "p99 latency of checkout by pod", "error rate ratio for the payments API", "nodes with disk pressure above 85%").
- **PROM_URL** — base URL of a Prometheus server for validation. Default: none (construct only).
- **METRIC_HINT** — a metric name or prefix to narrow discovery (e.g. `http_request_duration_seconds`). Default: none.
- **REPORT_DIR** — report output directory. Default: `./prometheus-query-helper-reports`.

Confirm `PROM_URL` (and that queries are read-only against it) before issuing any request.

---

## Step 1 — Clarify the intent

Restate the intent as a measurable quantity and state the assumptions:

- **Subject** — which service/job/instance.
- **Measure** — latency, rate, error ratio, saturation, availability.
- **Aggregation** — by which labels (`pod`, `namespace`, `route`, `le`).
- **Window** — range selector and `rate()`/`irate()` window.

If INTENT is ambiguous (e.g. "check the app"), ask a targeted clarifying question before writing PromQL.

---

## Step 2 — Discover candidate metrics (optional)

```bash
if [ -n "${PROM_URL:-}" ]; then
  curl -sS --max-time 10 "${PROM_URL}/api/v1/label/__name__/values" \
    | jq -r '.data[]' 2>/dev/null | grep -iE "${METRIC_HINT:-.}" | head -40
fi
```

Use discovered names instead of guessing. If no server is available, use well-known conventions (`*_total` for counters, `*_seconds` for duration histograms, `*_bytes` for gauges) and label them as assumptions.

---

## Step 3 — Build the query

Construct PromQL using the appropriate shape:

| Intent | Pattern |
|---|---|
| Request rate | `sum by (job) (rate(http_requests_total[5m]))` |
| Error ratio | `sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |
| p99 latency | `histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` |
| Saturation | `1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Availability | `avg_over_time(up[5m])` |

State why the window (e.g. `5m`) and aggregation level were chosen, and note counter-vs-gauge handling (always wrap counters in `rate`/`increase`).

---

## Step 4 — Validate (optional)

```bash
if [ -n "${PROM_URL:-}" ]; then
  q=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$QUERY")
  curl -sS --max-time 10 "${PROM_URL}/api/v1/query?query=${q}" | jq '{status, series: (.data.result|length), warning: .warnings}' 2>/dev/null
fi
```

Flag: parse errors, `status: error`, zero series returned (wrong labels), or very high series count (cardinality problem).

---

## Step 5 — Guardrails and alert suggestion

For each query, provide:

- **Cardinality note** — which labels multiply series; warn against grouping by high-cardinality labels (`pod` over long ranges, `path` with unbounded values).
- **Cost note** — long range selectors + `histogram_quantile` over large buckets.
- **Example alert** — a minimal recording/alerting expression (listed as a suggestion, not applied):

```yaml
# example — review before applying
- alert: HighErrorRate
  expr: |
    sum(rate(http_requests_total{code=~"5.."}[5m]))
      / sum(rate(http_requests_total[5m])) > 0.05
  for: 10m
  labels:
    severity: warning
```

---

## Step 6 — Generate report

Compile the result into a timestamped Markdown report:

```text
$REPORT_DIR/prometheus-query-helper-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# PromQL Helper Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Intent | <restated intent> |
| Validated against | <PROM_URL or "not validated"> |
| Series returned | <n or n/a> |

## Recommended query

<promql>

## Rationale
<per-clause explanation: metric choice, rate window, aggregation, labels>

## Cardinality and cost notes
<what multiplies series; what to avoid>

## Alternatives considered
<other valid shapes and when to prefer them>

## Example alert (suggestion only)
<yaml>
```

---

## Safety rules

- Only `GET` requests to the Prometheus API — never `POST` to rules/alerts, never create recording rules.
- Never send credentials in the URL query; rely on the user's existing auth (proxy/headers) and note if auth is missing.
- Never print bearer tokens or basic-auth values.
- Queries are suggestions — the user decides whether to add them as alerts or recording rules.
- Do not enumerate high-cardinality label values across the whole cluster without the user's consent (can be expensive).
