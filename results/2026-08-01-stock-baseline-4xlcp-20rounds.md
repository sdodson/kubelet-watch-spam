# Stock kube-apiserver / stock kernel — baseline (batch 1 + batch 2, n=38)

**Date:** 2026-08-01 (batch 1), 2026-08-02 (batch 2)
**Cluster:** fips-mode-5c8hc

This is the baseline for comparison against the combined "solution under test" (per-CPU-DRBG
kernel + go-semaphore kube-apiserver build), recorded in
`2026-08-01-go-semaphore-drbg-kernel-20rounds.md`.

**Update 2026-08-02:** collected a second 20-round batch (`stock-baseline-4xlcp-batch2`) on the
identical environment (no config changes between batches) to increase sample size and check
whether the initial apparent gap vs. the solution held up. Batch 2 raw log:
`2026-08-02-stock-baseline-4xlcp-batch2-rounds-raw.log`.

## Environment

- **Control plane:** 3x m6i.4xlarge (16 vCPU / 64 GiB) — same doubled-CP config as the solution run.
- **Kernel (all 3 masters):** `5.14.0-570.126.1.el9_6.x86_64` (stock) — reverted from the
  `5.14.0-730.el9` per-CPU-DRBG test kernel via `rpm-ostree override reset --all` + reboot,
  one master at a time, with etcd-health checks between each.
- **kube-apiserver image (all 3 masters):** stock,
  `quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:ce9842798b75bec812500f61ca0952dc735adeac6c2f3499eb92dcb1e028a636`
  — reverted by unsetting the `IMAGE` env var on `kube-apiserver-operator` and removing the CVO
  unmanaged override.
- **`GOLANG_FIPS_DRBG_LIMIT`:** not set (default).
- **Revision range:** kube-apiserver revisions 297 → 316 across the 20 rounds.
- **Workload:** same 2,900-pod config as the solution run (~3,183 total running pods at test start).
- **Harness:** `run_rounds.sh -r 20 -l stock-baseline-4xlcp`, 60s cooldown, 1200s timeout/round.
  `monitor_and_capture.sh -t 14400 -i 15` ran concurrently.

## Raw per-round peak Go-thread counts

### Batch 1 (revisions 297 → 316)

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 380 |
| 2  | 913 |
| 3  | 714 |
| 4  | 1173 |
| 5  | 598 |
| 6  | 887 |
| 7  | 186 |
| 8  | 337 |
| 9  | 659 |
| 10 | 1206 |
| 11 | 748 |
| 12 | 228 |
| 13 | 255 |
| 14 | 731 |
| 15 | 1133 |
| 16 | 381 |
| 17 | 178 |
| 18 | 81 |
| 19 | 309 |
| 20 | 296 |

Full timestamped detail: `2026-08-01-stock-baseline-4xlcp-rounds-raw.log`.

### Batch 2 (revisions 316 → 336, same environment, no config changes)

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 2827 |
| 2  | 252 |
| 3  | 2795 |
| 4  | 608 |
| 5  | 1075 |
| 6  | 309 |
| 7  | 485 |
| 8  | 1539 |
| 9  | 401 |
| 10 | 200 |
| 11 | 977 |
| 12 | 172 |
| 13 | 573 |
| 14 | 616 |
| 15 | 1103 |
| 16 | 178 |
| 17 | 132 |
| 18 | 497 |
| 19 | 1177 |
| 20 | 51 |

Full timestamped detail: `2026-08-02-stock-baseline-4xlcp-batch2-rounds-raw.log`.

## Summary statistics

| Stat | Batch 1 (n=19) | Batch 2 (n=19) | Combined (n=38) |
|---|---:|---:|---:|
| mean | 580 | 692 | 636 |
| median | 598 | 497 | 535 |
| p75 | 818 | 1026 | 907 |
| p90 | 1141 | 1249 | 1174 |
| stddev | 364 | 659 | 528 |
| min | 81 | 51 | 51 |
| max | 1206 | 2795 | 2795 |

## Comparison: combined stock baseline (n=38) vs. go-semaphore+DRBG-kernel solution (n=19)

| Stat | Stock baseline (n=38) | Solution (n=19) | Delta |
|---|---:|---:|---:|
| mean | 636 | 657 | +3.4% (worse) |
| median | 535 | 468 | -12.5% (better) |
| p75 | 907 | 686 | -24.4% (better) |
| p90 | 1174 | 1364 | +16.2% (worse) |
| stddev | 528 | 645 | +22% (noisier) |

**Welch's two-sample t-test (mean thread count, n=38 vs n=19): t = -0.125, df≈30.4 — not
statistically significant**, and weaker than the batch-1-only comparison (t=-0.455). Doubling the
baseline sample size shrank the apparent gap (mean delta went from +13.3% to +3.4%, median delta
from -21.7% to -12.5%) rather than confirming it — the initial batch-1 gap was largely noise.

## Conclusion

With combined stock-baseline n=38 vs. solution n=19, there is **no detectable effect** from the
go-semaphore + per-CPU-DRBG-kernel combination. The two distributions largely overlap; the
apparent improvement seen after the first 20-round comparison did not hold up with more data.
Per the earlier power analysis, distinguishing a real ~30-40% effect from this noise floor would
require substantially more rounds per arm (order ~100+), or a fundamentally lower-noise
measurement approach (e.g. direct bpftrace instrumentation of blocking call stacks rather than
peak aggregate thread counts).
