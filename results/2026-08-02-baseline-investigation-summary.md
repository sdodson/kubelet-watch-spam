# Baseline investigation summary (doubled m6i.4xlarge control plane)

**Date range:** 2026-08-01 to 2026-08-02
**Cluster:** fips-mode-5c8hc

This ties together the three data-gathering efforts run in this phase of the investigation, all
on the same doubled control plane (3x m6i.4xlarge, 16 vCPU/64 GiB — matching the customer's
48 vCPU/192 GiB proportions) with the same 2,900-pod watch-thundering-herd workload.

## 1. Stock kernel / stock kube-apiserver baseline (n=38)

Two 20-round batches, same environment, no config changes between them:

| Stat | Batch 1 (n=19) | Batch 2 (n=19) | Combined (n=38) |
|---|---:|---:|---:|
| mean | 580 | 692 | 636 |
| median | 598 | 497 | 535 |
| p75 | 818 | 1026 | 907 |
| p90 | 1141 | 1249 | 1174 |
| stddev | 364 | 659 | 528 |
| min/max | 81/1206 | 51/2795 | 51/2795 |

Full detail: `2026-08-01-stock-baseline-4xlcp-20rounds.md`.

## 2. go-semaphore build + per-CPU-DRBG kernel "solution" (n=19)

The patched-Go-toolchain `go-semaphore` kube-apiserver build, running on a custom test kernel
(`5.14.0-730.el9`) that introduces per-CPU DRBG state — evaluated together as one combined
candidate fix, not as independently isolated variables.

| Stat | Value |
|---|---:|
| mean | 657 |
| median | 468 |
| p75 | 686 |
| p90 | 1364 |
| stddev | 645 |

Full detail: `2026-08-01-go-semaphore-drbg-kernel-20rounds.md`.

## 3. Comparison: does the solution help?

**No.** Welch's two-sample t-test (combined baseline n=38 vs. solution n=19): **t = -0.125 —
nowhere near significant.**

| Stat | Baseline (n=38) | Solution (n=19) | Delta |
|---|---:|---:|---:|
| mean | 636 | 657 | +3.4% (worse) |
| median | 535 | 468 | -12.5% (better) |
| p75 | 907 | 686 | -24.4% (better) |
| p90 | 1174 | 1364 | +16.2% (worse) |

Mean and median disagree on direction — a symptom of high variance/right-skew in both datasets,
not a real effect. This tracks the earlier power analysis for this investigation: at the observed
noise levels (CV 60-100%), ~20-40 rounds/arm can only reliably detect a 50-70%+ effect size, and a
realistic effect (if any) is more likely in the 30-40% range — invisible at this sample size.
Doubling the baseline sample (batch 1 → combined) *shrank* the apparent gap rather than confirming
it, which is itself informative: the initial batch-1-only comparison was mostly noise.

## 4. What's actually driving the thread spikes (Go pprof thread-dump analysis)

Captured live threadcreate/goroutine dumps from a specific master mid-spike (1017 threads, +989
over baseline) using Go's own `/debug/pprof` endpoints, targeted directly at the spiking node
rather than round-robined through the LB. Full detail: `2026-08-02-threaddump-analysis.md`.

- **95.4% of goroutines (187K of 196K) at peak are watch-serving infrastructure** — split evenly
  between `cacheWatcher.process` (cache dispatch) and `WatchServer.HandleHTTP` (per-connection
  handler) — i.e. roughly **93,000 concurrent watch connections** on that one master. This
  directly confirms the thundering-herd mechanism this harness reproduces.
- **535 of 536 OS threads ever created had no attributable Go-level call stack** in the
  threadcreate profile — the signature of the Go scheduler's internal `sysmon`/`retake`/`startm`
  machinery spinning up replacement threads, consistent with P's getting stuck blocked
  (e.g. in a cgo call) rather than any single identifiable application code path.
- **Did not directly catch a goroutine mid-TLS-handshake or mid-`RAND_bytes`** — the full
  per-goroutine dump took 76s to generate under load (stop-the-world proportional to goroutine
  count) and by the time it returned, the storm had already collapsed from 196K to 10.8K
  goroutines. This is a real limitation of this specific tool under this load, not a bug.

## Overall picture

- The stock-vs-solution comparison is **statistically inconclusive** at current sample sizes —
  we cannot say the go-semaphore+DRBG-kernel combination helps or hurts.
- The **root trigger is confirmed** to be a genuine mass watch-reconnect event (~93K simultaneous
  connections per master), and OS thread growth is scheduler-driven rather than tied to one
  application code path.
- The **crypto/DRBG-contention link is not yet directly proven** by this session's data — it
  remains supported by earlier bpftrace work (which did directly observe threads blocked inside
  libcrypto) but unconfirmed by this round's Go-native pprof capture, due to a timing/tooling
  limitation rather than contradicting evidence.

## Open paths forward

1. Substantially more rounds per arm (order 100+) to resolve a realistic 30-40% effect size, or
   a lower-noise measurement method.
2. Repeat the pprof capture using fast (`debug=1`) polling throughout the whole spike window
   instead of a single slow `debug=2` snapshot, to catch the transient handshake/crypto window.
3. Re-run the bpftrace RAND_bytes/blocked-call-stack probes (proven working earlier this
   investigation) alongside a restart round on the current stable cluster state, for direct
   crypto-layer evidence.
