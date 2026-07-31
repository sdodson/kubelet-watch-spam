#!/usr/bin/env bash
# monitor_and_capture.sh — Continuously watch go_threads on all kube-apiserver
# nodes; the moment a spike is detected, immediately snapshot that node's
# current audit log to disk (before it can rotate away) and run a quick
# burst analysis. Designed to run unattended for hours/days so that a spike
# occurring at any time (not just during a scripted run_rounds.sh round) is
# captured before OpenShift's audit log rotation destroys the evidence.
#
# Usage:
#   ./monitor_and_capture.sh [OPTIONS]
#
# Options:
#   -t THRESHOLD    Delta-above-rolling-min that counts as a spike (default: 300)
#   -i INTERVAL     Poll interval in seconds (default: 15)
#   -o OUTDIR       Directory to write captures into (default: ./spike-captures)
#   -k KUBECONFIG   Path to kubeconfig (default: $KUBECONFIG)
#   -h              Show this help
#
# Output:
#   ${OUTDIR}/<node>_<timestamp>_audit.jsonl            — raw audit log snapshot
#   ${OUTDIR}/<node>_<timestamp>_analysis.txt           — verb/URI/user burst breakdown
#   ${OUTDIR}/<node>_<timestamp>_topnodes.txt           — top kubelet source hostnames
#   ${OUTDIR}/<node>_<timestamp>_kubelet_<host>.log     — kubelet journal from each source node
#   ${OUTDIR}/<node>_<timestamp>_apiserver_pod.log      — kube-apiserver container log
#   One line to stdout per poll; a "SPIKE" line whenever a capture fires.
#
# Example:
#   nohup ./monitor_and_capture.sh -t 300 -i 15 > /tmp/monitor.log 2>&1 &

set -uo pipefail

THRESHOLD=300
INTERVAL=15
OUTDIR="./spike-captures"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while getopts "t:i:o:k:h" opt; do
  case $opt in
    t) THRESHOLD=$OPTARG ;;
    i) INTERVAL=$OPTARG ;;
    o) OUTDIR=$OPTARG ;;
    k) export KUBECONFIG=$OPTARG ;;
    h) usage ;;
    *) echo "Unknown option: $opt" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTDIR"

for cmd in oc kubectl python3; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found in PATH" >&2; exit 1; }
done

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

# Map instance IP (e.g. 10.0.59.244:6443) -> node name, for oc adm node-logs
declare -A ip_to_node
refresh_node_map() {
  while IFS=' ' read -r ip name; do
    [ -z "$ip" ] && continue
    ip_to_node[$ip]=$name
  done < <(oc get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)
}
refresh_node_map

capture_node() {
  local node="$1" ts="$2" peak="$3"
  local prefix="${OUTDIR}/${node}_${ts}"

  echo "  Capturing audit log for $node (peak delta=$peak)..."

  # Find the currently-open audit log (the last file in the listing is 'audit.log',
  # the live symlink/file being written to right now).
  local current_log="audit.log"

  oc adm node-logs "$node" --path="kube-apiserver/${current_log}" 2>/dev/null \
    > "${prefix}_audit.jsonl"

  local lines
  lines=$(wc -l < "${prefix}_audit.jsonl" 2>/dev/null || echo 0)
  if [ "$lines" -eq 0 ]; then
    echo "    WARNING: captured 0 lines, node-logs may have failed" >&2
    rm -f "${prefix}_audit.jsonl"
    return
  fi
  echo "    Captured ${lines} audit events -> ${prefix}_audit.jsonl"

  # Quick burst analysis: last 60s of the captured log vs. the rest as baseline.
  python3 - "${prefix}_audit.jsonl" "${prefix}_analysis.txt" "${prefix}_topnodes.txt" <<'PYEOF'
import json, sys, re
from collections import Counter

inpath, outpath, topnodes_path = sys.argv[1], sys.argv[2], sys.argv[3]

events = []
with open(inpath) as f:
    for line in f:
        try:
            ev = json.loads(line)
        except Exception:
            continue
        ts = ev.get("requestReceivedTimestamp", "")
        if ts:
            events.append((ts, ev))

if not events:
    sys.exit(0)

events.sort(key=lambda x: x[0])
last_ts = events[-1][0]
last_minute_prefix = last_ts[:18]  # ~10s bucket string prefix, matches interactive analysis

per_bucket = Counter()
for ts, ev in events:
    per_bucket[ts[:18]] += 1

# Find the single busiest 10s bucket in the whole capture.
busiest_bucket, busiest_count = max(per_bucket.items(), key=lambda kv: kv[1])

verbs, uris, users, codes = Counter(), Counter(), Counter(), Counter()
for ts, ev in events:
    if ts[:18] == busiest_bucket:
        verbs[ev.get("verb", "")] += 1
        uris[ev.get("requestURI", "").split("?")[0].rsplit("/", 1)[0]] += 1
        users[ev.get("user", {}).get("username", "")] += 1
        codes[ev.get("responseStatus", {}).get("code")] += 1

with open(outpath, "w") as out:
    out.write(f"Capture spans {events[0][0]} .. {events[-1][0]} ({len(events)} events)\n")
    out.write(f"Busiest 10s bucket: {busiest_bucket} with {busiest_count} events\n\n")
    out.write("Verbs in busiest bucket:\n")
    for v, c in verbs.most_common(10):
        out.write(f"  {c:6d}  {v}\n")
    out.write("\nResponse codes in busiest bucket:\n")
    for c, n in codes.most_common(10):
        out.write(f"  {n:6d}  {c}\n")
    out.write("\nTop URI prefixes in busiest bucket:\n")
    for u, c in uris.most_common(15):
        out.write(f"  {c:6d}  {u}\n")
    out.write("\nTop users in busiest bucket:\n")
    for u, c in users.most_common(10):
        out.write(f"  {c:6d}  {u}\n")

# Extract the hostnames of the top-contributing kubelets so the caller can
# pull kubelet journal logs from the actual source nodes of the reconnect
# storm, not just the control-plane node that absorbed it.
node_re = re.compile(r"^system:node:(.+)$")
top_kubelets = []
for u, _ in users.most_common(20):
    m = node_re.match(u)
    if m:
        top_kubelets.append(m.group(1))
    if len(top_kubelets) >= 5:
        break
with open(topnodes_path, "w") as out:
    out.write("\n".join(top_kubelets))
PYEOF

  if [ -f "${prefix}_analysis.txt" ]; then
    echo "    Analysis -> ${prefix}_analysis.txt"
    echo "    --- summary ---"
    sed 's/^/    /' "${prefix}_analysis.txt" | head -20
  fi

  # Pull kubelet journal logs from the actual source nodes driving the storm
  # (identified from the audit log itself), and the apiserver pod's own
  # container log — all captured now, before rotation/restart can lose them.
  if [ -f "${prefix}_topnodes.txt" ]; then
    while IFS= read -r knode; do
      [ -z "$knode" ] && continue
      echo "    Capturing kubelet journal from $knode..."
      oc adm node-logs "$knode" -u kubelet --since=-20m 2>/dev/null \
        > "${prefix}_kubelet_${knode}.log"
      klines=$(wc -l < "${prefix}_kubelet_${knode}.log" 2>/dev/null || echo 0)
      if [ "$klines" -eq 0 ]; then
        rm -f "${prefix}_kubelet_${knode}.log"
      else
        echo "      -> ${klines} lines -> ${prefix}_kubelet_${knode}.log"
      fi
    done < "${prefix}_topnodes.txt"
  fi

  local apod
  apod=$(oc get pod -n openshift-kube-apiserver -l apiserver=true \
    --field-selector "spec.nodeName=${node}" -o name 2>/dev/null | head -1)
  if [ -n "$apod" ]; then
    echo "    Capturing apiserver pod log ($apod)..."
    oc logs -n openshift-kube-apiserver "$apod" -c kube-apiserver --tail=20000 2>/dev/null \
      > "${prefix}_apiserver_pod.log"
    plines=$(wc -l < "${prefix}_apiserver_pod.log" 2>/dev/null || echo 0)
    [ "$plines" -eq 0 ] && rm -f "${prefix}_apiserver_pod.log" || echo "      -> ${plines} lines -> ${prefix}_apiserver_pod.log"
  fi
}

