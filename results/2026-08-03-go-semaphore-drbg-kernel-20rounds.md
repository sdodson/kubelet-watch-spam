# go-semaphore (real semaphore) + per-CPU-DRBG kernel — 40 rounds (2 batches)

**Date:** 2026-08-03 (batch 1), 2026-08-04 (batch 2)
**Cluster:** fips-mode-5c8hc

A second 20-round batch was added on 2026-08-04 (kernel re-applied fresh via
`rpm-ostree override replace` + reboot on all 3 masters, same `go-semaphore` image, same
workload/churn config already active from the stock-kernel testing) to bring this configuration to
n=38, matching the stock baseline and the go-semaphore + stock-kernel dataset.

**This is the first test of the actual, functioning semaphore patch.** All prior go-semaphore
results in this investigation (v1, v2 — both removed from this repo) were built without the
`golang-src` RPM matching the patched toolchain, so `go build` silently compiled against the
*stock* standard library source. The semaphore code
(`vendor/github.com/golang-fips/openssl/v2/sem.go`) was never part of those binaries — confirmed
absent via `go tool nm` on an unstripped build. This test uses `go-semaphore`, built with
`golang`, `golang-bin`, **and `golang-src`** all at `1.24.13-10.testonly.el9_8`, confirmed via
`go tool nm` to contain `drbgSemEnabled`/`drbgSemInstance`/`(*drbgSem).Acquire`/`.Release`.

## The patch (for reference)

Exactly two files differ from stock, extracted and diffed directly from the RPM sources:
- `sem.go` (new): a `sync.Mutex`+`sync.Cond`-based semaphore, initialized in `init()` to
  `runtime.NumCPU()` (16 on these m6i.4xlarge nodes) unless overridden via `GOLANG_FIPS_DRBG_LIMIT`.
- `rand.go` (modified): `randReader.Read()` (backing `crypto/rand.Read()`) acquires the semaphore
  before calling `C.go_openssl_RAND_bytes`, releases after.

## Environment

- **Control plane:** 3x m6i.4xlarge (16 vCPU / 64 GiB), consistent with all prior datasets.
- **Kernel:** `5.14.0-730.el9.x86_64` (per-CPU-DRBG test kernel), all 3 masters.
- **kube-apiserver image:** `quay.io/sdodsonrht/getrandperf:go-semaphore`
  - Built via `containerfiles/Containerfile.go-semaphore` — official `make WHAT=...` process,
    `GOEXPERIMENT=strictfipsruntime` set explicitly, all three `golang*` RPMs at the matching
    `-10.testonly.el9_8` NVR.
- **`--profiling=true`** set explicitly via `unsupportedConfigOverrides.apiServerArguments` on the
  KubeAPIServer CR partway through this test's setup (persists across future revisions, unlike the
  raw manifest edits used earlier in this investigation).
