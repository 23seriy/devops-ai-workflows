
# /k8s-rbac-audit — Kubernetes RBAC Audit

Inventory and risk-rank ClusterRoles, Roles, and their bindings. Spot the usual security smells before an attacker does.

## Prerequisites

- `kubectl` configured, with at least `get`/`list` on `*.rbac.authorization.k8s.io` cluster-wide.
- `jq`.
- Optional: `kubectl-who-can` plugin (krew) for richer "who can X" queries — workflow degrades gracefully without it.

## Inputs

- **NAMESPACE** — scope for namespaced Roles/Bindings, or `all`. Default: `all`.
- **REPORT_DIR** — Default: `./k8s-rbac-reports`.

---

## Step 1 — Inventory


```bash
kubectl get clusterroles -o json | jq '.items | length' | xargs -I{} echo "ClusterRoles: {}"
kubectl get clusterrolebindings -o json | jq '.items | length' | xargs -I{} echo "ClusterRoleBindings: {}"
[ "$NAMESPACE" = "all" ] && SCOPE="-A" || SCOPE="-n $NAMESPACE"
kubectl get roles $SCOPE -o json | jq '.items | length' | xargs -I{} echo "Roles: {}"
kubectl get rolebindings $SCOPE -o json | jq '.items | length' | xargs -I{} echo "RoleBindings: {}"
kubectl get sa $SCOPE -o json | jq '.items | length' | xargs -I{} echo "ServiceAccounts: {}"
```

---

## Step 2 — cluster-admin bindings (highest risk)


```bash
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | select(.roleRef.name=="cluster-admin") |
  .metadata.name as $n |
  .subjects[]? | "\($n)\tkind=\(.kind)\tname=\(.name)\tns=\(.namespace // "-")"'
```

Flag every subject. Especially: `system:authenticated`, `system:unauthenticated` (catastrophic), human users (should be rare), service accounts in app namespaces.

---

## Step 3 — Wildcards in ClusterRoles and Roles


```bash
echo "=== ClusterRoles with wildcard verbs/resources/apiGroups ==="
kubectl get clusterroles -o json | jq -r '
  .items[] | .metadata.name as $n |
  .rules[]? | select(
    (.verbs // []) | index("*")
  ) // (
    select((.resources // []) | index("*"))
  ) // (
    select((.apiGroups // []) | index("*"))
  ) | "\($n) verbs=\(.verbs) resources=\(.resources) apiGroups=\(.apiGroups)"' | sort -u

echo "=== Namespaced Roles with wildcards ==="
kubectl get roles -A -o json | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name)" as $n |
  .rules[]? | select(
    ((.verbs // []) | index("*")) or
    ((.resources // []) | index("*")) or
    ((.apiGroups // []) | index("*"))
  ) | "\($n) verbs=\(.verbs) resources=\(.resources) apiGroups=\(.apiGroups)"' | sort -u
```

---

## Step 4 — Risky verbs / resources


```bash
RISKY_VERBS='create|update|patch|delete|deletecollection|impersonate|escalate|bind'
RISKY_RES='secrets|pods/exec|pods/attach|pods/portforward|nodes/proxy|certificatesigningrequests|tokenreviews|subjectaccessreviews|clusterrolebindings|rolebindings|clusterroles|roles|serviceaccounts/token|persistentvolumes'

kubectl get clusterroles,roles -A -o json | jq -r --arg rv "$RISKY_VERBS" --arg rr "$RISKY_RES" '
  .items[] | (.kind + " " + (.metadata.namespace // "-") + "/" + .metadata.name) as $n |
  .rules[]? |
  ((.verbs // []) | map(select(test($rv))) ) as $v |
  ((.resources // []) | map(select(test($rr))) ) as $r |
  select(($v | length) > 0 and ($r | length) > 0) |
  "\($n) verbs=\($v) resources=\($r) apiGroups=\(.apiGroups)"' | sort -u | head -200
```

Pay extra attention to:

- `secrets` + `get`/`list` → token theft.
- `pods/exec` + `pods` → arbitrary code execution.
- `escalate`, `bind` on roles/clusterroles → privilege escalation.
- `serviceaccounts/token` + `create` → token forging (since Kubernetes 1.24).
- `nodes/proxy` → bypass SSO/audit.

---

## Step 5 — ServiceAccount → ClusterRole/Role mapping


```bash
# All SA bindings cluster-wide
kubectl get clusterrolebindings -o json | jq -r '
  .items[] | .metadata.name as $b | .roleRef.name as $r |
  .subjects[]? | select(.kind=="ServiceAccount") |
  "\(.namespace)/\(.name)\tCRB=\($b)\trole=ClusterRole/\($r)"' | sort

kubectl get rolebindings -A -o json | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name)" as $b |
  "\(.roleRef.kind)/\(.roleRef.name)" as $r |
  .subjects[]? | select(.kind=="ServiceAccount") |
  "\(.namespace // "<rb-ns>")/\(.name)\tRB=\($b)\trole=\($r)"' | sort
```

