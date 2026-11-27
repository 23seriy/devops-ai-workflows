---
description: Read-only Redis health check — memory pressure and eviction, slow log, persistence (RDB/AOF), replication lag, connection saturation, keyspace hotspots, and dangerous config. Generates a markdown report.
argument-hint: "REDIS_ENV=<VAR_NAME> [DB=0] [TOP_N=20] [DEEP=yes|no] [REPORT_DIR=...]"
---

# /redis-health — Redis Health Diagnostics

Read-only health check for a Redis (or Valkey) instance or cluster. Covers memory usage and eviction, slow queries, persistence/RDB/AOF status, replication lag, client connections and fragmentation, keyspace distribution, and risky configuration. Produces a severity-ranked Markdown report.

**Read-only strictly enforced** — only `INFO`, `CONFIG GET`, `SLOWLOG GET`, `CLIENT LIST`, `MEMORY`, and `DBSIZE`-class commands. No `CONFIG SET`, `FLUSHDB`, `DEL`, `KEYS *`, or `DEBUG` commands.

## Prerequisites

- `redis-cli` client (matching the server major version ideally).
- Credentials provided via an environment variable holding either a redis URL (`redis://:pass@host:6379/0`) or a password.
- A user with at least read access to `INFO`, `CONFIG GET`, `SLOWLOG`, `CLIENT LIST` (`+@read` + specific admin reads).
- Optional: `jq` not required.

## Inputs

- **REDIS_ENV** *(required)* — name of the environment variable holding the connection URL. Default: `REDIS_URL`.
- **DB** — logical database index for keyspace checks. Default: `0`.
- **TOP_N** — number of rows per ranking. Default: `20`.
- **DEEP** — `yes` also samples key TTLs with `--scan` (never `KEYS *`) and reads `MEMORY STATS`. Default: `no`.
- **REPORT_DIR** — report output directory. Default: `./redis-health-reports`.

Never echo the connection URL or password. Confirm the target (and that it is not production, if relevant) **before running any command**.

---

## Step 1 — Connect and identify

```bash
: "${REDIS_ENV:=REDIS_URL}"
if [ -z "${!REDIS_ENV:-}" ]; then echo "ERROR: \$$REDIS_ENV is not set"; exit 1; fi
RC=(redis-cli -u "${!REDIS_ENV}")

"${RC[@]}" --no-auth-warning INFO server 2>/dev/null | grep -E 'redis_version|redis_mode|role|uptime_in_days|valkey_version'
"${RC[@]}" --no-auth-warning PING 2>/dev/null
```

Stop and report if `PING` fails. Never fall back to another host or with `--insecure`.

---

## Step 2 — Memory pressure and eviction

```bash
"${RC[@]}" --no-auth-warning INFO memory 2>/dev/null | grep -E 'used_memory_human|used_memory_peak_human|maxmemory_human|maxmemory_policy|mem_fragmentation_ratio|mem_allocator'
"${RC[@]}" --no-auth-warning CONFIG GET maxmemory 2>/dev/null
"${RC[@]}" --no-auth-warning CONFIG GET maxmemory-policy 2>/dev/null
"${RC[@]}" --no-auth-warning INFO stats 2>/dev/null | grep -E 'evicted_keys|expired_keys|keyspace_hits|keyspace_misses'
```

Flag:

- `used_memory` near `maxmemory` with a policy of `noeviction` — writes will start failing (`OOM command not allowed`).
- `evicted_keys` climbing — cache is too small for the working set (or TTLs are wrong).
- `mem_fragmentation_ratio` > 1.5 (RSS ≫ logical memory, allocator fragmentation) or < 1.0 (swap — severe).
- `maxmemory` = 0 on a cache instance — no ceiling; risk of host OOM.

---

## Step 3 — Persistence (RDB / AOF)

```bash
"${RC[@]}" --no-auth-warning INFO persistence 2>/dev/null | grep -E 'loading|rdb_last_bgsave_status|rdb_changes_since_last_save|rdb_last_save_time|aof_enabled|aof_last_bgrewrite_status|aof_last_write_status'
```

Flag:

- `rdb_last_bgsave_status:err` — background save failing (often disk full or fork/OOM).
- `aof_last_write_status:err` — AOF cannot write (disk full / permissions).
- `aof_enabled:0` and no RDB snapshots — data-loss risk on restart.
- `rdb_changes_since_last_save` very high with a long `rdb_last_save_time` — snapshot cadence too slow.

