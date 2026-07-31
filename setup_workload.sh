#!/usr/bin/env bash
# setup_workload.sh — Deploy the kubelet watch workload across N namespaces.
#
# Creates namespaces, bumps maxPods via KubeletConfig (waits for MCP rollout),
# generates secrets/CMs/pods, and applies them in parallel.
#
# Each pod mounts:
#   - UNIQUE_SECRETS unique secrets (per-pod, UNIQUE_KV short key/value pairs each)
#   - UNIQUE_CMS unique configmaps (per-pod, UNIQUE_KV short key/value pairs each)
#   - one COMMON secret, shared by every pod in the namespace
#     (COMMON_SECRET_FILES files x COMMON_SECRET_FILE_SIZE bytes of random data)
#   - COMMON_CMS COMMON configmaps, shared by every pod in the namespace
#     (1 file x COMMON_CM_FILE_SIZE bytes of random data each)
#
# Each pod's spec is also padded to ~8KB (to match a representative
# production pod spec size) via LABELS random labels, ANNOTATIONS random
# annotations (keys/values TOKEN_LEN chars — ~50% of the 63-char Kubernetes
# label limit), and ENV_VARS large environment variables of ENV_VAR_SIZE
# bytes each.
#
# Usage:
#   ./setup_workload.sh [OPTIONS]
#
# Options:
#   -n NAMESPACES   Number of namespaces (default: 10)
#   -p PODS         Pods per namespace (default: 240)
#   -q UNIQUE_SECRETS Unique secrets per pod (default: 2)
#   -w UNIQUE_CMS   Unique configmaps per pod (default: 2)
#   -u UNIQUE_KV    Short key/value pairs in each unique secret/configmap (default: 10)
#   -v UNIQUE_KV_LEN Length in chars of each unique secret/configmap value (default: 24)
#   -r UNIQUE_LARGE_SECRETS Unique large (single-file) secrets per pod (default: 0)
#   -i UNIQUE_LARGE_SECRET_SIZE Size in bytes of each unique large secret (default: 131072 = 128KiB)
#   -o UNIQUE_LARGE_CMS Unique large (single-file) configmaps per pod (default: 0)
#   -j UNIQUE_LARGE_CM_SIZE Size in bytes of each unique large configmap (default: 131072 = 128KiB)
#   -C UNIQUE_LARGE_CMS2 A second, independently-sized group of unique large
#                   configmaps per pod (default: 0) — lets you mix two
#                   different large-configmap sizes on the same pod
#   -J UNIQUE_LARGE_CM2_SIZE Size in bytes of each group-2 unique large
#                   configmap (default: 8192 = 8KiB)
#   -s SECRET_FILES Files in the shared common secret (default: 7)
#   -f SECRET_SIZE  Size in bytes of each common secret file (default: 10240 = 10KiB)
#   -c CMS          Number of shared common configmaps (default: 2)
#   -z CM_SIZE      Size in bytes of each common configmap's file (default: 262144 = 256KiB)
#   -l LABELS       Random labels per pod, beyond app=mount-spam (default: 10)
#   -a ANNOTATIONS  Random annotations per pod (default: 10)
#   -t TOKEN_LEN    Length of each label/annotation key and value (default: 31)
#   -e ENV_VARS     Large environment variables per pod (default: 6)
#   -y ENV_VAR_SIZE Size in bytes of each large env var's value (default: 900)
#   -m MAXPODS      kubelet maxPods limit (default: 550)
#   -b BATCH_SIZE   Pods per namespace applied per wave (default: 2)
#   -x BATCH_WAIT   Seconds between in-flight-count polls within a wave (default: 5)
#   -g MAX_WAVE_WAIT Max seconds to wait per wave for in-flight pods to drop
#                   to <=3 before the script aborts with an error (default: 300).
#                   Deliberately does NOT proceed to the next wave if this
#                   expires — piling more pods onto an already-stuck backlog
#                   is what turns a slow node into a full thundering-herd
#                   meltdown (observed: crio/runc sync-socket failures under
#                   sustained concurrent container-create load that never
#                   drain once enough pods back up).
#   -k KUBECONFIG   Path to kubeconfig (default: $KUBECONFIG)
#   -d              Dry-run: generate manifests but don't apply
#   -h              Show this help
#
# Example (default: matches a customer report of ~73KB secrets, 256KB+
# configmaps, and ~8KB pod specs):
#   ./setup_workload.sh -n 10 -p 240
#
# Target density: keep maxPods at or below the node's actual OVN-Kubernetes
# per-node subnet capacity (commonly ~500-520 usable IPs on a default /23
# hostSubnet) rather than the kubelet default of 750 — exceeding it causes
# ContainerCreating hangs from subnet exhaustion, which can also deadlock
# unrelated platform pods (PDB-protected singletons failing to reschedule).
#
# Pods are created in waves of BATCH_SIZE-per-namespace rather than all at
# once. Creating hundreds of pods simultaneously means every node tries to
# start hundreds of containers in the same instant, which can overwhelm
# crio/runc — concurrent container creation under heavy CPU contention
# causes sync-socket errors ("broken pipe" / "connection reset by peer")
# that keep every pod retrying forever in a self-sustaining ~100% CPU
# thundering herd that never drains on its own. A fixed sleep between waves
# is not enough on its own: pods already stuck retrying from a prior wave
# keep contributing background load, so the error count can still climb
# wave over wave even with small batches. Instead, after each wave the
# script polls (every BATCH_WAIT seconds, up to MAX_WAVE_WAIT) until the
# number of pods still ContainerCreating/CreateContainerError drops back
# down before starting the next wave, so failing pods get a chance to
# actually clear instead of stacking on top of fresh creates.
#
# Generated manifests are written to ./manifests/ for inspection.

