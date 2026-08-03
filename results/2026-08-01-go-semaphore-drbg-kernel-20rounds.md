# go-semaphore build on per-CPU-DRBG test kernel — 20 rounds

**Date:** 2026-08-01
**Cluster:** fips-mode-5c8hc

**Solution under test:** the new per-CPU-DRBG kernel and the go-semaphore kube-apiserver build
are being evaluated together as a single combined solution, not as independently-isolated
variables. The relevant comparison baseline is the stock kube-apiserver build on the stock
(old) kernel.

## Environment

- **Control plane:** 3x m6i.4xlarge (16 vCPU / 64 GiB) — doubled from m6i.2xlarge earlier in this
  investigation to match the customer's 48 vCPU / 192 GiB proportions more closely.
- **Kernel (all 3 masters):** `5.14.0-730.el9.x86_64` — custom test kernel introducing per-CPU DRBG,
  installed via `rpm-ostree override replace` from `/root/kernel-730.tar.gz`, one master at a time
  with etcd-health checks between each reboot.
- **kube-apiserver image (all 3 masters):** `quay.io/sdodsonrht/getrandperf:go-semaphore`
  - Built from `openshift/kubernetes` commit `2df3632e823a813f64218dfc6f5c2e70d28ecdf0`
  - Compiled with patched Go toolchain `golang-1.24.13-10.testonly.el9_8` (RPM in `./rpms/`),
    which limits/serializes thread creation during heavy `crypto/rand`/OpenSSL usage.
  - Deployed via CVO unmanaged override on `kube-apiserver-operator` Deployment (`group: "apps"`)
    + `IMAGE` env var, per the standard procedure in this repo.
- **`GOLANG_FIPS_DRBG_LIMIT`:** not set (default) for this run.
- **Revision range:** kube-apiserver revisions 275 → 295 across the 20 rounds.
- **Workload:** 2,900 pods (10 namespaces × 290 pods), standard `setup_workload.sh` config —
  see README.md "Current Workload Configuration" section for the exact invocation.
  ~3,188 total running pods cluster-wide at test start (workload + platform).
- **Harness:** `run_rounds.sh -r 20 -l go-semaphore-drbg-kernel`, 60s cooldown between rounds,
  1200s timeout per round. `monitor_and_capture.sh -t 14400 -i 15` ran concurrently for spike capture.

## Raw per-round peak Go-thread counts

Round 1 is conventionally discarded (captures carry-over state from the just-completed deploy,
not a clean spike measurement).

| Round | Peak threads |
|-------|-------------:|
| 1 (discard) | 1785 |
| 2  | 468 |
| 3  | 190 |
| 4  | 2716 |
| 5  | 1463 |
| 6  | 536 |
| 7  | 339 |
| 8  | 698 |
| 9  | 271 |
| 10 | 260 |
| 11 | 673 |
| 12 | 134 |
| 13 | 520 |
| 14 | 66 |
| 15 | 317 |
| 16 | 166 |
| 17 | 631 |
| 18 | 1339 |
| 19 | 407 |
| 20 | 1289 |

Full timestamped per-round detail (kubelet revision + per-master watch counts at each 15-20s
sample) preserved in `2026-08-01-go-semaphore-drbg-kernel-rounds-raw.log` in this directory.

## Summary statistics (rounds 2-20, n=19)

| Stat | Value |
|---|---:|
| mean | 657 |
| median | 468 |
| p75 | 686 |
| p90 | 1364 |
| stddev | 645 |
| CV (stddev/mean) | ~98% |
| min | 66 |
| max | 2716 |

## Caveats / known gaps

- **No valid baseline dataset currently survives.** The solution under test is the new kernel +
  go-semaphore build together, evaluated against a stock-kube-apiserver-on-stock-kernel baseline
  (doubled-CP config). Earlier 20-round stock and 18-round go-semaphore datasets from this same
  investigation were lost in a local machine `/tmp` (tmpfs) wipe. A partial 8-round fragment of a
  stock resume run survived (`/tmp/run_rounds_stock_resume.log`, revisions 266-267, old kernel) —
  too few rounds to serve as a reliable baseline on its own.
- Next step: collect a fresh 20-round stock-build/stock-kernel baseline (doubled-CP config) to
  compare against this dataset.
- Noise level remains high (CV ~98%), consistent with earlier power-analysis findings in this
  investigation: at this noise level, ~20 rounds/arm can only reliably detect effect sizes on the
  order of 50-70% reduction, not the ~30-40% that may be realistic.
- bpftrace probes (RAND_bytes concurrency, thread-activity, blocked-stack-signature tracing) were
  NOT running during this test — they were transient systemd units that did not survive the
  kernel-install reboots and were not redeployed.
