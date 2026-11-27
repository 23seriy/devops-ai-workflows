---
description: Review database migration scripts for risky patterns — locking DDL, long transactions, irreversible down-migrations, destructive column changes, and missing concurrent/batched strategies. Read-only static analysis.
argument-hint: "MIGRATION_PATH=<file|dir> [DIALECT=auto|postgres|mysql|sqlite] [DEEP=yes|no] [REPORT_DIR=...]"
---

# /db-migration-review — Database Migration Risk Review

Static review of database migration files (SQL, and the generated SQL from ORMs like Alembic / Django / Flyway / Liquibase when available) for patterns that cause outages: table-locking DDL, rewrites of large tables, destructive or irreversible changes, non-transactional DDL, and risky data backfills. **Read-only** — no database connection is required and no migration is executed.

## Prerequisites

- Migration files to review (`.sql`, or ORM migration dirs for context).
- Optional: `sqlfluff` or `sqlint` for syntax/consistency checks.
- Optional: a database connection *only* if the user wants the review to consider table sizes (`DEEP=yes`); otherwise none.

## Inputs

- **MIGRATION_PATH** *(required)* — a migration file, a directory of migrations, or a glob.
- **DIALECT** — SQL dialect for accurate rules. Default: `auto` (inferred from file extension/ORM markers or asked).
- **DEEP** — `yes` also analyses the paired down/rollback migration where present. Default: `no`.
- **REPORT_DIR** — report output directory. Default: `./db-migration-review-reports`.

---

## Step 1 — Discover and read migrations

```bash
if [ -d "$MIGRATION_PATH" ]; then
  find "$MIGRATION_PATH" -type f \( -name '*.sql' -o -name '*.py' -o -name '*.rb' -o -name '*.xml' -o -name '*.yaml' \) | sort
else
  ls $MIGRATION_PATH
fi
```

Report the files reviewed up front. If none are found, stop.

---

## Step 2 — Destructive and irreversible changes

```bash
grep -niE 'DROP[[:space:]]+(TABLE|COLUMN|INDEX|CONSTRAINT)|TRUNCATE|ALTER[[:space:]]+TABLE.*DROP|DELETE[[:space:]]+FROM' $MIGRATIONS 2>/dev/null
grep -niE 'RENAME[[:space:]]+(TABLE|COLUMN)|ALTER[[:space:]]+COLUMN.*TYPE' $MIGRATIONS 2>/dev/null
```

Flag:

- `DROP TABLE` / `DROP COLUMN` in a migration that ships with the code — data loss; recommend a two-phase (expand/contract) approach.
- `TRUNCATE` / unqualified `DELETE FROM` — catastrophic if mis-scoped; flag hard.
- Column type changes (`ALTER COLUMN ... TYPE`) that force a table rewrite or lose precision.
- Renames without a compatibility window — breaks in-flight application code.
- No `down`/rollback migration (DEEP) — irreversible; require a documented restore plan.

---

## Step 3 — Locking and blocking DDL

```bash
grep -niE 'ALTER[[:space:]]+TABLE|ADD[[:space:]]+(COLUMN|CONSTRAINT)|CREATE[[:space:]]+(UNIQUE[[:space:]]+)?INDEX|ADD[[:space:]]+PRIMARY' $MIGRATIONS 2>/dev/null
grep -niE 'CREATE[[:space:]]+INDEX' $MIGRATIONS 2>/dev/null | grep -viE 'concurrently|online'
grep -niE 'ALTER[[:space:]]+TABLE.*(ADD|MODIFY|ALTER).*NOT[[:space:]]+NULL' $MIGRATIONS 2>/dev/null
```

Flag:

- `CREATE INDEX` without `CONCURRENTLY` (Postgres) / `ALGORITHM=INPLACE, LOCK=NONE` (MySQL) — blocks writes.
- Adding a `NOT NULL` column without a default on a populated table — fails or rewrites.
- `ALTER TABLE ... SET NOT NULL` without a validated constraint first.
- Multiple DDL statements in one transaction on MySQL (implicit commits) — partial-failure risk.

---

## Step 4 — Long-running and risky data operations

```bash
grep -niE 'UPDATE[[:space:]]+[A-Za-z_"]+[[:space:]]+SET|INSERT[[:space:]]+INTO.*SELECT|CREATE[[:space:]]+TABLE.*AS[[:space:]]+SELECT' $MIGRATIONS 2>/dev/null
grep -niE 'WHERE[[:space:]]+1=1|WHERE[[:space:]]+TRUE|LIMIT[[:space:]]+[0-9]{6,}' $MIGRATIONS 2>/dev/null
```

Flag:

- Unbatched `UPDATE ... SET` over an entire large table in one transaction — lock time + WAL bloat; recommend batching with a bounded predicate.
- `INSERT INTO ... SELECT` / `CREATE TABLE AS SELECT` on large tables — long-running; recommend `--jobs`/chunking or an out-of-band job.
- Backfills that assume an empty table.
- Operations that will hold an `ACCESS EXCLUSIVE` lock while doing data work.

---

## Step 5 — Transaction and ordering safety

```bash
grep -niE 'BEGIN|COMMIT|ROLLBACK|SAVEPOINT' $MIGRATIONS 2>/dev/null
grep -niE 'SET[[:space:]]+(session|lock_timeout|statement_timeout)|LOCK[[:space:]]+TABLE' $MIGRATIONS 2>/dev/null
grep -niE 'ENABLE[[:space:]]+(REPLICA|ALWAYS)[[:space:]]+TRIGGER|DISABLE[[:space:]]+TRIGGER' $MIGRATIONS 2>/dev/null
```

Flag:

- Missing `lock_timeout` / `statement_timeout` on DDL — a blocked table can queue every request behind it.
- `ENABLE ALWAYS/REPLICA TRIGGER` / disabled triggers — can break logical replication or hide writes.
- DDL and DML in the same transaction on engines that disallow it.
- Migrations that depend on being applied in exact order but lack versioning.

---

## Step 6 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/db-migration-review-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# Database Migration Review Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Dialect | <postgres/mysql/sqlite> |
| Migrations reviewed | <n> |
| Highest risk | 🔴 / 🟡 / 🟢 |

## Summary
<1-2 sentence assessment>

## Findings

### 🔴 Critical
<data-destroying DDL, unqualified DELETE/TRUNCATE, irreversible without rollback>

### 🟡 Warning
<locking DDL, unbatched backfills, missing timeouts, missing CONCURRENTLY>

### 🔵 Info
<suggested ordering, batching strategy, future index plans>

## Per-migration breakdown
<each file with line references and the recommended rewrite>

## Safe migration checklist
<expand/contract steps, lock timeouts, rollback plan, monitoring during apply>
```

---

## Safety rules

- This workflow is **entirely static and read-only**. No database is connected to, and no migration is executed.
- `DEEP` never runs SQL against a live database without explicit user consent; even then, only `SELECT` metadata queries.
- Never print credentials from migration/config files; redact connection strings.
- Recommended rewrites are suggestions for the author — do not auto-apply changes to migration files.