set -euo pipefail

NAMESPACES=10
PODS=240
UNIQUE_SECRETS=2
UNIQUE_CMS=2
UNIQUE_KV=10
UNIQUE_KV_LEN=24
UNIQUE_LARGE_SECRETS=0
UNIQUE_LARGE_SECRET_SIZE=131072
UNIQUE_LARGE_CMS=0
UNIQUE_LARGE_CM_SIZE=131072
UNIQUE_LARGE_CMS2=0
UNIQUE_LARGE_CM2_SIZE=8192
SECRET_FILES=7
SECRET_SIZE=10240
CMS=2
CM_SIZE=262144
LABELS=10
ANNOTATIONS=10
TOKEN_LEN=31
ENV_VARS=6
ENV_VAR_SIZE=900
MAXPODS=550
BATCH_SIZE=2
BATCH_WAIT=5
MAX_WAVE_WAIT=300
DRYRUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
GENERATOR="${SCRIPT_DIR}/gen_mount_workload.py"
BATCHER="${SCRIPT_DIR}/batch_pods.py"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while getopts "n:p:q:w:u:v:r:i:o:j:C:J:s:f:c:z:l:a:t:e:y:m:b:x:g:k:dh" opt; do
  case $opt in
    n) NAMESPACES=$OPTARG ;;
    p) PODS=$OPTARG ;;
    q) UNIQUE_SECRETS=$OPTARG ;;
    w) UNIQUE_CMS=$OPTARG ;;
    u) UNIQUE_KV=$OPTARG ;;
    v) UNIQUE_KV_LEN=$OPTARG ;;
    r) UNIQUE_LARGE_SECRETS=$OPTARG ;;
    i) UNIQUE_LARGE_SECRET_SIZE=$OPTARG ;;
    o) UNIQUE_LARGE_CMS=$OPTARG ;;
    j) UNIQUE_LARGE_CM_SIZE=$OPTARG ;;
    C) UNIQUE_LARGE_CMS2=$OPTARG ;;
    J) UNIQUE_LARGE_CM2_SIZE=$OPTARG ;;
    s) SECRET_FILES=$OPTARG ;;
    f) SECRET_SIZE=$OPTARG ;;
    c) CMS=$OPTARG ;;
    z) CM_SIZE=$OPTARG ;;
    l) LABELS=$OPTARG ;;
    a) ANNOTATIONS=$OPTARG ;;
    t) TOKEN_LEN=$OPTARG ;;
    e) ENV_VARS=$OPTARG ;;
    y) ENV_VAR_SIZE=$OPTARG ;;
    m) MAXPODS=$OPTARG ;;
    b) BATCH_SIZE=$OPTARG ;;
    x) BATCH_WAIT=$OPTARG ;;
    g) MAX_WAVE_WAIT=$OPTARG ;;
    k) export KUBECONFIG=$OPTARG ;;
    d) DRYRUN=true ;;
    h) usage ;;
    *) echo "Unknown option: $opt" >&2; exit 1 ;;
  esac
