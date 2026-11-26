---
description: Read-only PostgreSQL health check — bloat, long-running and idle-in-transaction queries, lock waits, replication lag, connection saturation, missing indexes, and autovacuum. Generates a markdown report.
argument-hint: "CONN_ENV=<VAR_NAME> [DATABASE=postgres] [TOP_N=20] [DEEP=yes|no] [REPORT_DIR=...]"
---

# /postgres-health — PostgreSQL Health Diagnostics

Read-only health check for a PostgreSQL instance or cluster. Covers version/config, connection saturation, long-running and idle-in-transaction queries, lock waits and blocking chains, table/index bloat, missing-index candidates, autovacuum health, and replication lag (primary and replica perspectives). Produces a severity-ranked Markdown report.

**Read-only strictly enforced** — every query is a `SELECT` against `pg_*` / `information_schema` views. No DDL, DML, `pg_terminate_backend`, or `VACUUM` is issued. Remediation is listed in the report for the DBA to apply.

## Prerequisites

- `psql` client matching the server's major version (for accurate catalog columns).
- A connection to the target database. The password is read from an environment variable named by `CONN_ENV` — never passed on the command line.
- A role with `pg_monitor` (or superuser) for `pg_stat_activity` / `pg_stat_replication` / `pg_stat_statements`.
- Optional: `pg_stat_statements` extension installed (enables query-level stats in Step 5).
- Optional: `jq` not required.

## Inputs

- **CONN_ENV** *(required)* — name of the environment variable holding a libpq URI (`postgresql://user:pass@host:5432/dbname?sslmode=require`). Default: `PG_CONN`.
- **DATABASE** — database to connect to for per-DB checks. Default: `postgres`.
- **TOP_N** — number of rows per ranking. Default: `20`.
- **DEEP** — `yes` also runs `pg_stat_statements` history and table-size sampling. Default: `no`.
- **REPORT_DIR** — report output directory. Default: `./postgres-health-reports`.

Never echo the connection string or password. Confirm the target host (and that it is not production, if that matters to the user) **before running any query**.

---

## Step 1 — Verify connection and server identity

```bash
: "${CONN_ENV:=PG_CONN}"
if [ -z "${!CONN_ENV:-}" ]; then echo "ERROR: \$$CONN_ENV is not set"; exit 1; fi

psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT version(),
         current_database() AS db,
         pg_is_in_recovery() AS in_recovery,
         (SELECT setting FROM pg_settings WHERE name='server_version') AS server_version;"
```

Stop and report if the connection fails. Never fall back to a different host or user.

---

## Step 2 — Connection usage and activity mix

```bash
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT state, count(*) AS n
  FROM pg_stat_activity
  WHERE backend_type = 'client backend'
  GROUP BY state ORDER BY n DESC;"

psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT name, setting FROM pg_settings
  WHERE name IN ('max_connections','superuser_reserved_connections');"
```

Flag:

- Client connections at or above ~80% of `max_connections - superuser_reserved_connections`.
- Large `idle` count (connection-pooler missing or misconfigured).
- `idle in transaction` above a small threshold — see Step 3.

---

## Step 3 — Long-running and idle-in-transaction sessions

```bash
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT pid, usename, state,
         now() - xact_start  AS xact_age,
         now() - query_start AS query_age,
         left(query, 120)    AS query_head
  FROM pg_stat_activity
  WHERE backend_type = 'client backend'
    AND state <> 'idle'
    AND xact_start IS NOT NULL
  ORDER BY xact_start ASC
  LIMIT ${TOP_N:-20};"

psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT pid, usename, state, now() - state_change AS idle_age
  FROM pg_stat_activity
  WHERE state = 'idle in transaction'
  ORDER BY state_change ASC
  LIMIT ${TOP_N:-20};"
```

Flag:

- Any query running longer than a documented threshold (default: >5 min) — list for review.
- `idle in transaction` older than ~1 min — holds locks and blocks autovacuum; report PID and age.
- Truncated query text only — never print parameter values; the `query` column never includes bind parameters.

---

## Step 4 — Lock waits and blocking chains

```bash
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT blocked.pid          AS blocked_pid,
         blocked.usename      AS blocked_user,
         blocking.pid         AS blocking_pid,
         blocking.usename     AS blocking_user,
         left(blocked.query, 100)  AS blocked_query,
         left(blocking.query, 100) AS blocking_query,
         now() - blocked.query_start AS wait_age
  FROM pg_stat_activity blocked
  JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
  WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
  ORDER BY wait_age DESC;"
```

Flag:

- Any non-empty result — a blocking chain is active. Report the head blocker and the wait age.
- Suggest `pg_terminate_backend(blocking_pid)` **as a recommended action only** — never execute it.
- Empty result is expected on a healthy instance; say so explicitly rather than "skipping".

---

## Step 5 — Expensive queries (`pg_stat_statements`)

