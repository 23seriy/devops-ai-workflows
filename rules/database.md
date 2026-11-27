# Database Agent Rules

Agent-agnostic safety guardrails for database work (PostgreSQL, MySQL, Redis). Reference from a project's `CLAUDE.md`, paste into a system prompt, or include as context when working on database changes.

## Identity and target safety — non-negotiable

- ALWAYS confirm the target host, instance/cluster, and environment (prod/staging/dev) before connecting. Never fall back to a different host or credential after a failure.
- NEVER connect to production with a read-write application role for investigation — use a read-only or `pg_monitor`-class role.
- NEVER run `DROP`, `TRUNCATE`, `DELETE` without a `WHERE` clause, or `FLUSHDB`/`FLUSHALL` — these are data-loss operations and require explicit confirmation plus a verified backup.

## Read-only investigation

- Prefer read-only catalog/stat views: `pg_stat_*`, `information_schema`, `redis INFO`/`SLOWLOG GET`/`CONFIG GET`.
- Use parameterised queries in examples — never interpolate user input into SQL.
- Never use `SELECT *` on large tables during investigation; select the columns you need with a `LIMIT`.
- In Redis, never use `KEYS *` in production — use `SCAN` with a small `COUNT`.

## Migrations and schema changes

- Treat every migration as a code change: review it, test it on a copy, and have a rollback path.
- Prefer **expand/contract** for breaking changes: add the new shape, backfill, switch reads/writes, then remove the old shape in a later release.
- Set `lock_timeout` and `statement_timeout` before DDL so a blocked lock doesn't queue every request behind it.
- Never add a `NOT NULL` column without a default to a populated table in one step.
- Use `CREATE INDEX CONCURRENTLY` (Postgres) / online DDL (MySQL) for indexes on live tables.
- Batch large backfills and make them resumable.

## Secrets and data

- NEVER print connection strings, passwords, or bind-parameter values.
- Treat query text and log lines as potentially sensitive — truncate and redact before including them in output.
- Never copy production data into a non-production environment without anonymisation.

## Performance work

- Base recommendations on `EXPLAIN (ANALYZE, BUFFERS)`, not intuition. Never suggest dropping an index without checking usage stats.
- Changing a planner/configuration parameter is a production change — propose it, don't apply it.
- Never restart the database server or reload configuration without confirmation and a maintenance window.