done

TOTAL_PODS=$((NAMESPACES * PODS))
COMMON_SECRET_BYTES=$((SECRET_FILES * SECRET_SIZE))
COMMON_CM_BYTES=$((CMS * CM_SIZE))

echo "=== Workload configuration ==="
echo "  Namespaces:       $NAMESPACES  (mount-spam-0 .. mount-spam-$((NAMESPACES-1)))"
echo "  Pods/namespace:   $PODS"
echo "  Unique secrets/pod: $UNIQUE_SECRETS ($UNIQUE_KV short key/value pairs each, ${UNIQUE_KV_LEN} chars)"
echo "  Unique configmaps/pod: $UNIQUE_CMS ($UNIQUE_KV short key/value pairs each, ${UNIQUE_KV_LEN} chars)"
echo "  Unique large secrets/pod: $UNIQUE_LARGE_SECRETS (${UNIQUE_LARGE_SECRET_SIZE}B each)"
echo "  Unique large configmaps/pod: $UNIQUE_LARGE_CMS (${UNIQUE_LARGE_CM_SIZE}B each)"
echo "  Unique large configmaps/pod (group 2): $UNIQUE_LARGE_CMS2 (${UNIQUE_LARGE_CM2_SIZE}B each)"
echo "  Common secret:    1 ($SECRET_FILES files x ${SECRET_SIZE}B = ${COMMON_SECRET_BYTES}B), shared per namespace"
echo "  Common configmaps: $CMS (1 file x ${CM_SIZE}B each = ${COMMON_CM_BYTES}B total), shared per namespace"
echo "  Pod metadata:     $LABELS labels + $ANNOTATIONS annotations (${TOKEN_LEN}-char keys/values) + $ENV_VARS env vars (${ENV_VAR_SIZE}B each) => ~8KB pod spec"
echo "  maxPods:          $MAXPODS"
echo "  Total pods:       $TOTAL_PODS"
echo "  Pod rollout:      batches of $BATCH_SIZE/namespace (up to $((BATCH_SIZE * NAMESPACES)) concurrent), adaptive wait between waves (poll ${BATCH_WAIT}s, cap ${MAX_WAVE_WAIT}s)"
echo ""

mkdir -p "$MANIFEST_DIR"

# --- Step 1: KubeletConfig ---
echo "=== Step 1: Apply KubeletConfig (maxPods=$MAXPODS) ==="
cat > "$MANIFEST_DIR/kubeletconfig-maxpods.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-max-pods
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    maxPods: ${MAXPODS}
EOF

if ! $DRYRUN; then
  kubectl apply -f "$MANIFEST_DIR/kubeletconfig-maxpods.yaml"

  echo "  Waiting for MachineConfigPool worker rollout..."
  deadline=$((SECONDS + 3600))
  while [ $SECONDS -lt $deadline ]; do
    updated=$(kubectl get mcp worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo 0)
    total=$(kubectl get mcp worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo 0)
    updating=$(kubectl get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null)
    printf "    updated=%s/%s  updating=%s\n" "$updated" "$total" "$updating"
    if [ "$updating" = "False" ] && [ "${updated:-0}" -eq "${total:-1}" ] && [ "${total:-0}" -gt 0 ]; then
      echo "  MCP rollout complete."
      break
    fi
    sleep 30
  done
