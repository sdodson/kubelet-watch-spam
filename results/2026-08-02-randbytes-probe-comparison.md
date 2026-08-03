# RAND_bytes concurrency probe: stock vs. go-semaphore+DRBG-kernel

**Date:** 2026-08-02 (original run), 2026-08-03 (re-run against corrected build)
**Cluster:** fips-mode-5c8hc
**Goal:** directly verify the go-semaphore build's core mechanism (capping concurrent
thread-creating operations during a crypto/DRBG-contention burst) rather than continuing to infer
it from noisy aggregate peak-thread-count statistics.

**Update 2026-08-03:** the original go-semaphore image used to gather the 2026-08-02 numbers below
turned out to have a build-fidelity issue — it was missing `GOEXPERIMENT=strictfipsruntime`,
which stock's official build pipeline sets (confirmed via `go version -m` showing no
`X:strictfipsruntime` tag). After rebuilding via the actual `Dockerfile.rhel` `make WHAT=...`
process with that flag corrected (`getrandperf:go-semaphore-v2`), the probe was re-run identically
against the corrected build. Both result sets are kept below — the original is retained for
history/comparison, and the v2 section shows the corrected numbers. The stock side did not need
re-running since it was never affected by this build issue.

## Method

A bpftrace uprobe/uretprobe on `RAND_bytes` in the kube-apiserver container's own `libcrypto.so.3`
(resolved per-PID via `/proc/<pid>/root/...` to guarantee we trace the exact library loaded in that
process, not the host's copy), tracking concurrent in-flight calls (`@active`/`@max_active`) and a
duration histogram, attached directly to the **actual kube-apiserver child process** (not the
`watch-termination` wrapper it runs under — an early version of this probe mistakenly targeted the
wrapper PID and produced false "zero activity" results the whole session; fixed by using
`pgrep -x kube-apiserver` instead of matching the wrapper's command line).

A self-reattaching "looper" wrapper (systemd transient unit per node) watches for the
kube-apiserver child PID to change (i.e. a restart) and launches a fresh capture automatically, so
restarts triggered via `forceRedeploymentReason` are caught without manual re-attachment.

One restart round was captured for each build (stock, then go-semaphore+DRBG-kernel), on the same
doubled m6i.4xlarge control plane / 2,900-pod workload. Raw logs: `randbytes-probe/stock_*.log`,
`randbytes-probe/solution_*.log`.

## Probe scripts

Both preserved verbatim in `randbytes-probe/`.

**`rand_bytes_concurrency.bt.tmpl`** — the bpftrace probe itself. `__LIBPATH__`, `__PID__`, and
`__DURATION__` are substituted per-invocation (see looper below) since bpftrace probe specifiers
must be compile-time literals, not runtime variables.

```bpftrace
#!/usr/bin/env bpftrace
// rand_bytes_concurrency.bt (templated) — track concurrent RAND_bytes calls
// and their duration for a specific PID/library, to directly verify whether
// a build/kernel combination caps concurrency (go-semaphore) or exhibits
// DRBG lock contention (long calls).

BEGIN
{
    printf("Tracing RAND_bytes for PID __PID__ for __DURATION__ seconds...\n");
    @start = nsecs;
    @active = 0;
    @max_active = 0;
}

uprobe:__LIBPATH__:RAND_bytes
/pid == __PID__/
{
    @active++;
    if (@active > @max_active) {
        @max_active = @active;
    }
    @entry[tid] = nsecs;
}

uretprobe:__LIBPATH__:RAND_bytes
/pid == __PID__ && @active > 0/
{
    @active--;
    if (@entry[tid]) {
        @duration_ns = hist(nsecs - @entry[tid]);
        delete(@entry[tid]);
    }
}

interval:s:1
{
    printf("%d  active=%lld  max_active=%lld\n", (nsecs - @start) / 1000000000, @active, @max_active);
    if ((nsecs - @start) / 1000000000 >= __DURATION__) {
        exit();
    }
}

END
{
    printf("\n=== Final max concurrent RAND_bytes calls: %lld ===\n", @max_active);
    printf("\n=== RAND_bytes call duration histogram (ns) ===\n");
    print(@duration_ns);
    clear(@active);
    clear(@max_active);
    clear(@entry);
    clear(@duration_ns);
    clear(@start);
}
```

**`rand_bytes_probe_looper.sh`** — the self-reattaching wrapper run on each master via
`systemd-run` (so it survives the `oc debug node` session ending). Watches for the kube-apiserver
child PID to change (a restart), resolves that PID's own `libcrypto.so.3` via `/proc/<pid>/root/`
so the uprobe targets the exact library loaded in that process (not the host's copy), substitutes
the template placeholders, and runs bpftrace against it for `CAPTURE_SECS`. Loops until
`DEADLINE_SECS` elapses, so multiple restart rounds triggered via `forceRedeploymentReason` are
each caught automatically without manual re-attachment.

```bash
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
```

Launched per node as, e.g.:
```bash
childpid=$(pgrep -x kube-apiserver | head -1)
systemd-run --unit=rand-bytes-looper --description='RAND_bytes concurrency probe' \
  /usr/bin/bash /tmp/rand_bytes_probe_looper.sh "$childpid" 400 3000 <label>
```

## Results (original — build-fidelity-flawed go-semaphore image, 2026-08-02)

| Node | Build | Max concurrent RAND_bytes | Peak go_threads (same round) |
|---|---|---:|---:|
| ip-10-0-54-184 | stock | 27 | — (not captured precisely) |
| ip-10-0-8-45 | stock | 38 | — (not captured precisely) |
| ip-10-0-86-117 | stock | 26 | — (not captured precisely) |
| ip-10-0-54-184 | go-semaphore+DRBG | 31 | 752 |
| ip-10-0-8-45 | go-semaphore+DRBG | 21 | 149 |
| ip-10-0-86-117 | go-semaphore+DRBG | 6 | **2345** |

Call duration histograms (both builds): overwhelmingly 8-16μs per call (normal), with a long tail.
Stock's worst outlier calls reached ~1-4ms. The solution's worst outlier (on ip-10-0-54-184) reached
**4-16ms** — a longer tail than anything seen under stock, in this one-round sample.

## Results (corrected go-semaphore-v2 image, 2026-08-03)

Same method, same workload, one fresh restart round captured against
`quay.io/sdodsonrht/getrandperf:go-semaphore-v2` (build-fidelity issue fixed, confirmed via
`go version -m` showing `X:strictfipsruntime` matching stock). Raw logs:
`randbytes-probe/solutionv2_*.log`.

| Node | Build | Max concurrent RAND_bytes | Peak go_threads (same round) |
|---|---|---:|---:|
| ip-10-0-54-184 | go-semaphore-v2+DRBG | **41** | 338 |
| ip-10-0-8-45 | go-semaphore-v2+DRBG | 23 | **1511** |
| ip-10-0-86-117 | go-semaphore-v2+DRBG | 6 | 677 |

Duration histograms: same shape as before, overwhelmingly 8-16μs, long tail out to 2-8ms on two of
the three nodes (ip-10-0-54-184: up to 2-4ms; ip-10-0-8-45: up to 4-8ms) — comparable to, not
better than, both earlier datasets.

## Finding 1: no evidence of a hard concurrency cap

If go-semaphore's patch enforces a semaphore limiting concurrent RAND_bytes-triggered thread
creation, we'd expect **all** solution measurements to sit at or below some consistent ceiling,
regardless of load. Instead, across *both* the original and corrected builds:

- Original solution max concurrency (31, 21, 6) spans a similar range to stock (27, 38, 26), and
  the solution's highest single value (31) exceeds two of the three stock values.
- Corrected v2 solution max concurrency (**41**, 23, 6) is, if anything, higher still — 41 exceeds
  every single stock value observed (27, 38, 26).
- There is no visible ceiling in either build — nothing suggests calls are being queued/serialized
  once some N is reached, and fixing the build-fidelity issue did not introduce one.

## Finding 2: RAND_bytes concurrency does not track OS thread spike magnitude

This pattern now holds independently across **two separate rounds** (original build 2026-08-02,
corrected build 2026-08-03):

- **2026-08-02:** ip-10-0-86-117 had the largest thread spike (2345) but the *lowest* RAND_bytes
  concurrency (max=6); ip-10-0-54-184 had a far smaller spike (752) but the highest concurrency (31).
- **2026-08-03 (corrected build):** ip-10-0-8-45 had the largest thread spike (1511) but only
  moderate RAND_bytes concurrency (23); ip-10-0-54-184 had the *smallest* spike (338) but the
  *highest* concurrency (41) — the same inversion, on different nodes, on the corrected build.

If crypto/DRBG contention during TLS handshakes were the primary driver of OS thread growth, the
node with the biggest thread spike should consistently show the most concurrent RAND_bytes
activity. It doesn't, on either build. Seeing the same inversion independently on both the flawed
and corrected images rules out "build fidelity" as an explanation for this specific finding — it's
a robust result, not an artifact of the build issue.

## Interpretation

Combined with the earlier Go pprof thread-dump analysis (which found the goroutine explosion is
95% watch-serving infrastructure, and thread creation is scheduler-internal/unattributed rather
than tied to any single code path), this session's evidence base now points toward: **the OS
thread growth is driven by the sheer volume and scheduling dynamics of the watch reconnect storm
itself** (tens of thousands of goroutines becoming runnable/blocked in quick succession, forcing
the Go scheduler to spin up replacement M's), rather than specifically by DRBG/RAND_bytes lock
contention during TLS handshakes. The crypto layer is active during these events (real, nonzero,
sometimes tens of concurrent calls) but does not scale with — and in the most extreme observed
case, is inversely related to — the thread-count spike magnitude.

## Caveats

- **n=1 round per build per image.** Given the substantial round-to-round variance documented
  throughout this investigation (peak thread counts ranging 51-2795 across 38+ stock rounds), a
  single round per build is not sufficient on its own to rule out noise as an explanation for any
  one specific number. However, Finding 2 (the concurrency/thread-count inversion) is an
  intra-round, cross-node comparison under identical conditions — not a between-build comparison —
  so it is not subject to the same round-to-round confound, and it has now reproduced independently
  on two separate rounds (original and corrected builds), which is stronger evidence than either
  round alone.
- The go-semaphore patch's actual source diff was never obtained in this investigation — this
  probe tests its *observable effect* on RAND_bytes concurrency specifically. Symbol-level binary
  analysis (see conversation) found no semaphore-related construct and byte-identical
  thread-creation runtime functions between stock and go-semaphore, which is consistent with (but
  not absolute proof of) the patch simply not doing what its name implies for this code path.

## Bottom line toward the stated goal

This is the most direct evidence gathered in this investigation on the specific mechanism the
go-semaphore build is meant to address, and it does **not** support the hypothesis that capping
RAND_bytes/DRBG concurrency is what's needed to reduce the OS thread spikes — on either the
original or the build-fidelity-corrected image. Combined with the aggregate A/B comparison (which,
after the same build correction, now shows the corrected build trending *worse* than stock on both
mean and median — see `2026-08-03-go-semaphore-v2-drbg-kernel-20rounds.md`) and the pprof-confirmed
watch-thundering-herd root cause, the weight of evidence now leans toward **disproving** both the
specific crypto-contention causal story and the go-semaphore+DRBG-kernel combination as a fix.
