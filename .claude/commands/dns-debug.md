---
description: Diagnose DNS resolution across multiple resolvers — authoritative answers, record consistency, propagation, CNAME chains, and basic DNSSEC posture. Read-only, generates a markdown report.
argument-hint: "NAME=<fqdn> [TYPE=A|AAAA|CNAME|MX|TXT|NS|SOA] [RESOLVERS=...] [REPORT_DIR=...]"
---

# /dns-debug — DNS Resolution Diagnostics

Trace how a DNS name resolves across public resolvers, the authoritative servers, and the local system: authoritative answer, propagation consistency, CNAME chains, negative answers, TTLs, and basic DNSSEC status. **Read-only** — only DNS queries are sent.

## Prerequisites

- `dig` (bind-utils / dnsutils) — the `DEFAULT` requirement.
- Network egress to UDP/TCP 53.
- Optional: `host`, `nslookup` (fallbacks), `curl` for DoH cross-checks.
- Optional: `delv` or `dig +dnssec` for DNSSEC validation details.

## Inputs

- **NAME** *(required)* — the fully-qualified domain name to resolve.
- **TYPE** — record type. Default: `A`. Use `AAAA` for IPv6, plus others as needed (run multiple types if unsure).
- **RESOLVERS** — comma-separated resolver IPs to compare. Default: `1.1.1.1,8.8.8.8,9.9.9.9`.
- **REPORT_DIR** — report output directory. Default: `./dns-debug-reports`.

Confirm the name (and that the user owns/administers it) before querying.

---

## Step 1 — Local resolution and resolver config

```bash
echo "=== System resolvers ==="
scutil --dns 2>/dev/null | grep 'nameserver\[' | head -5 || cat /etc/resolv.conf 2>/dev/null | grep '^nameserver'
echo "=== Local answer ==="
dig +short "$NAME" "$TYPE"
```

Flag: no local answer while public resolvers disagree (split-horizon or broken local resolver).

---

## Step 2 — Delegation walk (authoritative path)

```bash
echo "=== Root -> TLD -> zone NS delegation ==="
dig +noall +authority +answer "$NAME" | sed -n '1,40p'

echo "=== Authoritative NS records ==="
dig +short NS "$NAME"
```

Flag:

- NS set that disagrees with the registrar (delegation mismatch) — a classic propagation failure.
- Lame delegation: an NS returns no authoritative data for the zone (`dig @<ns> "$NAME" "$TYPE"` without the `aa` flag).
- Missing glue / out-of-bailiwick nameservers that do not resolve.

---

## Step 3 — Query authoritative servers directly

```bash
for ns in $(dig +short NS "$NAME"); do
  echo "===== @$ns ====="
  dig +noall +answer +comment "@$ns" "$NAME" "$TYPE" | grep -E 'flags:|ANSWER SECTION|IN\s'
done
```

Flag:

- Different answers across authoritative servers (out-of-sync secondaries — serial/notify issue).
- No `aa` (authoritative answer) flag from any server — wrong server or misconfiguration.
- Very high or very low TTLs where a change is in progress (propagation expectation).

---

## Step 4 — Cross-resolver consistency

```bash
IFS=',' read -r -a RES <<< "${RESOLVERS:-1.1.1.1,8.8.8.8,9.9.9.9}"
for r in "${RES[@]}"; do
  printf '%-16s ' "$r"
  dig +short "@$r" "$NAME" "$TYPE" | sort | tr '\n' ' '
  echo
done
```

Flag:

- Resolvers returning different record sets — propagation incomplete or geo/anycast differences worth noting.
- `NXDOMAIN` from one resolver and an answer from another — cached negative or delegation bug.
- Empty answers everywhere — name may not exist, or only exists on a specific type.

---

## Step 5 — CNAME chain and DNSSEC

```bash
echo "=== CNAME chain ==="
dig +noall +answer "$NAME" | grep -i cname

echo "=== DNSSEC ==="
dig +dnssec +noall +answer "$NAME" "$TYPE" | grep -E 'RRSIG|ad;|do;' || echo "no DNSSEC signatures returned"
if command -v delv >/dev/null 2>&1; then
  delv "$NAME" "$TYPE" 2>&1 | tail -5
fi
```

Flag:

- Long CNAME chain (>3 hops) or a chain ending in `NXDOMAIN` — dangling CNAME.
- CNAME at the zone apex (illegal, breaks MX/SOA) — flag.
- DNSSEC `bogus` (validation failure), or signed zone not returning `ad` — security-relevant.

---

## Step 6 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/dns-debug-<name>-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# DNS Debug Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Name | <fqdn> |
| Type | <type> |
| Authoritative NS | <list> |
| Resolvers checked | <n> |
| Consistent | <yes/no> |

## Summary
<verdict: 🟢 resolving consistently / 🟡 inconsistent / 🔴 broken>

## Findings by category
### Delegation
### Authoritative answers
### Propagation across resolvers
### CNAME chain
### DNSSEC

## Recommended actions
<ordered fixes: registrar NS, zone records, TTL, DNSSEC signing>
```

---

## Safety rules

- Only DNS queries are performed — no zone transfers (`AXFR`) unless the user explicitly asks and owns the zone.
- Never attempt to modify records; remediation is listed as recommended actions (e.g. `rndc reload`, provider console steps).
- Query only the name and resolvers the user named — do not enumerate subdomains.
- Respect resolver rate limits; a handful of queries per name.
- Do not attempt resolver cache poisoning or spoofing tests.