Flag: SAs bound to `cluster-admin`; SAs with multiple high-power bindings; default SAs (`default` in any namespace) with non-empty bindings.

---

## Step 6 — Workloads using non-default ServiceAccounts


```bash
[ "$NAMESPACE" = "all" ] && S="-A" || S="-n $NAMESPACE"
kubectl get pods $S -o json | jq -r '
  .items[] |
  "\(.metadata.namespace)/\(.metadata.name)\tSA=\(.spec.serviceAccountName // "default")\tautomount=\(.spec.automountServiceAccountToken // true)"' | sort -u
```

Flag: workloads still on `default` SA (best practice: dedicated SA per app); `automountServiceAccountToken: true` on workloads that don't call the API (token exposure risk).

---

## Step 7 — Aggregated ClusterRoles & built-in escalation paths


```bash
kubectl get clusterroles -o json | jq -r '
  .items[] | select(.aggregationRule != null) |
  "\(.metadata.name) labelSelectors=\(.aggregationRule.clusterRoleSelectors)"'

# Roles aggregated INTO admin/edit/view
kubectl get clusterroles -l rbac.authorization.k8s.io/aggregate-to-admin=true -o name
kubectl get clusterroles -l rbac.authorization.k8s.io/aggregate-to-edit=true -o name
kubectl get clusterroles -l rbac.authorization.k8s.io/aggregate-to-view=true -o name
```

Flag: custom CRs aggregating into `admin` or `edit` that grant unexpected verbs (admin/edit then silently get more power on every cluster they're applied to).

---

## Step 8 — Unused roles (heuristic)


```bash
# ClusterRoles with no binding referencing them
ALL_CR=$(kubectl get clusterroles -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort -u)
USED_CR=$(kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
  .items[] | select(.roleRef.kind=="ClusterRole") | .roleRef.name' | sort -u)
echo "=== ClusterRoles with no bindings ==="
comm -23 <(echo "$ALL_CR") <(echo "$USED_CR") | head -50
```

Heuristic only — system-managed CRs may legitimately have no bindings yet.

---

## Step 9 — Group / user subjects (catch leftover human accounts)


```bash
kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
  .items[] | (.kind + " " + (.metadata.namespace // "-") + "/" + .metadata.name) as $b |
  .roleRef as $r | .subjects[]? |
  select(.kind=="User" or .kind=="Group") |
  "\($b)\tsubject=\(.kind)/\(.name)\trole=\($r.kind)/\($r.name)"' | sort -u
```

Flag: bindings to `system:masters` Group (effectively cluster-admin), individual `User` subjects (should usually be Groups via OIDC/SSO).

---

## Step 10 — "Who can do X?" sanity checks


```bash
for q in "create pods" "get secrets" "create clusterrolebindings" "impersonate users" "create serviceaccounts/token" "patch nodes" "create pods/exec"; do
  echo "=== Who can $q ==="
  kubectl auth can-i $q --as=system:anonymous 2>/dev/null && echo "  ⚠️ anonymous can!"
  kubectl who-can $q 2>/dev/null || echo "  (kubectl-who-can plugin not installed)"
done
```

---

## Step 11 — Generate report

Write `$REPORT_DIR/k8s-rbac-<context>-<timestamp>.md`:

1. Header + cluster context + identity.
2. Executive summary + risk verdict (Low/Medium/High/Critical).
3. **Critical findings**: anonymous/`system:authenticated` cluster-admin, group cluster-admin bindings, secrets-readable wildcards.
4. Wildcard table (ClusterRole/Role, verbs, resources).
5. Risky verb-resource combinations (Step 4).
6. SA → role map summary, `default` SA usage.
7. User/Group subject inventory.
8. Unused-role heuristic (Step 8) — informational.
9. Recommended actions (P1/P2/P3) with concrete `kubectl` commands.
10. Appendix: command transcript.

Print path + top 3 P1 actions.

---

## Risk severity guide

- 🔴 **Critical**: anonymous or `system:authenticated` bound to cluster-admin; SA with `*/*/*`; ability for non-admins to create RoleBindings/ClusterRoleBindings or `escalate`/`bind`.
- 🟡 **Medium**: wildcards on namespaced Roles, default SA bound to anything beyond view, automountServiceAccountToken on non-API workloads, broad `secrets:list` outside of platform namespaces.
- 🔵 **Low/Info**: stale unused ClusterRoles, individual User subjects (consider SSO Groups), aggregated CRs adding broad verbs.

---

## Safety rules

- 100% read-only. No `create`, `apply`, `patch`, `delete`.
- Never print secret contents — only names and metadata.
- RBAC failures recorded in report; do not attempt elevation.
