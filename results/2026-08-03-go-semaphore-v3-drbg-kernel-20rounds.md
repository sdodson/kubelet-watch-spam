# go-semaphore-v3 (real semaphore) + per-CPU-DRBG kernel — 20 rounds

**Date:** 2026-08-03
**Cluster:** fips-mode-5c8hc

**This is the first test of the actual, functioning semaphore patch.** All prior go-semaphore
results in this investigation (v1, v2 — both removed from this repo) were built without the
`golang-src` RPM matching the patched toolchain, so `go build` silently compiled against the
*stock* standard library source. The semaphore code
(`vendor/github.com/golang-fips/openssl/v2/sem.go`) was never part of those binaries — confirmed
absent via `go tool nm` on an unstripped build. This test uses `go-semaphore-v3`, built with
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
- **kube-apiserver image:** `quay.io/sdodsonrht/getrandperf:go-semaphore-v3`
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
- **Harness:** `run_rounds.sh -r 20 -l go-semaphore-v3-drbg-kernel`, standard settings.
- **Concurrent instrumentation:** a periodic `/debug/pprof/threadcreate` capture (every 15s) plus a
  triggered `/debug/pprof/goroutine` + `/debug/pprof/threadcreate` capture whenever any node's
  `go_threads` exceeded a threshold (200 initially, lowered to 120 partway through) via
  `oc get --raw`, both LB-routed (not targeted to a specific node). Raw output:
  `randbytes-probe-v3/threadcreate_watch.txt`, `randbytes-probe-v3/goroutine_watch.txt`.

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

Full timestamped detail: `2026-08-03-go-semaphore-v3-drbg-kernel-rounds-raw.log`.

## Summary statistics (rounds 2-20, n=19)

| Stat | Value |
|---|---:|
| mean | 215.0 |
| median | 154.0 |
| p75 | 299.0 |
| p90 | 509.6 |
| stddev | 166.3 |
| min | 31 |
| max | 578 |

## Comparison vs. combined stock baseline (n=38)

| Stat | Stock baseline (n=38) | go-semaphore-v3 + DRBG (n=19) | Reduction |
|---|---:|---:|---:|
| mean | 635.6 | 215.0 | **66.2%** |
| median | 535.0 | 154.0 | **71.2%** |
| p75 | 906.5 | 299.0 | 67.0% |
| p90 | 1174.2 | 509.6 | 56.6% |
| stddev | 527.7 | 166.3 | (much less noisy) |

**Welch's two-sample t-test: t = 4.488, df ≈ 49.2 — highly statistically significant** (p < 0.0001).
This is a completely different result from every prior comparison in this investigation. The
earlier power analysis established that ~20-40 rounds/arm could only reliably detect a 50-70%+
effect at this noise level — this result clears that bar decisively, and by a comfortable margin
on both mean and median simultaneously (unlike every earlier, build-flawed comparison, where mean
and median routinely disagreed on direction).

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
capture (22) is used above. See `randbytes-probe-v3/v3_ip-10-0-54-184.log` for the raw evidence.

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

- **Namespace churn was not active for the first 11 of 20 rounds**, then was enabled partway
  through (per user request, to increase load). This makes the round-to-round conditions
  non-uniform within this single dataset. Splitting the data: rounds 2-11 (no churn, n=10) mean =
  249.2, median = 227.5; rounds 12-20 (churn, n=9) mean = 177.0, median = 126.0 — if anything,
  thread counts were *lower* under churn in this run, suggesting churn did not inflate results
  here, but a cleaner re-run with churn active for the full 20 rounds would remove this confound
  entirely.
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

This is the first evidence in this investigation of a real, large, statistically significant
improvement from a candidate fix. Given everything found here was against a binary now confirmed
to contain the actual patch (unlike every prior go-semaphore test), this result should be
considered far more credible than anything measured earlier. Recommended next steps: (1) re-run
with churn active for the full duration to remove that confound, (2) investigate the mechanism by
which the semaphore reduces peak threads despite the watch-storm goroutine population being
unchanged, (3) consider isolating the DRBG-kernel and go-semaphore-build effects independently
(this test still bundles them together) if resources allow.
