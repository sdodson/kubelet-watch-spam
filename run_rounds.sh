#!/usr/bin/env bash
# run_rounds.sh — Trigger kube-apiserver rolling restarts and record peak go_threads.
#
# Each round forces a new kube-apiserver revision, waits for the full 3-master
# rollout to complete, and records the maximum go_threads seen during the round.
# Thread counts come from the in-cluster Prometheus instance.
#
# Usage:
#   ./run_rounds.sh [OPTIONS]
#
# Options:
#   -r ROUNDS       Number of rounds to run (default: 5)
#   -w WAIT         Seconds to wait between rounds (default: 60)
#   -t TIMEOUT      Seconds to wait for each rollout (default: 1200)
#   -l LABEL        Label for this run, used in forceRedeploymentReason (default: test)
#   -k KUBECONFIG   Path to kubeconfig (default: $KUBECONFIG)
#   -h              Show this help
#
# Output:
#   One RESULT line per round:  RESULT round=N peak=THREADS
#   Round 1 is typically discarded (convention: first round after any
#   configuration change catches carry-over state).
#
# Example:
#   ./run_rounds.sh -r 5 -l kubelet-watch-31k
#   ./run_rounds.sh -r 3 -l kubelet-watch-65k -w 30

set -euo pipefail

ROUNDS=5
WAIT=60
TIMEOUT=1200
LABEL="test"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while getopts "r:w:t:l:k:h" opt; do
  case $opt in
    r) ROUNDS=$OPTARG ;;
    w) WAIT=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    l) LABEL=$OPTARG ;;
    k) export KUBECONFIG=$OPTARG ;;
    h) usage ;;
    *) echo "Unknown option: $opt" >&2; exit 1 ;;
  esac
done

# Verify prerequisites
for cmd in kubectl oc python3; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 1; }
done

prometheus_query() {
  local query="$1"
  oc exec -n openshift-monitoring prometheus-k8s-0 -- \
    curl -sg --max-time 8 \
    "http://localhost:9090/api/v1/query?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")" \
    2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    r = d['data']['result']
    print(r[0]['value'][1] if r else '')
except Exception:
    print('')
" 2>/dev/null
}

get_threads() {
  oc exec -n openshift-monitoring prometheus-k8s-0 -- \
    curl -sg --max-time 5 \
    'http://localhost:9090/api/v1/query?query=go_threads{job="apiserver"}' \
    2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for r in d['data']['result']:
        print(r['metric']['instance'], r['value'][1])
except Exception:
    pass
" 2>/dev/null || true
}

get_node_revisions() {
  oc get kubeapiserver cluster \
    -o jsonpath='{.status.nodeStatuses}' 2>/dev/null | \
    python3 -c "
import json, sys
try:
    ns = json.loads(sys.stdin.read())
    for n in ns:
        print(n['nodeName'].split('.')[0], n.get('currentRevision', '?'))
except Exception:
    pass
" 2>/dev/null || true
}

run_round() {
  local round=$1
  local start peak=0
  start=$(date +%s)

  printf "\n=== Round %d at %s ===\n" "$round" "$(date '+%H:%M:%S')"

  local reason="${LABEL}-r${round}-$(date +%s)"
  kubectl patch kubeapiserver cluster --type=merge \
    -p "{\"spec\":{\"forceRedeploymentReason\":\"${reason}\"}}" 2>/dev/null

  local cur_rev
  cur_rev=$(oc get kubeapiserver cluster \
    -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null)
  local target_rev=$((cur_rev + 1))
  printf "  rev %s -> %s\n" "$cur_rev" "$target_rev"

  # Track per-node minimum observed thread count. Using the minimum as a
  # rolling baseline removes carry-over from prior rounds: a node with 1,422
  # stale threads starts with min=1422 (delta=0); after it restarts and drops
  # to ~20, min resets to 20 and subsequent spikes are measured correctly.
  declare -A min_threads

  local deadline=$((SECONDS + TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    local elapsed=$(( $(date +%s) - start ))

    local st
    st=$(get_node_revisions)

    local th
    th=$(get_threads)

    # Track peak as max delta above each node's rolling minimum.
    while IFS=' ' read -r ip v; do
      [ -z "$ip" ] && continue
      v=${v%.*}
      local cur=${v:-0}
      local min=${min_threads[$ip]:-$cur}
      [ "$cur" -lt "$min" ] && min=$cur
      min_threads[$ip]=$min
      local delta=$(( cur - min ))
      [ "$delta" -gt "$peak" ] && peak=$delta
    done <<< "$th"

    printf "  t+%3ds  [%s]  [%s]\n" \
      "$elapsed" \
      "$(echo "$st" | awk '{printf "%s=%s ", $1, $2}')" \
      "$(echo "$th" | awk '{printf "%s=%s ", $1, $2}')"

    # Check completion: all nodes at target rev and all pods Running
    local all_done=true
    while IFS=' ' read -r _node rev; do
      [ "${rev:-0}" -lt "$target_rev" ] 2>/dev/null && all_done=false
    done <<< "$st"

    if $all_done; then
      local running
      running=$(oc get pods -n openshift-kube-apiserver -l apiserver=true \
        --no-headers 2>/dev/null | grep -c Running || true)
      [ "$running" -eq 3 ] && break
    fi

    sleep 15
  done

  printf "RESULT round=%d peak=%d\n" "$round" "$peak"
}

echo "=== kube-apiserver rolling restart measurement ==="
echo "  Rounds:  $ROUNDS"
echo "  Label:   $LABEL"
echo "  Wait:    ${WAIT}s between rounds"
echo "  Timeout: ${TIMEOUT}s per round"
echo ""
echo "  Note: Round 1 is typically discarded — it captures carry-over"
echo "        threads from any prior state, not a clean spike measurement."

for r in $(seq 1 "$ROUNDS"); do
  run_round "$r"
  if [ "$r" -lt "$ROUNDS" ]; then
    echo "  Cooling ${WAIT}s..."
    sleep "$WAIT"
  fi
done

echo ""
echo "=== Summary ==="
echo "  Label: $LABEL"
echo "  (Discard round 1 if starting from elevated thread count)"