echo "=== Spike monitor started ==="
echo "  Threshold:  +${THRESHOLD} threads above rolling min (edge-triggered)"
echo "  Interval:   ${INTERVAL}s"
echo "  Output dir: ${OUTDIR}"
echo ""

declare -A min_threads
declare -A armed  # per-IP: "1" once we've captured this elevation, cleared when it drops back down

while true; do
  now=$SECONDS
  th=$(get_threads)
  if [ -z "$th" ]; then
    printf "%s  (no data from prometheus, retrying)\n" "$(date '+%Y-%m-%dT%H:%M:%S')"
    sleep "$INTERVAL"
    continue
  fi

  line_out=""
  spikes_this_round=""

  while IFS=' ' read -r ip v; do
    [ -z "$ip" ] && continue
    v=${v%.*}
    cur=${v:-0}
    min=${min_threads[$ip]:-$cur}
    [ "$cur" -lt "$min" ] && min=$cur
    min_threads[$ip]=$min
    delta=$(( cur - min ))
    line_out="${line_out}${ip}=${cur}(Δ${delta}) "

    # Thread counts never decay while a process runs (Go's thread trimmer is
    # too conservative to matter here) — a node that steps up and stays up
    # would otherwise re-trigger forever on a time-based cooldown alone.
    # Edge-trigger instead: capture once when we cross the threshold, then
    # stay "armed" (silent) until the delta drops back near zero, which only
    # happens after that apiserver instance restarts and min_threads resets.
    rearm_at=$(( THRESHOLD / 4 ))
    if [ "$delta" -ge "$THRESHOLD" ] && [ "${armed[$ip]:-0}" -eq 0 ]; then
      spikes_this_round="${spikes_this_round}${ip}:${delta} "
      armed[$ip]=1
    elif [ "$delta" -lt "$rearm_at" ] && [ "${armed[$ip]:-0}" -eq 1 ]; then
      armed[$ip]=0
    fi
  done <<< "$th"

  printf "%s  %s\n" "$(date '+%Y-%m-%dT%H:%M:%S')" "$line_out"

  if [ -n "$spikes_this_round" ]; then
    ts=$(date -u '+%Y%m%dT%H%M%SZ')
    for entry in $spikes_this_round; do
      ip="${entry%%:*}"
      delta="${entry##*:}"
      node="${ip_to_node[$ip]:-}"
      if [ -z "$node" ]; then
        refresh_node_map
        node="${ip_to_node[$ip]:-}"
      fi
      if [ -z "$node" ]; then
        echo "SPIKE  ${ip} delta=${delta}  (could not resolve node name, skipping capture)"
        continue
      fi
      echo "SPIKE  ${ip} (${node}) delta=${delta}  -- capturing audit log"
      capture_node "$node" "$ts" "$delta"
    done
  fi

  sleep "$INTERVAL"
done