else
  echo "  [dry-run] Would apply kubeletconfig and wait for MCP rollout"
fi

# --- Step 2: Namespaces ---
echo ""
echo "=== Step 2: Create namespaces ==="
for i in $(seq 0 $((NAMESPACES-1))); do
  ns="mount-spam-$i"
  if ! $DRYRUN; then
    kubectl create namespace "$ns" 2>/dev/null && echo "  created $ns" || echo "  $ns already exists"
  else
    echo "  [dry-run] Would create namespace $ns"
  fi
done

# --- Step 3: Generate manifests ---
echo ""
echo "=== Step 3: Generate manifests ==="
for i in $(seq 0 $((NAMESPACES-1))); do
  ns="mount-spam-$i"
  python3 "$GENERATOR" --pods "$PODS" --unique-secrets "$UNIQUE_SECRETS" --unique-cms "$UNIQUE_CMS" \
    --unique-kv "$UNIQUE_KV" --unique-kv-len "$UNIQUE_KV_LEN" \
    --unique-large-secrets "$UNIQUE_LARGE_SECRETS" --unique-large-secret-size "$UNIQUE_LARGE_SECRET_SIZE" \
    --unique-large-cms "$UNIQUE_LARGE_CMS" --unique-large-cm-size "$UNIQUE_LARGE_CM_SIZE" \
    --unique-large-cms2 "$UNIQUE_LARGE_CMS2" --unique-large-cm2-size "$UNIQUE_LARGE_CM2_SIZE" \
    --common-secret-files "$SECRET_FILES" --common-secret-file-size "$SECRET_SIZE" \
    --common-cms "$CMS" --common-cm-file-size "$CM_SIZE" \
    --namespace "$ns" --resources-only 2>/dev/null \
    > "$MANIFEST_DIR/ns${i}_resources.yaml" &
  python3 "$GENERATOR" --pods "$PODS" --unique-secrets "$UNIQUE_SECRETS" --unique-cms "$UNIQUE_CMS" \
    --unique-kv "$UNIQUE_KV" --unique-kv-len "$UNIQUE_KV_LEN" \
    --unique-large-secrets "$UNIQUE_LARGE_SECRETS" --unique-large-secret-size "$UNIQUE_LARGE_SECRET_SIZE" \
    --unique-large-cms "$UNIQUE_LARGE_CMS" --unique-large-cm-size "$UNIQUE_LARGE_CM_SIZE" \
    --unique-large-cms2 "$UNIQUE_LARGE_CMS2" --unique-large-cm2-size "$UNIQUE_LARGE_CM2_SIZE" \
    --common-secret-files "$SECRET_FILES" --common-secret-file-size "$SECRET_SIZE" \
    --common-cms "$CMS" --common-cm-file-size "$CM_SIZE" \
    --pod-labels "$LABELS" --pod-annotations "$ANNOTATIONS" --label-token-len "$TOKEN_LEN" \
    --env-vars "$ENV_VARS" --env-var-size "$ENV_VAR_SIZE" \
    --namespace "$ns" --pods-only 2>/dev/null \
    > "$MANIFEST_DIR/ns${i}_pods.yaml" &
done
wait
echo "  Manifests written to $MANIFEST_DIR/"

# --- Step 4: Apply resources (parallel) ---
echo ""
echo "=== Step 4: Apply secrets and configmaps ==="
if ! $DRYRUN; then
  for i in $(seq 0 $((NAMESPACES-1))); do
    (kubectl create -f "$MANIFEST_DIR/ns${i}_resources.yaml" 2>/dev/null | \
      awk 'END{print "  ns'$i' resources: created="NR}') &
  done
  wait
  echo "  Resources applied."
else
  echo "  [dry-run] Would apply resources across $NAMESPACES namespaces"
fi

