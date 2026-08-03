#!/bin/bash
# rand_bytes_probe_looper.sh <initial_pid> <per_restart_capture_seconds> <total_deadline_seconds> <label>
# Continuously watches for kube-apiserver restarts and re-attaches the
# RAND_bytes concurrency probe fresh each time, so it can catch whichever
# restart round happens to produce a real thread-count spike.
LAST_PID=$1
CAPTURE_SECS=$2
DEADLINE_SECS=$3
LABEL=$4
OUT=/tmp/rand_bytes_probe_${LABEL}.log
START=$(date +%s)

echo "$(date '+%H:%M:%S') looper started, initial pid=$LAST_PID" > "$OUT"

while [ $(( $(date +%s) - START )) -lt "$DEADLINE_SECS" ]; do
  NEW_PID=""
  while [ $(( $(date +%s) - START )) -lt "$DEADLINE_SECS" ]; do
    CUR=$(pgrep -x kube-apiserver | head -1)
    if [ -n "$CUR" ] && [ "$CUR" != "$LAST_PID" ]; then
      NEW_PID=$CUR
      break
    fi
    sleep 2
  done
  [ -z "$NEW_PID" ] && break

  LAST_PID=$NEW_PID
  echo "$(date '+%H:%M:%S') === new kube-apiserver pid=$NEW_PID ===" >> "$OUT"

  LIBPATH="/proc/${NEW_PID}/root/usr/lib64/libcrypto.so.3"
  for i in $(seq 1 30); do
    [ -e "$LIBPATH" ] && break
    sleep 1
  done

  BT_SCRIPT="/tmp/rand_bytes_concurrency_${LABEL}_${NEW_PID}.bt"
  sed "s#__LIBPATH__#${LIBPATH}#g; s#__PID__#${NEW_PID}#g; s#__DURATION__#${CAPTURE_SECS}#g" \
    /tmp/rand_bytes_concurrency.bt.tmpl > "$BT_SCRIPT"

  echo "$(date '+%H:%M:%S') capturing for ${CAPTURE_SECS}s (pid=$NEW_PID)..." >> "$OUT"
  /tmp/bpftrace "$BT_SCRIPT" >> "$OUT" 2>&1
  echo "$(date '+%H:%M:%S') capture done (pid=$NEW_PID)" >> "$OUT"
done

echo "$(date '+%H:%M:%S') looper exiting (deadline reached)" >> "$OUT"