---

## Step 4 — Replication

```bash
"${RC[@]}" --no-auth-warning INFO replication 2>/dev/null | grep -E 'role|connected_slaves|slave[0-9]|master_link_status|master_last_io_seconds_ago|master_repl_offset|slave_repl_offset'
```

Flag:

- Replica `master_link_status:down` — replication broken (network, auth, or `masterauth`).
- `master_last_io_seconds_ago` high — replication lag / stalled stream.
- Offset gap between `master_repl_offset` (primary) and `slave_repl_offset` — measure lag.
- Zero connected replicas where the topology expects HA — note as a resiliency gap.

---

## Step 5 — Clients and connections

```bash
"${RC[@]}" --no-auth-warning INFO clients 2>/dev/null | grep -E 'connected_clients|blocked_clients|client_recent_max_input_buffer|client_recent_max_output_buffer'
"${RC[@]}" --no-auth-warning CONFIG GET maxclients 2>/dev/null
"${RC[@]}" --no-auth-warning CLIENT LIST 2>/dev/null | awk '{print $1, $2, $5, $6}' | head -5
```

Flag:

- `connected_clients` near `maxclients` — connection exhaustion (missing pooling).
- `blocked_clients` sustained — blocking commands (BLPOP/BRPOP) piling up.
- Many long-idle clients — pooler misconfiguration.

---

## Step 6 — Slow log and keyspace

```bash
"${RC[@]}" --no-auth-warning CONFIG GET slowlog-log-slower-than 2>/dev/null
"${RC[@]}" --no-auth-warning SLOWLOG GET "${TOP_N:-20}" 2>/dev/null | head -80
"${RC[@]}" --no-auth-warning INFO keyspace 2>/dev/null
"${RC[@]}" --no-auth-warning -n "${DB:-0}" DBSIZE 2>/dev/null
```

Flag:

- `slowlog-log-slower-than` = -1 — slow log disabled (you're blind to hot commands).
- `SLOWLOG GET` entries with `KEYS`, `SMEMBERS`, `HGETALL`, `FLUSH*` — O(N) command usage; flag for review.
- Keyspace with no TTL discipline (DEEP: sample `--scan` and `TTL` a subset) — memory growth.
- Never run `KEYS *`; use `SCAN` with a small count for sampling only.

---

## Step 7 — Dangerous configuration

```bash
for k in protected-mode appendonly appendfsync save timeout tcp-keepalive lazyfree-lazy-eviction lazyfree-lazy-expire; do
  printf '%-24s ' "$k"; "${RC[@]}" --no-auth-warning CONFIG GET "$k" 2>/dev/null | tail -1
done
```

Flag:

- `protected-mode no` exposed to the internet — critical.
- `appendonly no` with `save ""` — no persistence at all.
- `timeout 0` on a public/shared instance — idle connections accumulate.
- `CONFIG GET dir` / `dbfilename` on odd paths — misconfigured volume (risk of data on ephemeral disk).

---

## Step 8 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/redis-health-<host-slug>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Redis Health Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Version | <redis_version> |
| Mode / role | <standalone/cluster, primary/replica> |
| Host | <host only> |
| Used / Max memory | <> / <> |
| Connected clients | <n> |
| Evicted keys | <n> |

## Executive summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>
<top 3–5 findings ranked by severity>

## Findings by category
### Memory and eviction
### Persistence
### Replication
### Clients and connections
### Slow queries and keyspace
### Configuration

## Recommended actions
<prioritized — CONFIG SET suggestions listed for the operator to apply, never executed>
```

---

## Safety rules

- Only read commands: `INFO`, `CONFIG GET`, `SLOWLOG GET`, `CLIENT LIST`, `MEMORY STATS`, `DBSIZE`, `SCAN`. Never `CONFIG SET`, `FLUSHDB/ALL`, `DEL`, `KEYS *`, `BGREWRITEAOF`, `DEBUG`.
- Never print the connection URL or password.
- Never print key names in bulk (SCAN sampling is for counting/TTL only; report aggregates).
- If a command is denied by ACLs, record it and continue — never attempt privilege escalation.
- Confirm the target host/role with the user before running any command.