# --- Step 5: Apply pods (staggered waves, adaptive wait) ---
echo ""
echo "=== Step 5: Apply pods (batches of $BATCH_SIZE/namespace) ==="
if ! $DRYRUN; then
  NUM_BATCHES=$(( (PODS + BATCH_SIZE - 1) / BATCH_SIZE ))
  INFLIGHT_THRESHOLD=30
  echo "  $NUM_BATCHES waves, up to $((BATCH_SIZE * NAMESPACES)) pods created concurrently per wave"
  echo "  Between waves: poll every ${BATCH_WAIT}s (up to ${MAX_WAVE_WAIT}s) until in-flight pods <= $INFLIGHT_THRESHOLD"

  for i in $(seq 0 $((NAMESPACES-1))); do
    python3 "$BATCHER" "$MANIFEST_DIR/ns${i}_pods.yaml" "$BATCH_SIZE" "$MANIFEST_DIR" "$i" &
  done
  wait

  count_inflight() {
    local inflight=0 r
    for i in $(seq 0 $((NAMESPACES-1))); do
      r=$(kubectl get pods -n "mount-spam-$i" --no-headers 2>/dev/null | \
        grep -cE "ContainerCreating|CreateContainerError|Pending" || true)
      inflight=$((inflight + r))
    done
    echo "$inflight"
  }

  for b in $(seq 0 $((NUM_BATCHES-1))); do
    for i in $(seq 0 $((NAMESPACES-1))); do
      f="$MANIFEST_DIR/ns${i}_pods_batch${b}.yaml"
      [ -s "$f" ] && kubectl create -f "$f" >/dev/null 2>&1 &
    done
    wait

    if [ "$b" -lt "$((NUM_BATCHES-1))" ]; then
      wave_deadline=$((SECONDS + MAX_WAVE_WAIT))
      while [ $SECONDS -lt $wave_deadline ]; do
        inflight=$(count_inflight)
        [ "$inflight" -le "$INFLIGHT_THRESHOLD" ] && break
        sleep "$BATCH_WAIT"
      done
      if [ "$inflight" -gt "$INFLIGHT_THRESHOLD" ]; then
        err_running=0
        for i in $(seq 0 $((NAMESPACES-1))); do
          r=$(kubectl get pods -n "mount-spam-$i" --no-headers 2>/dev/null | grep -c Running || true)
          err_running=$((err_running + r))
        done
        echo ""
        echo "  ERROR: wave $((b+1))/$NUM_BATCHES: in-flight=$inflight still above threshold" \
          "($INFLIGHT_THRESHOLD) after ${MAX_WAVE_WAIT}s."
        echo "  Stopping instead of piling more pods onto a backlog that isn't clearing —" \
          "that compounding is what caused prior runs to melt down entirely."
        echo "  $err_running pods Running so far. Investigate node/crio state before retrying."
        exit 1
      fi
    fi

    total_running=0
    for i in $(seq 0 $((NAMESPACES-1))); do
      r=$(kubectl get pods -n "mount-spam-$i" --no-headers 2>/dev/null | grep -c Running || true)
      total_running=$((total_running + r))
    done
    printf "  wave %d/%d: %d Running, in-flight=%s\n" "$((b+1))" "$NUM_BATCHES" "$total_running" "${inflight:-?}"
  done
  echo "  Pods applied."
else
  echo "  [dry-run] Would apply pods across $NAMESPACES namespaces in batches of $BATCH_SIZE"
fi

# --- Step 6: Wait for pods ---
echo ""
echo "=== Step 6: Waiting for pods to reach Running state ==="
if ! $DRYRUN; then
  deadline=$((SECONDS + 600))
  while [ $SECONDS -lt $deadline ]; do
    running=0
    for i in $(seq 0 $((NAMESPACES-1))); do
      r=$(kubectl get pods -n "mount-spam-$i" --no-headers 2>/dev/null | grep -c Running || true)
      running=$((running + r))
    done
    printf "  Running: %d / %d\n" "$running" "$TOTAL_PODS"
    [ "$running" -ge "$((TOTAL_PODS * 9 / 10))" ] && echo "  Ready (≥90%%)." && break
    sleep 30
  done
fi

echo ""
echo "=== Setup complete ==="
echo "  Use run_rounds.sh to start rolling restart measurements."