```bash
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT left(query, 120) AS query_head,
         calls,
         round(total_exec_time::numeric, 1) AS total_ms,
         round(mean_exec_time::numeric, 1)  AS mean_ms,
         rows
  FROM pg_stat_statements
  ORDER BY total_exec_time DESC
  LIMIT ${TOP_N:-20};" 2>/dev/null \
|| echo "pg_stat_statements not available — skipping (install the extension and set shared_preload_libraries)"
```

Flag:

- Queries with high `total_exec_time` and high `calls` (hot path worth optimising).
- High `mean_exec_time` with low `calls` (individual slow query).
- `query_head` only — never the full query with literals; `pg_stat_statements` normalises literals to `$1` by default.

DEEP only: also rank by `shared_blks_read` (I/O heavy) and `temp_blks_written` (spilling to disk).

---

## Step 6 — Table and index bloat

```bash
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT schemaname, relname, n_live_tup, n_dead_tup,
         CASE WHEN n_live_tup > 0
              THEN round(100.0 * n_dead_tup / n_live_tup, 1) ELSE 0 END AS dead_pct,
         last_vacuum, last_autovacuum, last_analyze
  FROM pg_stat_user_tables
  WHERE n_dead_tup > 1000
  ORDER BY n_dead_tup DESC
  LIMIT ${TOP_N:-20};"
```

Flag:

- `dead_pct` above ~20% with a growing `n_dead_tup` — bloat; recommend `VACUUM (VERBOSE, ANALYZE)` after hours.
- `last_autovacuum` null on a busy table — autovacuum not keeping up (check `autovacuum_max_workers`, `autovacuum_vacuum_scale_factor`).
- `last_analyze` stale on a table with recent DML — planner statistics out of date.

Do **not** run `VACUUM` / `pg_repack` — list them as recommended actions.

---

## Step 7 — Missing-index candidates

```bash
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT relname AS table, seq_scan, idx_scan,
         CASE WHEN seq_scan + idx_scan > 0
              THEN round(100.0 * seq_scan / (seq_scan + idx_scan), 1) ELSE 0 END AS seq_pct,
         n_live_tup
  FROM pg_stat_user_tables
  WHERE seq_scan > 1000 AND n_live_tup > 10000
  ORDER BY seq_scan DESC
  LIMIT ${TOP_N:-20};"

psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT relname, indexrelname, idx_scan
  FROM pg_stat_user_indexes
  WHERE idx_scan = 0
  ORDER BY indexrelname
  LIMIT ${TOP_N:-20};"
```

Flag:

- Tables with high `seq_scan` and high `seq_pct` on large tables — candidates for an index review (not an automatic index recommendation).
- Zero-`idx_scan` indexes — likely redundant; report as candidates for review (not for dropping).
- Never emit a `CREATE INDEX` as an executed fix; list candidates for the DBA to validate with `EXPLAIN`.

---

## Step 8 — Replication lag

```bash
# Primary perspective
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT client_addr, state, sync_state,
         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
         replay_lag
  FROM pg_stat_replication
  ORDER BY replay_lag_bytes DESC;" 2>/dev/null \
|| echo "not a primary / no pg_stat_replication rows"

# Replica perspective (only if pg_is_in_recovery() is true, from Step 1)
psql "${!CONN_ENV}" -X -A -F $'\t' -c "
  SELECT pg_is_in_recovery() AS replica,
         now() - pg_last_xact_replay_timestamp() AS replay_delay;"
```

Flag:

- Replicas with `replay_lag_bytes` above a documented threshold or `state` not `streaming`.
- `sync_state: async` where the service expects synchronous replication — note the risk, don't change the config.
- A replica falling consistently behind (increasing `replay_delay`) — investigate network or load, do not touch the replica.

---

## Step 9 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/postgres-health-<host-slug>-<YYYYMMDD-HHMMSS>.md
```

Use the **host only** (no user, password, or query string) as the slug.

### Report structure

```markdown
# PostgreSQL Health Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Server version | <version> |
| Host | <host> |
| Role | primary / replica |
| Database | <db> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Connections
### Long-running and idle transactions
### Locks and blocking
### Expensive queries
### Table bloat and autovacuum
### Indexes
### Replication

## Recommended actions
<prioritized list — DBA applies; no statements were executed>
```

Present the user with:

1. Path to the saved report.
2. Verdict (🟢 / 🟡 / 🔴).
3. Top 3–5 recommended actions.

---

## Safety rules

- Every query is a **read-only `SELECT`**. No `INSERT`/`UPDATE`/`DELETE`/`DDL`, no `VACUUM`, `REINDEX`, `pg_repack`, or `pg_terminate_backend`.
- Never print the connection string, password, or bind-parameter values. Query text is truncated and normalised only.
- Treat `pg_stat_activity.query` as sensitive — it may contain literals if the app doesn't use bind parameters; truncate to `query_head`.
- If a query fails due to permissions, record the failure and continue — never attempt privilege escalation.
- Never change `postgresql.conf`, restart the server, or modify replication configuration.
- Confirm the host/role (primary vs replica) with the user before running any query.
