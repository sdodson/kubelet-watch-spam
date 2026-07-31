#!/usr/bin/env bash
# watch_distribution_monitor.sh — Track the distribution of active WATCH
# requests across the 3 kube-apiserver instances via Thanos/Prometheus.
#
# Logging cadence:
#   - Dense (every POLL_INTERVAL) while a kube-apiserver revision rollout
#     is in progress (any node has a non-zero targetRevision).
#   - One snapshot immediately when a rollout is detected starting,
#     labeled PRE-ROLLOUT-BASELINE, using the most recent pre-transition
#     reading (captures the "just before" state).
#   - One snapshot immediately when a rollout completes (ROLLOUT-COMPLETE).
#   - Otherwise, one snapshot every STEADY_INTERVAL seconds while steady.
#
# Usage:
#   KUBECONFIG=... ./watch_distribution_monitor.sh [outfile] [token_file]

set -uo pipefail

OUT="${1:-/tmp/watch_distribution.log}"
TOKEN_FILE="${2:-/tmp/.thanos_token}"
POLL_INTERVAL=20
STEADY_INTERVAL=300

THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
TOKEN=$(cat "$TOKEN_FILE")

query_watch_dist() {
  curl -sk -H "Authorization: Bearer ${TOKEN}" \
    --data-urlencode 'query=apiserver_longrunning_requests{apiserver="kube-apiserver",verb="WATCH"}' \
    "https://${THANOS_HOST}/api/v1/query" \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print(f'query-error={e}')
    sys.exit(0)
res={}
for r in d.get('data',{}).get('result',[]):
    inst=r['metric'].get('instance','?')
    val=float(r['value'][1])
    res[inst]=res.get(inst,0)+val
total=sum(res.values())
if not res:
    print('no-data')
else:
    parts=' '.join(f'{k}={int(v)}' for k,v in sorted(res.items()))
    print(f'{parts} total={int(total)}')
"
}

get_revision_state() {
  oc get kubeapiserver cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}={.currentRevision}/{.targetRevision} {end}'
}

echo "=== Watch distribution monitor started $(date -u +%FT%TZ) ===" >> "$OUT"

last_reading=""
is_rolling=false
last_steady_log=0

while true; do
  state=$(get_revision_state)
  now=$(date +%s)
  ts=$(date -u +%FT%TZ)
  currently_rolling=false
  echo "$state" | grep -qE '/[1-9][0-9]*' && currently_rolling=true

  dist=$(query_watch_dist)

  if [ "$currently_rolling" = true ] && [ "$is_rolling" = false ]; then
    if [ -n "$last_reading" ]; then
      echo "$last_reading" >> "$OUT"
    fi
    echo "$ts [ROLLOUT-START $state] $dist" >> "$OUT"
  elif [ "$currently_rolling" = true ]; then
    echo "$ts [ROLLOUT $state] $dist" >> "$OUT"
  else
    if [ "$is_rolling" = true ]; then
      echo "$ts [ROLLOUT-COMPLETE $state] $dist" >> "$OUT"
      last_steady_log=$now
    elif [ $((now - last_steady_log)) -ge $STEADY_INTERVAL ]; then
      echo "$ts [STEADY $state] $dist" >> "$OUT"
      last_steady_log=$now
    fi
  fi

  last_reading="$ts [PRE-ROLLOUT-BASELINE $state] $dist"
  is_rolling=$currently_rolling
  sleep "$POLL_INTERVAL"
done
