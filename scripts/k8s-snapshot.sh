#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# k8s-snapshot.sh — Dump cluster state to a timestamped file
# ────────────────────────────────────────────────────────────────
# Usage: ./k8s-snapshot.sh [namespace|all] [output-dir]
#
# Takes a read-only snapshot of key cluster resources:
#   nodes, pods, events, services, deployments, HPA, top
#
# Useful before/after changes, for incident records, or
# to share cluster state with someone who doesn't have access.
# ────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${1:-all}"
OUTPUT_DIR="${2:-.}"
CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

SCOPE_ARGS=()
if [ "$NAMESPACE" = "all" ]; then
  SCOPE_ARGS=(-A)
  FILENAME="k8s-snapshot-${CONTEXT}-all-${TIMESTAMP}.md"
else
  SCOPE_ARGS=(-n "$NAMESPACE")
  FILENAME="k8s-snapshot-${CONTEXT}-${NAMESPACE}-${TIMESTAMP}.md"
fi

OUT="${OUTPUT_DIR}/${FILENAME}"

echo "📸 Taking cluster snapshot..."
echo "   Context:   $CONTEXT"
echo "   Namespace: $NAMESPACE"
echo "   Output:    $OUT"
echo ""

{
  echo "# Kubernetes Cluster Snapshot"
  echo ""
  echo "| | |"
  echo "|---|---|"
  echo "| **Context** | \`$CONTEXT\` |"
  echo "| **Namespace** | \`$NAMESPACE\` |"
  echo "| **Timestamp** | $TIMESTAMP UTC |"
  echo ""

  echo "## Cluster info"
  echo '```'
  kubectl cluster-info 2>&1 || true
  echo '```'
  echo ""

  echo "## Nodes"
  echo '```'
  kubectl get nodes -o wide 2>&1 || true
  echo '```'
  echo ""

  echo "## Node resource usage"
  echo '```'
  kubectl top nodes 2>&1 || echo "metrics-server not available"
  echo '```'
  echo ""

  echo "## Namespaces"
  echo '```'
  kubectl get ns 2>&1 || true
  echo '```'
  echo ""

  echo "## Pods"
  echo '```'
  kubectl get pods "${SCOPE_ARGS[@]}" -o wide 2>&1 || true
  echo '```'
  echo ""

  echo "## Pod resource usage"
  echo '```'
  kubectl top pods "${SCOPE_ARGS[@]}" --sort-by=memory 2>&1 | head -30 || echo "metrics-server not available"
  echo '```'
  echo ""

  echo "## Problem pods"
  echo '```'
  kubectl get pods "${SCOPE_ARGS[@]}" --field-selector='status.phase!=Running,status.phase!=Succeeded' -o wide 2>&1 || true
  echo '```'
  echo ""

  echo "## Deployments"
  echo '```'
  kubectl get deploy "${SCOPE_ARGS[@]}" 2>&1 || true
  echo '```'
  echo ""

  echo "## StatefulSets"
  echo '```'
  kubectl get sts "${SCOPE_ARGS[@]}" 2>&1 || true
  echo '```'
  echo ""

  echo "## DaemonSets"
  echo '```'
  kubectl get ds "${SCOPE_ARGS[@]}" 2>&1 || true
  echo '```'
  echo ""

  echo "## Services"
  echo '```'
  kubectl get svc "${SCOPE_ARGS[@]}" 2>&1 || true
  echo '```'
  echo ""

  echo "## HPAs"
  echo '```'
  kubectl get hpa "${SCOPE_ARGS[@]}" -o wide 2>&1 || echo "none"
  echo '```'
  echo ""

  echo "## PVCs"
  echo '```'
  kubectl get pvc "${SCOPE_ARGS[@]}" 2>&1 || true
  echo '```'
  echo ""

  echo "## Recent warning events (last 50)"
  echo '```'
  kubectl get events "${SCOPE_ARGS[@]}" --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -50 || true
  echo '```'
  echo ""

  echo "---"
  echo "*Snapshot taken at $TIMESTAMP UTC by k8s-snapshot.sh*"

} > "$OUT"

echo "✅ Snapshot saved to: $OUT"
echo "   $(wc -l < "$OUT") lines"
