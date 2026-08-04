# go-semaphore-v3 (real semaphore) + STOCK kernel — 40 rounds (2 batches)

**Date:** 2026-08-03 (batch 1), 2026-08-04 (batch 2)
**Cluster:** fips-mode-5c8hc

This isolates the go-semaphore-v3 build's effect from the per-CPU-DRBG test kernel, by reverting
all 3 masters to the stock kernel (`5.14.0-570.126.1.el9_6`) while keeping `go-semaphore-v3`
deployed, then running 20 rounds under the same conditions as
`2026-08-03-go-semaphore-v3-drbg-kernel-20rounds.md`. A second 20-round batch was added on
2026-08-04 (same config, unchanged) to bring the sample size up to n=38, matching the stock
baseline's sample size.

## Environment

- **Control plane:** 3x m6i.4xlarge (16 vCPU / 64 GiB), consistent with all prior datasets.
- **Kernel:** `5.14.0-570.126.1.el9_6.x86_64` (stock), all 3 masters — reverted via
  `rpm-ostree override reset --all` + reboot, one master at a time with etcd-health checks.
- **kube-apiserver image:** `quay.io/sdodsonrht/getrandperf:go-semaphore-v3` (unchanged from the
  DRBG-kernel test — confirmed via `go tool nm` to contain the real semaphore).
- **`--profiling=true`**, namespace churn: same as the DRBG-kernel test (both were already active
  from that prior test and left running).
- **Workload:** same 2,900-pod config.
- **Harness:** `run_rounds.sh -r 20 -l go-semaphore-v3-stock-kernel`, standard settings.

## Raw per-round peak Go-thread counts

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 45 |
| 2  | 225 |
| 3  | 160 |
| 4  | 46 |
| 5  | 175 |
| 6  | 143 |
| 7  | 102 |
| 8  | 96 |
| 9  | 28 |
| 10 | 958 |
| 11 | 104 |
| 12 | 114 |
| 13 | 127 |
| 14 | 457 |
| 15 | 468 |
| 16 | 68 |
| 17 | 257 |
| 18 | 22 |
| 19 | 82 |
| 20 | 59 |

Full timestamped detail: `2026-08-03-go-semaphore-v3-stock-kernel-rounds-raw.log`.

### Batch 2 (2026-08-04, same config)

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 171 |
| 2  | 176 |
| 3  | 81 |
| 4  | 52 |
| 5  | 66 |
| 6  | 348 |
| 7  | 343 |
| 8  | 94 |
| 9  | 72 |
| 10 | 161 |
| 11 | 543 |
| 12 | 74 |
| 13 | 186 |
| 14 | 63 |
| 15 | 190 |
| 16 | 155 |
| 17 | 35 |
| 18 | 134 |
| 19 | 220 |
| 20 | 351 |

Full timestamped detail: `2026-08-04-go-semaphore-v3-stock-kernel-batch2-rounds-raw.log`.

## Summary statistics

| Stat | Batch 1 (n=19) | Batch 2 (n=19) | Combined (n=38) |
|---|---:|---:|---:|
| mean | 194.3 | 176.0 | 185.1 |
| median | 114.0 | 155.0 | 130.5 |
| stdev | 223.6 | 134.3 | 182.1 |
| p90 | 459.2 | 348.6 | 382.8 |
| min | 22 | 35 | 22 |
| max | 958 | 543 | 958 |

## Three-way comparison (combined n=38 vs. n=38)

| Stat | Stock baseline (n=38) | go-semaphore-v3 + stock kernel (n=38) | go-semaphore-v3 + DRBG kernel (n=19) |
|---|---:|---:|---:|
| mean | 635.6 | **185.1** | 215.0 |
| median | 535.0 | **130.5** | 154.0 |
| p90 | 1174.2 | 382.8 | 509.6 |
| max | 2795 | 958 | 578 |
| stdev | 527.7 | 182.1 | 166.3 |

**Welch's t-test, stock baseline (n=38) vs. go-semaphore-v3 + stock kernel (n=38): t = 4.974,
df ≈ 45.7 — highly significant** (p < 0.0001), and *stronger* than the batch-1-only comparison
(t=4.423) — doubling the sample size reinforced the effect rather than revealing it as noise,
the opposite of what happened with every earlier (build-flawed) go-semaphore comparison in this
investigation. Mean reduction **70.9%**, median reduction **75.6%**.

**Welch's t-test, go-semaphore-v3 + stock kernel (batch 1, n=19) vs. go-semaphore-v3 + DRBG kernel
(n=19): t = -0.324 — not remotely significant.** The two kernel conditions remain statistically
indistinguishable from each other with the go-semaphore-v3 build in place.

## Conclusion: the DRBG kernel contributes nothing measurable

This cleanly isolates the two variables that were previously bundled together as "the solution":

- **go-semaphore-v3 alone (stock kernel) already produces the full effect** — a large,
  highly-significant reduction vs. stock baseline, matching (if not slightly exceeding) the
  combined kernel+build result.
- **Adding the per-CPU-DRBG kernel on top of go-semaphore-v3 adds no additional detectable
  benefit.** The kernel was the more invasive, harder-to-deploy half of the original "solution"
  (requiring `rpm-ostree` kernel replacement and node reboots) — this result suggests it can be
  dropped entirely without losing any of the observed improvement.

Combined with all prior findings in this investigation (no visible change to the watch-storm
goroutine population, partial-not-total RAND_bytes concurrency capping), the current best
explanation is: **the go-semaphore patch to `vendor/github.com/golang-fips/openssl/v2` is doing
essentially all of the work**, and the per-CPU-DRBG kernel — the other half of what was originally
proposed as a bundled fix — appears to be unnecessary.

## Caveats

- Namespace churn and `--profiling=true` were already active from the prior test and carried over
  unchanged into this one, so both datasets in this comparison share that condition — the
  isolation here is specifically kernel-vs-kernel, with build and workload held constant.
- As with the DRBG-kernel dataset, individual round outliers (958, 468, 457) show the same
  round-to-round variance this investigation has documented throughout — driven by how many
  clients happen to reconnect simultaneously during a given restart, not by the fix candidate.
- This does not by itself rule out a *smaller*, harder-to-detect benefit from the DRBG kernel at
  this sample size — only that no such benefit is visible here. Given go-semaphore-v3 alone already
  explains the full effect size, further isolating a possible small residual kernel contribution
  would need many more rounds than is likely worthwhile.
