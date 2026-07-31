#!/usr/bin/env bash
# teardown_workload.sh — Remove all kubelet watch workload resources.
#
# Deletes pods, secrets, configmaps, and namespaces created by setup_workload.sh.
# Also optionally removes the KubeletConfig maxPods override.
#
# Usage:
#   ./teardown_workload.sh [OPTIONS]
#
# Options:
#   -n NAMESPACES   Number of namespaces to clean (default: 10)
#   -K              Also delete the KubeletConfig (restores default maxPods)
#   -k KUBECONFIG   Path to kubeconfig (default: $KUBECONFIG)
#   -h              Show this help

set -euo pipefail

NAMESPACES=10
DELETE_KUBELETCONFIG=false

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while getopts "n:Kk:h" opt; do
  case $opt in
    n) NAMESPACES=$OPTARG ;;
    K) DELETE_KUBELETCONFIG=true ;;
    k) export KUBECONFIG=$OPTARG ;;
    h) usage ;;
    *) echo "Unknown option: $opt" >&2; exit 1 ;;
  esac
done

echo "=== Teardown kubelet watch workload ==="

echo "Deleting pods and resources across $NAMESPACES namespaces..."
for i in $(seq 0 $((NAMESPACES-1))); do
  ns="mount-spam-$i"
  kubectl delete pods     -n "$ns" -l app=mount-spam --grace-period=0 2>/dev/null &
  kubectl delete secrets  -n "$ns" -l app=mount-spam 2>/dev/null &
  kubectl delete configmap -n "$ns" -l app=mount-spam 2>/dev/null &
done
wait
echo "  Resources deleted."

echo "Deleting namespaces..."
for i in $(seq 0 $((NAMESPACES-1))); do
  kubectl delete namespace "mount-spam-$i" --ignore-not-found 2>/dev/null &
done
wait
echo "  Namespaces deleted."

if $DELETE_KUBELETCONFIG; then
  echo "Removing KubeletConfig (maxPods override)..."
  kubectl delete kubeletconfig increase-max-pods --ignore-not-found
  echo "  Done. MachineConfigPool will roll back to default maxPods."
fi

# Clean up generated manifest files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${SCRIPT_DIR}/manifests" ]; then
  echo "Removing generated manifests..."
  rm -rf "${SCRIPT_DIR}/manifests"
fi

echo ""
echo "=== Teardown complete ==="
