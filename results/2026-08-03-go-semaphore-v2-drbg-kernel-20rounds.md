# Corrected go-semaphore build + per-CPU-DRBG kernel — 20 rounds

**Date:** 2026-08-03
**Cluster:** fips-mode-5c8hc

This supersedes the earlier `2026-08-01-go-semaphore-drbg-kernel-20rounds.md` dataset, which used
a hand-rolled `go build ./cmd/kube-apiserver` invocation that diverged from the official OpenShift
build pipeline (missing `GOEXPERIMENT=strictfipsruntime`, confirmed via `go version -m` showing no
`X:strictfipsruntime` tag on that binary vs. stock). This run uses a corrected image built from the
actual `openshift-hack/images/hyperkube/Dockerfile.rhel` `make WHAT=...` process with only the
patched Go toolchain RPMs and `GOEXPERIMENT=strictfipsruntime` added — confirmed via `go version`
to now match stock's build flags exactly:
```
stock:                go1.24.13 (Red Hat 1.24.13-5.el9_6) X:strictfipsruntime
go-semaphore-v2:      go1.24.13 (Red Hat 1.24.13-10.testonly.el9_8) X:strictfipsruntime
```

## Environment

- **Control plane:** 3x m6i.4xlarge (16 vCPU / 64 GiB), same as all other datasets in this series.
- **Kernel:** `5.14.0-730.el9.x86_64` (per-CPU-DRBG test kernel), all 3 masters.
- **kube-apiserver image:** `quay.io/sdodsonrht/getrandperf:go-semaphore-v2`
  - Built via `rpms/Containerfile.go-semaphore` (updated version) — official `make WHAT=...` build
    process, `golang-1.24.13-10.testonly.el9_8` toolchain, `GOEXPERIMENT=strictfipsruntime` set
    explicitly, `GOTOOLCHAIN=local` to pin to the patched toolchain.
  - Verified: `GOLANG_FIPS_DRBG_LIMIT` string still absent from the compiled binary even with
    correct build flags — the code path is unreachable from kube-apiserver's actual crypto/rand
    usage (routes through `vendor/github.com/golang-fips/openssl/v2`, not Go's native
    `crypto/internal/fips140/drbg`). See `2026-08-02-randbytes-probe-comparison.md` and prior
    conversation for the full trace.
  - Verified: no semaphore-related symbols beyond generic Go runtime internals and gRPC's
    pre-existing `atomicSemaphore` — byte-for-byte identical to stock on this front.
- **Workload:** same 2,900-pod config as all other datasets. 3188 pods running at test start.
- **Harness:** `run_rounds.sh -r 20 -l go-semaphore-v2-drbg-kernel`, standard settings.

## Raw per-round peak Go-thread counts

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 989 |
| 2  | 129 |
| 3  | 1132 |
| 4  | 213 |
| 5  | 366 |
| 6  | 832 |
| 7  | 1444 |
| 8  | 384 |
| 9  | 47 |
| 10 | 52 |
| 11 | 504 |
| 12 | 1364 |
| 13 | 864 |
| 14 | 963 |
| 15 | 1016 |
| 16 | 389 |
| 17 | 930 |
| 18 | 231 |
| 19 | 2187 |
| 20 | 1044 |

Full timestamped detail: `2026-08-03-go-semaphore-v2-drbg-kernel-rounds-raw.log`.

## Summary statistics (rounds 2-20, n=19)

| Stat | Value |
|---|---:|
| mean | 742 |
| median | 832 |
| p75 | 1030 |
| p90 | 1380 |
| stddev | 564 |
| min | 47 |
| max | 2187 |

## Comparison vs. combined stock baseline (n=38)

| Stat | Stock baseline (n=38) | go-semaphore-v2 + DRBG (n=19) | Delta |
|---|---:|---:|---:|
| mean | 636 | 742 | +16.7% (worse) |
| median | 535 | 832 | +55.5% (worse) |
| p75 | 907 | 1030 | +13.6% (worse) |
| p90 | 1174 | 1380 | +17.6% (worse) |
| stddev | 528 | 564 | +7% (noisier) |

**Welch's two-sample t-test: t = -0.684, df=34 — not statistically significant** at these sample
sizes, consistent with the established noise floor for this metric (CV 70-90%). However, unlike
the earlier (build-divergent) comparison where mean and median disagreed on direction, **both
mean and median now consistently point the same direction: worse than stock**, not better.

## Conclusion

With the build-fidelity issue corrected (matching stock's `GOEXPERIMENT=strictfipsruntime` flag),
the go-semaphore + per-CPU-DRBG-kernel combination shows a consistent (though not statistically
proven) trend toward *higher* peak thread counts than stock, not lower. Combined with the rest of
this investigation's findings — no semaphore construct present in the binary, no RAND_bytes
concurrency cap observed, `GOLANG_FIPS_DRBG_LIMIT` unreachable from kube-apiserver's actual code
path, and no correlation between thread-spike magnitude and RAND_bytes concurrency — the weight of
evidence now leans toward: **this fix candidate does not resolve the thread-explosion problem, and
may make it somewhat worse.** This should not be treated as statistically proven given the sample
size, but it is no longer plausible to describe this combination as a clear improvement.
