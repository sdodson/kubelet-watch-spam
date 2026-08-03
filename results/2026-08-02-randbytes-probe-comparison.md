# RAND_bytes concurrency probe: stock vs. go-semaphore+DRBG-kernel

**Date:** 2026-08-02
**Cluster:** fips-mode-5c8hc
**Goal:** directly verify the go-semaphore build's core mechanism (capping concurrent
thread-creating operations during a crypto/DRBG-contention burst) rather than continuing to infer
it from noisy aggregate peak-thread-count statistics.

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

## Results

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

## Finding 1: no evidence of a hard concurrency cap

If go-semaphore's patch enforces a semaphore limiting concurrent RAND_bytes-triggered thread
creation, we'd expect **all** solution measurements to sit at or below some consistent ceiling,
regardless of load. Instead:

- Solution max concurrency (31, 21, 6) spans a similar range to stock (27, 38, 26), and the
  solution's highest single value (31, on ip-10-0-54-184) exceeds two of the three stock values.
- There is no visible ceiling — nothing suggests calls are being queued/serialized once some N is
  reached.

## Finding 2: RAND_bytes concurrency does not track OS thread spike magnitude

The clearest evidence from this session, all from the **same round** on the go-semaphore+DRBG
build:

- **ip-10-0-86-117 had the single largest thread spike measured in this entire investigation
  (2345 threads)** — yet its RAND_bytes concurrency was the **lowest of the three nodes (max=6)**.
- ip-10-0-54-184 had a much smaller thread spike (752) but higher RAND_bytes concurrency (31).

If crypto/DRBG contention during TLS handshakes were the primary driver of OS thread growth, the
node with the biggest thread spike should also show the most concurrent RAND_bytes activity. It
shows the opposite. This is a direct contradiction of the DRBG-contention-as-primary-cause
hypothesis, at least as the dominant mechanism — using the most direct instrument available
(actual concurrent crypto call counts, not an inferred proxy).

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

- **n=1 round per build.** Given the substantial round-to-round variance documented throughout
  this investigation (peak thread counts ranging 51-2795 across 38+ stock rounds), a single round
  per build is not sufficient to rule out noise as an explanation for the specific numbers above.
  However, Finding 2 (the concurrency/thread-count inversion) is an intra-round, cross-node
  comparison under identical conditions — not a between-build comparison — so it is not subject to
  the same round-to-round confound and stands as solid evidence on its own.
- The go-semaphore patch's actual implementation was never inspected directly in this
  investigation (no source diff reviewed) — this probe tests its *observable effect* on RAND_bytes
  concurrency specifically. It's possible the patch targets a different code path (e.g. general Go
  runtime thread creation, unrelated to RAND_bytes) that this probe wouldn't detect. That would be
  a reasonable next thing to check if source access becomes available.

## Bottom line toward the stated goal

This is the most direct evidence gathered in this investigation on the specific mechanism the
go-semaphore build is meant to address, and it does **not** support the hypothesis that capping
RAND_bytes/DRBG concurrency is what's needed to reduce the OS thread spikes. Combined with the
statistically-inconclusive aggregate A/B comparison (n=38 vs n=19, Welch t=-0.125) and the
pprof-confirmed watch-thundering-herd root cause, the weight of evidence at this point leans toward
**disproving** the specific crypto-contention causal story, while still leaving the broader
question — does anything about the combined kernel+build change help the customer-visible symptom
at all — statistically unresolved.