- **Workload:** same 2,900-pod config as all other datasets, **plus namespace churn**
  (`churn_namespace.sh`, default settings — recreates `mount-spam-9` every 300s) enabled partway
  through this run (starting during round 12's cooldown). Rounds 1-11 ran without churn; rounds
  12-20 ran with it. See caveats below.
- **Harness:** `run_rounds.sh -r 20 -l go-semaphore-drbg-kernel`, standard settings.
- **Concurrent instrumentation:** a periodic `/debug/pprof/threadcreate` capture (every 15s) plus a
  triggered `/debug/pprof/goroutine` + `/debug/pprof/threadcreate` capture whenever any node's
  `go_threads` exceeded a threshold (200 initially, lowered to 120 partway through) via
  `oc get --raw`, both LB-routed (not targeted to a specific node). Raw output:
  `randbytes-probe/threadcreate_watch.txt`, `randbytes-probe/goroutine_watch.txt`.

## Raw per-round peak Go-thread counts

| Round | Peak threads | Note |
|-------|-------------:|---|
| 1 (discard) | 298 | |
| 2  | 300 | |
| 3  | 578 | |
| 4  | 152 | |
| 5  | 507 | |
| 6  | 334 | |
| 7  | 298 | |
| 8  | 157 | |
| 9  | 51 | |
| 10 | 84 | |
| 11 | 31 | |
| 12 | 102 | namespace churn enabled during this round's cooldown |
| 13 | 100 | churn active |
| 14 | 78 | churn active |
| 15 | 234 | churn active |
| 16 | 194 | churn active |
| 17 | 126 | churn active |
| 18 | 85 | churn active |
| 19 | 520 | churn active |
| 20 | 154 | churn active |

Full timestamped detail: `2026-08-03-go-semaphore-drbg-kernel-rounds-raw.log`.

### Batch 2 (2026-08-04, same config, kernel re-applied fresh)

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 50 |
| 2  | 78 |
| 3  | 181 |
| 4  | 54 |
| 5  | 79 |
| 6  | 13 |
| 7  | 63 |
| 8  | 68 |
| 9  | 400 |
| 10 | 123 |
| 11 | 123 |
| 12 | 150 |
| 13 | 270 |
| 14 | 386 |
| 15 | 39 |
| 16 | 57 |
| 17 | 49 |
| 18 | 195 |
| 19 | 204 |
| 20 | 373 |

Full timestamped detail: `2026-08-04-go-semaphore-drbg-kernel-batch2-rounds-raw.log`.

## Summary statistics

| Stat | Batch 1 (n=19) | Batch 2 (n=19) | Combined (n=38) |
|---|---:|---:|---:|
| mean | 215.0 | 152.9 | 183.9 |
| median | 154.0 | 123.0 | 138.0 |
| stdev | 166.3 | 123.2 | 147.7 |
| p90 | 509.6 | 375.6 | 390.2 |
| min | 31 | 13 | 13 |
| max | 578 | 400 | 578 |

## Comparison vs. combined stock baseline (n=38)

| Stat | Stock baseline (n=38) | go-semaphore + DRBG (n=38) | Reduction |
|---|---:|---:|---:|
| mean | 635.6 | 183.9 | **71.1%** |
| median | 535.0 | 138.0 | **74.2%** |
| p90 | 1174.2 | 390.2 | 66.8% |
| max | 2795 | 578 | 79.3% |
| stdev | 527.7 | 147.7 | (much less noisy) |

**Welch's two-sample t-test: t = 5.081, df ≈ 42.8 — highly statistically significant** (p < 0.0001),
and *stronger* than the batch-1-only comparison (t=4.488). This is a completely different result
from every prior comparison in this investigation involving the (build-flawed) earlier go-semaphore
images. The earlier power analysis established that ~20-40 rounds/arm could only reliably detect a
50-70%+ effect at this noise level — this result clears that bar decisively, and doubling the
sample size reinforced rather than weakened it.

### vs. go-semaphore + stock kernel (n=38 each)

| Stat | go-semaphore + stock kernel | go-semaphore + DRBG kernel |
|---|---:|---:|
| mean | 185.1 | 183.9 |
| median | 130.5 | 138.0 |

**Welch's t-test: t = 0.031 — essentially zero difference.** With both configurations at n=38, the
DRBG kernel and stock kernel are statistically indistinguishable from each other when
go-semaphore is deployed. This confirms (with much stronger power than the earlier n=19-vs-n=19
comparison, which already showed t=-0.324) that **the per-CPU-DRBG kernel contributes nothing
measurable** — the go-semaphore build alone fully accounts for the effect.

## RAND_bytes concurrency (audited, n=17 captures across the 3 nodes)

Values: `[7, 12, 17, 18, 19, 21, 21, 22, 24, 25, 27, 34, 36, 37, 37, 46, 60]`

| Stat | Value |
|---|---:|
| mean | 27.2 |
| median | 24.0 |
| stdev | 13.1 |
| min/max | 7 / 60 |
| samples exceeding NumCPU (16) | 15 / 17 |

The semaphore is not producing a hard ceiling at exactly 16 — most samples exceed it, one reaches
60. Most likely explanation (not directly verified): OpenSSL has other internal call sites into
`RAND_bytes` (e.g. key/IV generation inside cipher operations) that don't route through the
Go-level `randReader.Read()` wrapper this patch touches, so they aren't gated by the semaphore and
stack on top of the gated calls. Still, this is a *bounded, moderate* range compared to the
completely unbounded values seen with the broken (no-semaphore) builds under similar load.

One raw "Final max concurrent" printf value of 521 was discarded as a bpftrace END-block
read/aggregation artifact — it directly contradicted the immediately-preceding live interval
sample (22) with no elapsed time for a real burst to occur. The corrected live-sample max for that
capture (22) is used above. See `randbytes-probe/ip-10-0-54-184.log` for the raw evidence.

## Thread/goroutine dump findings (unchanged from the stock-build analysis)

Every triggered capture during this run (thresholds 200, then 120) shows the **same signature as
the stock-build analysis from earlier in this investigation**:

- **Threadcreate profile:** ~99% of OS-thread-creation events are unattributed (`0x0` stack) —
  this is a structural property of the profiler when thread creation is driven by the Go
  scheduler's internal `sysmon`/`retake` mechanism rather than identifiable application code, not
  something that varies with load or build.
- **Goroutine profile:** consistently 91-96% of all active goroutines are `cacheWatcher.process` +
  `WatchServer.HandleHTTP` (paired per active client watch connection). The largest single capture
  this run showed 133,249 total goroutines, 93.2% in these two groups — the largest goroutine count
  observed in this entire investigation, confirming the watch-reconnect-storm mechanism is fully
  intact and unaffected by the semaphore fix.

This means: **the semaphore's dramatic effect on peak thread counts is not explained by any visible
change to the dominant watch-serving goroutine population** — that population looks the same as
ever. The mechanism by which capping `RAND_bytes` concurrency produces a 66-71% reduction in peak
OS threads, despite the watch storm itself being untouched, is not yet understood from this data
alone and would be a good next thing to investigate (e.g., does capping crypto-related M-blocking
reduce the *rate* at which the scheduler needs to spin up replacement Ms, even though the ultimate
goroutine population is unchanged?).

## Caveats

- **Namespace churn was not active for the first 11 of 20 rounds of batch 1**, then was enabled
  partway through (per user request, to increase load). This makes the round-to-round conditions
  non-uniform within batch 1. Splitting batch 1: rounds 2-11 (no churn, n=10) mean = 249.2, median
  = 227.5; rounds 12-20 (churn, n=9) mean = 177.0, median = 126.0 — if anything, thread counts were
  *lower* under churn, suggesting churn did not inflate results. Batch 2 ran with churn active
  throughout (it was already running continuously by that point), so it doesn't share this
  confound, and its own stats (mean 152.9, median 123.0) are consistent with both halves of batch 1.
- **A worker node (`ip-10-0-95-33`) had a brief (~90s) kubelet restart/NotReady blip** around round
  11, self-resolved without intervention. Recurring ~17-minute kubelet restart cycles were observed
  in node events on this same worker before and after — appears to be a pre-existing, minor
  instability unrelated to this test (it's a worker, not one of the 3 masters being measured), but
  worth independent investigation if this cluster is used for further testing.
- **Stock baseline is not from a same-day run** — it's the n=38 combined dataset from 2026-08-01/02
  in `2026-08-01-stock-baseline-4xlcp-20rounds.md`, same environment/workload otherwise.
- The goroutine/threadcreate triggered captures were LB-routed (`oc get --raw`), not targeted to a
  specific node, so a given capture may not correspond to the exact node reporting the triggering
  thread count — though the qualitative pattern (watch-storm dominance) has been completely
  consistent across every capture regardless of which node answered.

## Bottom line

With all three configurations now at n=38, this investigation has landed on a clear, statistically
robust conclusion: **the go-semaphore build produces a large (~70-76%), highly significant
reduction in peak kube-apiserver OS thread counts versus stock, and the per-CPU-DRBG kernel adds
no additional measurable benefit on top of it** (t=0.031 between the two kernel variants — as
close to "no difference" as this kind of comparison gets). The open question that remains is
mechanistic, not statistical: the goroutine population driving these spikes (the watch-reconnect
storm) looks identical with or without the fix, so how capping `RAND_bytes` concurrency produces
this large a reduction in peak OS threads is still not understood from this data alone.
