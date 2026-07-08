---
description: Fetch your open Jira issues from a project and save a dated markdown snapshot to ~/src/my_tasks/YYYY-MM-DD.md.
argument-hint: "[PROJECT=<key>] [OUTPUT_DIR=~/src/my_tasks]"
---

# /jira-my-tasks — My Open Jira Tasks

Read-only. Queries the Jira REST API for all issues assigned to you that are not Done, groups them by status, and writes a dated markdown file you can open, share, or diff across days.

## Prerequisites

- `~/.jira-credentials` with the following variables (chmod 600):

  ```text
  JIRA_BASE_URL=https://<org>.atlassian.net
  JIRA_EMAIL=<your-email>
  JIRA_TOKEN=<your-api-token>    # https://id.atlassian.com/manage-profile/security/api-tokens
  JIRA_ASSIGNEE_ID=<your-account-id>
  JIRA_PROJECT=<project-key>
  ```

- `python3` (stdlib only — no pip installs).
- `curl`.

## Inputs

- **PROJECT** — Jira project key. Default: value of `JIRA_PROJECT` in `~/.jira-credentials`.
- **OUTPUT_DIR** — Directory to write dated snapshots. Default: `~/src/my_tasks`.

Safe to rerun: each run overwrites only today's `${OUTPUT_DIR}/YYYY-MM-DD.md` snapshot; no other state is touched.

---

## Step 1 — Check prerequisites, load credentials, and resolve inputs

```bash
command -v curl >/dev/null || { echo "curl is required but not found"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required but not found"; exit 1; }

source ~/.jira-credentials 2>/dev/null || { echo "~/.jira-credentials not found"; exit 1; }

for var in JIRA_BASE_URL JIRA_EMAIL JIRA_TOKEN JIRA_ASSIGNEE_ID; do
  [ -n "${!var}" ] || { echo "Missing $var in ~/.jira-credentials"; exit 1; }
done

PROJECT="${PROJECT:-$JIRA_PROJECT}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/src/my_tasks}"
mkdir -p "$OUTPUT_DIR"

echo "Project : $PROJECT"
echo "Assignee: $JIRA_ASSIGNEE_ID"
echo "Output  : $OUTPUT_DIR"
```

---

## Step 2 — Fetch open issues from Jira

Credentials are passed via a `curl` config file rather than `-u` on the command line, so they don't appear in `ps`/process listings.

```bash
source ~/.jira-credentials
PROJECT="${PROJECT:-$JIRA_PROJECT}"
RESPONSE_FILE="$(mktemp -t jira_tasks.XXXXXX.json)"
CURL_CFG="$(mktemp -t jira_curl.XXXXXX.cfg)"
chmod 600 "$CURL_CFG"
trap 'rm -f "$RESPONSE_FILE" "$CURL_CFG"' EXIT

printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_TOKEN" > "$CURL_CFG"

/usr/bin/curl -s \
  -K "$CURL_CFG" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -X POST \
  "${JIRA_BASE_URL}/rest/api/3/search/jql" \
  -d "{
    \"jql\": \"project=${PROJECT} AND assignee=${JIRA_ASSIGNEE_ID} AND statusCategory != Done ORDER BY updated DESC\",
    \"fields\": [\"summary\",\"status\",\"priority\",\"issuetype\",\"updated\"],
    \"maxResults\": 50
  }" > "$RESPONSE_FILE"

rm -f "$CURL_CFG"
echo "Response saved to $RESPONSE_FILE"
python3 -c "import json; d=json.load(open('$RESPONSE_FILE')); print(f'Issues returned: {len(d.get(\"issues\",[]))}')"
```

If the response contains `errorMessages`, stop and report the error. Common causes: wrong `JIRA_BASE_URL`, expired token, or invalid `JIRA_ASSIGNEE_ID`.

---

## Step 3 — Write dated markdown snapshot

```bash
source ~/.jira-credentials
PROJECT="${PROJECT:-$JIRA_PROJECT}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/src/my_tasks}"
DATE=$(date +%Y-%m-%d)
OUTPUT_FILE="${OUTPUT_DIR}/${DATE}.md"

python3 - "$RESPONSE_FILE" "$OUTPUT_FILE" "$DATE" "$JIRA_BASE_URL" << 'PYEOF'
import json, sys

response_file, output_file, date, base_url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(response_file) as f:
    data = json.load(f)

issues = data.get('issues', [])
in_progress, ready, backlog = [], [], []

for i in issues:
    f = i['fields']
    status = f['status']['name']
    priority = f.get('priority', {}).get('name', 'N/A')
    itype = f['issuetype']['name']
    updated = f.get('updated', '')[:10]
    key = i['key']
    summary = f['summary']
    url = f"{base_url}/browse/{key}"
    line = f"- [{key}]({url}) — {summary} `{itype}` `{priority}` _(updated {updated})_"
    if 'progress' in status.lower():
        in_progress.append(line)
    elif 'test' in status.lower() or 'review' in status.lower():
        ready.append(line)
    else:
        backlog.append(line)

lines = [f"# My Tasks — {date}\n", f"**Total open:** {len(issues)}\n"]
if in_progress:
    lines += ["## In Progress\n"] + in_progress + [""]
if ready:
    lines += ["## Ready for Testing / Review\n"] + ready + [""]
if backlog:
    lines += ["## Backlog\n"] + backlog + [""]

content = '\n'.join(lines)
with open(output_file, 'w') as f:
    f.write(content)
print(f"Wrote {len(issues)} issues to {output_file}")
PYEOF

rm -f "$RESPONSE_FILE"
```

---

## Step 4 — Report

Print a brief summary:

- Total issues fetched
- Counts per section (In Progress / Ready for Testing / Backlog)
- Full path to the output file

Example:

```text
Wrote 29 issues to /Users/you/src/my_tasks/2026-07-07.md

In Progress        :  7
Ready for Testing  :  4
Backlog            : 18
```
