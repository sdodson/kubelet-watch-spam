#!/usr/bin/env bash
# churn_namespace.sh — Repeatedly delete and fully recreate one namespace,
# to simulate namespace churn happening concurrently with kube-apiserver
# rolling restarts (see run_rounds.sh).
#
# Each cycle: delete the target namespace, re-run setup_workload.sh (which is
# idempotent — the other 9 namespaces are detected as already-correct and
# skipped quickly; only the deleted namespace actually gets recreated), wait
# for it to reach Running, then sleep before the next cycle.
#
# Usage:
#   ./churn_namespace.sh [OPTIONS]
#
# Options:
#   -n NAMESPACE      Namespace to churn (default: mount-spam-9)
#   -s SLEEP_SECONDS  Seconds to sleep between cycles, after recreation
#                     completes (default: 300)
#   -k KUBECONFIG     Path to kubeconfig (default: $KUBECONFIG)
#   -h                Show this help
#
# The recreated namespace uses the SAME resource shape as the main workload
# (see setup_workload.sh args below) — keep these in sync if the main
# workload config changes.

set -euo pipefail

NAMESPACE="mount-spam-9"
SLEEP_SECONDS=300

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while getopts "n:s:k:h" opt; do
  case $opt in
    n) NAMESPACE=$OPTARG ;;
    s) SLEEP_SECONDS=$OPTARG ;;
    k) export KUBECONFIG=$OPTARG ;;
    h) usage ;;
    *) echo "Unknown option: $opt" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Must match the current main workload config (setup_workload.sh invocation)
# exactly, or the churned namespace will drift from the other 9.
SETUP_ARGS=(-n 10 -p 290 -q 8 -w 8 -u 5 -v 32 -r 8 -i 8192 -o 8 -j 8192 \
            -s 1 -f 131072 -c 2 -z 262144 -b 5 -x 5 -g 300 -m 512)

echo "=== Namespace churn loop ==="
echo "  Target:      $NAMESPACE"
echo "  Sleep:       ${SLEEP_SECONDS}s between cycles"
echo "  Workload:    setup_workload.sh ${SETUP_ARGS[*]}"
echo ""

cycle=0
while true; do
  cycle=$((cycle + 1))
  echo ""
  echo "=== Cycle $cycle: $(date -u +%FT%TZ) ==="

  echo "  Deleting namespace $NAMESPACE..."
  if kubectl delete namespace "$NAMESPACE" --wait=true --timeout=300s; then
    echo "  Deleted."
  else
    echo "  WARNING: delete did not confirm cleanly (may already be gone or stuck terminating) — continuing."
  fi

  echo "  Recreating workload (idempotent — only $NAMESPACE should need real work)..."
  if ! "${SCRIPT_DIR}/setup_workload.sh" "${SETUP_ARGS[@]}"; then
    echo "  WARNING: setup_workload.sh failed this cycle (e.g. wave-abort) — will retry next cycle."
  fi

  echo "  Cycle $cycle complete. Sleeping ${SLEEP_SECONDS}s..."
  sleep "$SLEEP_SECONDS"
done
