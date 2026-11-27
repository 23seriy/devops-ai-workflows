---
description: Audit TLS certificates across a list of hosts — chain validity, expiry, weak protocols/ciphers, hostname match, and revocation posture. Read-only, generates a markdown report.
argument-hint: "HOSTS=<file|comma-list> [PORT=443] [WARN_DAYS=30] [SNI=yes|no] [REPORT_DIR=...]"
---

# /tls-cert-audit — TLS Certificate & Configuration Audit

Audit the TLS posture of one or more hosts: certificate chain, expiry, hostname/SAN match, protocol and cipher support, and basic revocation indicators. **Read-only** — only TLS handshakes are performed; no traffic beyond the handshake is sent.

## Prerequisites

- `openssl` (1.1.1+ preferred for `-s_client` features).
- Network access to the target hosts on the audited port.
- Optional: `nmap` with `ssl-enum-ciphers` for cipher enumeration.
- Optional: `curl` for HTTP-level checks (redirect to HTTPS, HSTS).

## Inputs

- **HOSTS** *(required)* — a comma-separated list of `host[:port]` entries, or a file path (one host per line).
- **PORT** — default port when a host omits one. Default: `443`.
- **WARN_DAYS** — expiry warning threshold in days. Default: `30`.
- **SNI** — `yes` sends the hostname as SNI (required for most modern servers). Default: `yes`.
- **REPORT_DIR** — report output directory. Default: `./tls-cert-audit-reports`.

---

## Step 1 — Resolve the host list

```bash
if [ -f "$HOSTS" ]; then
  mapfile -t TARGETS < "$HOSTS" 2>/dev/null || IFS=$'\n' read -r -d '' -a TARGETS < "$HOSTS"
else
  IFS=',' read -r -a TARGETS <<< "$HOSTS"
fi
printf '%s\n' "${TARGETS[@]}" | sed 's/^ *//; s/ *$//' | grep -v '^$' | sort -u
```

If the resolved list is empty, stop and report. Confirm the host list with the user before connecting (avoid scanning hosts out of scope).

---

## Step 2 — Certificate chain and validity

For each target:

```bash
for t in "${TARGETS[@]}"; do
  h=${t%%:*}; p=${t##*:}; [ "$p" = "$t" ] && p=${PORT:-443}
  echo "===== $h:$p ====="
  timeout 15 openssl s_client -connect "$h:$p" -servername "$h" -showcerts </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName,keyUsage,extendedKeyUsage 2>/dev/null \
    || echo "HANDSHAKE FAILED: $h:$p"
  # Chain verification
  timeout 15 openssl s_client -connect "$h:$p" -servername "$h" -verify_return_error </dev/null 2>&1 \
    | grep -E 'Verify return code|verify error' || true
done
```

Flag:

- `HANDSHAKE FAILED` — connection refused, timeout, or protocol mismatch.
- `Verify return code` not `0 (ok)` — incomplete chain (common: missing intermediate), self-signed, or expired.
- Expiry within `WARN_DAYS` — report exact `notAfter` and days remaining.
- Hostname not present in `subjectAltName` (legacy CN-only certs) — modern clients reject.
- Key usage missing `digitalSignature`/`keyEncipherment` for the server role.

---

## Step 3 — Protocol and cipher posture

```bash
for t in "${TARGETS[@]}"; do
  h=${t%%:*}; p=${t##*:}; [ "$p" = "$t" ] && p=${PORT:-443}
  echo "===== $h:$p protocol matrix ====="
  for v in -tls1_2 -tls1_3 -tls1_1 -tls1; do
    if timeout 10 openssl s_client $v -connect "$h:$p" -servername "$h" </dev/null >/dev/null 2>&1; then
      echo "  $v: SUPPORTED"
    else
      echo "  $v: not supported"
    fi
  done
done
```

Flag:

- TLS 1.0 or 1.1 supported — deprecated; PCI-DSS and modern baselines require TLS 1.2+.
- TLS 1.3 *not* supported on public endpoints — not a hard failure, but note it.
- Optional `nmap --script ssl-enum-ciphers -p $p $h` to enumerate accepted ciphers; flag `RC4`, `3DES`, `DES`, `NULL`, `EXPORT`, and CBC-mode suites as weak.

---

## Step 4 — HTTP-level TLS signals

```bash
for t in "${TARGETS[@]}"; do
  h=${t%%:*}; p=${t##*:}; [ "$p" = "$t" ] && p=${PORT:-443}
  echo "===== $h:$p HTTP ====="
  curl -sS -o /dev/null -D - --max-time 10 "https://$h:$p/" 2>/dev/null | grep -iE '^strict-transport-security|^location' || echo "no HSTS / no redirect headers"
  # Plain HTTP redirect check
  curl -sS -o /dev/null -w 'http_status=%{http_code} redirect=%{redirect_url}\n' --max-time 10 "http://$h/" 2>/dev/null || echo "no HTTP listener"
done
```

Flag:

- No `Strict-Transport-Security` header on HTTPS responses.
- HTTP listener that does not redirect to HTTPS.
- Redirect to a different hostname (cert must still match the final host).

---

## Step 5 — Generate report

Compile all findings into a timestamped Markdown report:

```text
$REPORT_DIR/tls-cert-audit-<YYYYMMDD-HHMMSS>.md
```

### Report structure

```markdown
# TLS Certificate Audit Report

| Field | Value |
|---|---|
| Generated | <timestamp> |
| Hosts audited | <n> |
| Failing | <n> |
| Expiring soon | <n> |

## Summary
<verdict: 🟢 healthy / 🟡 needs attention / 🔴 critical findings>

## Per-host results
| Host:Port | Subject | Issuer | Expires | Days left | Chain OK | TLS min | HSTS | Verdict |
|---|---|---|---|---|---|---|---|---|

## Findings
### 🔴 Critical
<expired, invalid chain, hostname mismatch, TLS 1.0/1.1, weak ciphers>
### 🟡 Warning
<expiring soon, no HSTS, missing HTTP→HTTPS redirect>
### 🔵 Info
<no TLS 1.3, minor hardening>

## Recommended actions
<renewal steps, chain fix, protocol/cipher policy, HSTS rollout>
```

---

## Safety rules

- This workflow performs **TLS handshakes only** — no authentication, no data beyond the handshake, no vulnerability exploitation.
- Never run intrusive scans (`ssl-heartbleed`, `ssl-drown`, etc.) without explicit user consent; note them as optional follow-ups.
- Never send client certificates or credentials.
- Only connect to hosts the user named — do not expand scope or crawl discovered hostnames without confirming.
- Respect rate limits: one handshake per check per host; do not loop aggressively.
- Report certificate contents (subject/issuer/SAN) only — never private keys (they are never transmitted anyway).
