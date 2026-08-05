# kubelet_watch_spam

Tools for generating a realistic kubelet watch workload and measuring the
kube-apiserver Go thread spike that occurs during rolling restarts.

## Background

When the kube-apiserver restarts, every kubelet that has pods on the cluster
must reconnect its watch connections. Each watch reconnection triggers
`uuid.New()` → `crypto/rand.Read()` → (in OCP's CGo-based FIPS build)
OpenSSL `RAND_bytes()`, which holds an OS thread for the duration of the CGo
call. With enough simultaneous reconnects, this can exhaust Go's 10,000-thread
limit and crash the apiserver.

This workload simulates that scenario using **native kubelet watches** — pods
that mount unique secrets and configmaps, causing the kubelet on each node to
maintain real watch connections to the apiserver. This is more realistic than
synthetic client-go reflectors because the reconnect behavior matches what
production kubelets do during an upgrade or rolling restart.

Each pod mounts a mix of **unique** (per-pod) and **common** (shared across
every pod in the namespace) objects, sized to match a customer report of
~73KB secrets and 256KB+ configmaps in production:

- Two **unique** secrets per pod (10 short key/value pairs each).
- Two **unique** configmaps per pod (10 short key/value pairs each).
- One **common** secret per namespace, shared by every pod
  (7 files x 10KiB random data ≈ 73KB total — matches a reported 73,744-byte secret).
- Two **common** configmaps per namespace, shared by every pod
  (1 file x 256KiB random data each).

Because the common objects are shared, each kubelet only needs a single watch
per common object regardless of how many pods on that node reference it — but
the object's *full* body is what gets re-fetched on every watch reconnect,
once per node. This mix reproduces both watch-count pressure (many small
unique secrets) and payload-size pressure (few large shared objects) at once.

Each pod's own spec is padded to **~8KB** (a representative production pod
spec size) with:

- 10 random labels (plus `app=mount-spam`) and 10 random annotations, keys
  and values at 31 chars each — ~50% of the 63-char Kubernetes label limit
  (annotation values have no such hard limit, but are sized the same way here
  for a representative footprint).
- 6 large environment variables, 900 bytes of random data each.

**For detailed root-cause analysis** — including a secondary kubelet-side
amplification loop discovered via audit+kubelet log correlation, and what
changes in Kubernetes 1.34-1.36 might affect it — see
[ROOT_CAUSE_FINDINGS.md](./ROOT_CAUSE_FINDINGS.md).

## Files

| File | Purpose |
|------|---------|
| `gen_mount_workload.py` | Generates secrets/ConfigMap/Pod YAML for one namespace |
| `setup_workload.sh` | **The load-out/deploy script** — KubeletConfig → namespaces → resources → pods |
| `run_rounds.sh` | Trigger rolling restarts and record peak `go_threads` per round |
| `monitor_and_capture.sh` | Continuously watch `go_threads`; snapshot audit logs the moment a spike is detected |
| `teardown_workload.sh` | Delete all workload resources and optionally restore maxPods |
| `churn_namespace.sh` | Repeatedly delete/recreate one namespace concurrently with restarts (stress variant, not in regular use) |
| `watch_distribution_monitor.sh` | Watch-count distribution monitoring |

## Quick Start

```bash
# 1. Deploy the default workload (10 namespaces × 240 pods, ~73KB common
#    secret + two 256KB common configmaps per namespace, 1 unique secret/pod)
./setup_workload.sh -n 10 -p 240

# 2. Run 5 rolling restart rounds (discard round 1 — see note below)
./run_rounds.sh -r 5 -l 4.22-kubelet-baseline

# 3. Scale up the common object sizes/counts if needed, e.g. 4 common
#    configmaps instead of 2 (delete pods first, then regenerate):
for i in {0..9}; do
  oc delete pods -n mount-spam-$i -l app=mount-spam --grace-period=0
done
./setup_workload.sh -n 10 -p 240 -c 4
./run_rounds.sh -r 5 -l 4.22-kubelet-4cm

# 4. Clean up everything (including KubeletConfig)
./teardown_workload.sh -K
```

## Watch Count Math

```
distinct_watched_objects_per_node ≈ pods_on_node × (UNIQUE_SECRETS + UNIQUE_CMS)
                                     + 1 (common secret)
                                     + CMS (common configmaps)
total_cluster_watches ≈ NAMESPACES × (PODS × (UNIQUE_SECRETS + UNIQUE_CMS) + 1 + CMS)
```

| Configuration | Pods | Distinct objects/namespace | ~Watches |
|--------------|------|----------------------------|---------|
| default (`-q 2 -w 2 -c 2`) | 2,400 | 963 (240×(2+2) unique secrets/cms + 1 common secret + 2 common cms) | ~9,630 |

Unlike the earlier all-unique-objects design, most *bytes* here are shared
per namespace — watch *count* is dominated by the per-pod unique secrets and
configmaps, while watch *payload size* is dominated by the few large common
objects (~73KB common secret, 256KB×N common configmaps) that every node
re-fetches in full on reconnect.

Target: keep `maxPods` at or below the node's actual OVN-Kubernetes per-node
subnet capacity (commonly ~500-520 usable IPs on a default `/23` hostSubnet),
**not** the kubelet default of 750. Exceeding it causes `ContainerCreating`
hangs from subnet exhaustion — which can also deadlock unrelated PDB-protected
platform pods (router, Prometheus, etc.) that can't find room to reschedule
during node maintenance. Default here is `maxPods=550`.

## setup_workload.sh

```
Usage: ./setup_workload.sh [OPTIONS]

  -n NAMESPACES   Number of namespaces (default: 10)
  -p PODS         Pods per namespace (default: 240)
  -q UNIQUE_SECRETS Unique secrets per pod (default: 2)
  -w UNIQUE_CMS   Unique configmaps per pod (default: 2)
  -u UNIQUE_KV    Short key/value pairs in each unique secret/configmap (default: 10)
  -v UNIQUE_KV_LEN Length in chars of each unique secret/configmap value (default: 24)
  -r UNIQUE_LARGE_SECRETS Unique large (single-file) secrets per pod (default: 0)
  -i UNIQUE_LARGE_SECRET_SIZE Size in bytes of each unique large secret (default: 131072 = 128KiB)
  -o UNIQUE_LARGE_CMS Unique large (single-file) configmaps per pod (default: 0)
  -j UNIQUE_LARGE_CM_SIZE Size in bytes of each unique large configmap (default: 131072 = 128KiB)
  -s SECRET_FILES Files in the shared common secret (default: 7)
  -f SECRET_SIZE  Size in bytes of each common secret file (default: 10240 = 10KiB)
  -c CMS          Number of shared common configmaps (default: 2)
  -z CM_SIZE      Size in bytes of each common configmap's file (default: 262144 = 256KiB)
  -l LABELS       Random labels per pod, beyond app=mount-spam (default: 10)
  -a ANNOTATIONS  Random annotations per pod (default: 10)
  -t TOKEN_LEN    Length of each label/annotation key and value (default: 31)
  -e ENV_VARS     Large environment variables per pod (default: 6)
  -y ENV_VAR_SIZE Size in bytes of each large env var's value (default: 900)
  -m MAXPODS      kubelet maxPods limit (default: 550)
  -b BATCH_SIZE   Pods per namespace applied per wave (default: 2)
  -x BATCH_WAIT   Seconds between in-flight-count polls within a wave (default: 5)
  -g MAX_WAVE_WAIT Max seconds to wait per wave for in-flight pods to drop
                  to <=3 before the script aborts with an error (default: 300)
  -k KUBECONFIG   Path to kubeconfig
  -d              Dry-run: generate manifests only, don't apply
```

What it does:
1. Applies a `KubeletConfig` setting `maxPods: MAXPODS` and waits for the
   MachineConfigPool rollout to complete across all worker nodes (~30–60 min).
2. Creates namespaces `mount-spam-0` through `mount-spam-N`.
3. Generates YAML manifests into `./manifests/` via `gen_mount_workload.py`.
4. Applies secrets and configmaps in parallel across all namespaces.
5. Applies pods in waves of `BATCH_SIZE` per namespace (via `batch_pods.py`).
   Creating all pods at once means every node tries to start hundreds of
   containers simultaneously, which can overwhelm crio/runc badly enough
   (sync-socket errors, apparently from sustained container-lifecycle churn
   rather than pure CPU contention — the failure threshold showed up at
   roughly the same absolute pod count regardless of burst size) that it
   never drains on its own. A fixed sleep between waves isn't sufficient
   either — pods already stuck retrying from a prior wave keep contributing
   load, so errors can still climb wave over wave. Instead, after each wave
   the script polls every `BATCH_WAIT` seconds (up to `MAX_WAVE_WAIT`) until
   the count of pods still `ContainerCreating`/`CreateContainerError`/`Pending`
   drops to 3 or fewer before starting the next wave. If it doesn't clear
   within `MAX_WAVE_WAIT`, the script **aborts** rather than proceeding —
   piling more pods onto a backlog that isn't draining is what turned a
   slow patch into a full thundering-herd meltdown in testing. Once past
   Step 5 it waits until ≥90% of all pods are Running.

## run_rounds.sh

```
Usage: ./run_rounds.sh [OPTIONS]

  -r ROUNDS       Number of rounds (default: 5)
  -w WAIT         Seconds between rounds (default: 60)
  -t TIMEOUT      Seconds to wait per rollout (default: 1200)
  -l LABEL        Label for forceRedeploymentReason (default: test)
  -k KUBECONFIG   Path to kubeconfig
```

Each round:
1. Patches `kubeapiserver/cluster` with a unique `forceDeploymentReason` to
   trigger a new revision.
2. Polls revision status and `go_threads{job="apiserver"}` from Prometheus
   every 15 seconds until all 3 masters have rolled.
3. Prints a `RESULT round=N peak=THREADS` line.

**Discard round 1.** The first round after any configuration change (new
workload, cluster restart, prior spike) captures carry-over thread state, not
a clean spike measurement. Rounds 2+ reflect steady-state behavior.

## teardown_workload.sh

```
Usage: ./teardown_workload.sh [OPTIONS]

  -n NAMESPACES   Number of namespaces to clean (default: 10)
  -K              Also delete the KubeletConfig (restores default maxPods)
  -k KUBECONFIG   Path to kubeconfig
```

Deletes pods, secrets, configmaps, and namespaces in parallel.
Pass `-K` to also remove the `increase-max-pods` KubeletConfig, which will
trigger another MachineConfigPool rollout to restore the default `maxPods`.

## gen_mount_workload.py

Lower-level manifest generator used by `setup_workload.sh`. Can be used
directly for custom configurations.

```
Usage: python3 gen_mount_workload.py [OPTIONS] > workload.yaml

  --pods N                    Number of pods in this namespace (default: 240)
  --unique-secrets N          Unique secrets per pod (default: 2)
  --unique-cms N              Unique configmaps per pod (default: 2)
  --unique-kv N               Short key/value pairs in each unique secret/configmap (default: 10)
  --unique-kv-len N           Length in chars of each unique secret/configmap value (default: 24)
  --unique-large-secrets N    Unique large (single-file) secrets per pod (default: 0)
  --unique-large-secret-size N Size in bytes of each unique large secret's file (default: 131072)
  --unique-large-cms N        Unique large (single-file) configmaps per pod (default: 0)
  --unique-large-cm-size N    Size in bytes of each unique large configmap's file (default: 131072)
  --common-secret-files N     Files in the shared common secret (default: 7)
  --common-secret-file-size N Size in bytes of each common secret file (default: 10240)
  --common-cms N              Number of shared common configmaps (default: 2)
  --common-cm-file-size N     Size in bytes of each common configmap's file (default: 262144)
  --pod-labels N              Random labels per pod, beyond app=mount-spam (default: 10)
  --pod-annotations N         Random annotations per pod (default: 10)
  --label-token-len N         Length of each label/annotation key and value (default: 31)
  --env-vars N                Large environment variables per pod (default: 6)
  --env-var-size N            Size in bytes of each large env var's value (default: 900)
  --namespace NS              Target namespace (default: default)
  --prefix PREFIX             Name prefix (default: mount-spam)
  --image IMAGE               Container image (default: ubi9/ubi-minimal:latest)
  --cpu CPU                   CPU request (default: 1m)
  --memory MEM                Memory request/limit (default: 4Mi — conmon's own
                               RSS is ~1.9MiB and shares the pod-level cgroup
                               under crio's conmon_cgroup=pod setting, so this
                               must stay comfortably above that or the pod's
                               cgroup can hit an unkillable-process OOM deadlock)
  --resources-only            Emit only Secret/ConfigMap objects
  --pods-only                 Emit only Pod objects
  --delete                    Emit delete manifests instead of create
```

With the defaults above, each pod's serialized spec is ~8KB (matching a
representative production pod spec size), on top of the volume mounts for
the unique/common secrets and configmaps.

Pod `i` mounts its own unique secrets (`{prefix}-secret-unique-{i}-{j}`) and
unique configmaps (`{prefix}-cm-unique-{i}-{j}`) plus the one shared common
secret and every shared common configmap in the namespace. The common
objects give a small number of large, heavily-shared watch targets; the
unique secrets/configmaps give many small, per-pod watch targets — a mix of
both watch-count and watch-payload-size pressure.

**Important:** Apply secrets/CMs before pods. If pods are created before their
referenced secrets exist, they will be stuck in `ContainerCreating` until the
secrets are available. Once the secrets land, the pods start without needing
to be deleted and recreated.

## Monitoring Queries

All queries run against the in-cluster Prometheus at
`http://localhost:9090` (reached via `oc exec -n openshift-monitoring prometheus-k8s-0 -- curl -sg ...`).

### Watch count — total active WATCH connections for secrets and configmaps

```promql
sum(apiserver_longrunning_requests{verb="WATCH", resource=~"secrets|configmaps"})
```

Breakdown by resource type:

```promql
sum by (resource) (apiserver_longrunning_requests{verb="WATCH", resource=~"secrets|configmaps"})
```

### Thread count — current OS threads per apiserver instance

```promql
go_threads{job="apiserver"}
```

### Peak threads — maximum threads seen over a rolling window (useful post-round)

```promql
max by (instance) (max_over_time(go_threads{job="apiserver"}[30m]))
```

Adjust the window (`30m`) to match the round duration. `run_rounds.sh` uses
instantaneous polling; this query is useful for capturing spikes that fell
between poll intervals.

### One-liner to check both from the shell

```bash
KC=/path/to/kubeconfig

# Watch count
oc --kubeconfig=$KC exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -sg 'http://localhost:9090/api/v1/query?query=sum(apiserver_longrunning_requests{verb="WATCH",resource=~"secrets|configmaps"})' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('watches:', d['data']['result'][0]['value'][1])"

# Thread count per instance
oc --kubeconfig=$KC exec -n openshift-monitoring prometheus-k8s-0 -- \
  curl -sg 'http://localhost:9090/api/v1/query?query=go_threads{job="apiserver"}' \
  | python3 -c "
import json,sys; d=json.load(sys.stdin)
for r in d['data']['result']:
    print(f\"  {r['metric']['instance']}  threads={r['value'][1]}\")
"
```

## go-semaphore-v3 Investigation — Final Results (2026-08-03/04)

**Status: paused pending a final build to test.** The go-semaphore fix candidate is a two-file
patch to `vendor/github.com/golang-fips/openssl/v2` (`sem.go` new, `rand.go` modified) that wraps
`RAND_bytes` in a semaphore capped at `runtime.NumCPU()` (tunable via `GOLANG_FIPS_DRBG_LIMIT`),
originally proposed alongside a custom per-CPU-DRBG kernel as a combined fix.

**Two important build-fidelity findings first:** the go-semaphore images tested through
2026-08-03 (`v1`, `v2`) were missing the `golang-src` RPM matching the patched toolchain, so they
were compiled against the *stock* Go standard library — the semaphore code was never actually
present in those binaries (confirmed via `go tool nm`). All results from those builds were removed
from this repo as invalid. `go-semaphore-v3` (built with `golang`+`golang-bin`+`golang-src` all at
the same NVR, plus `GOEXPERIMENT=strictfipsruntime` set explicitly to match the official build
pipeline) is the first build confirmed to actually contain the patch.

**With `go-semaphore-v3`, all three configurations tested at n=38 rounds:**

| Stat | Stock baseline | go-semaphore-v3 + stock kernel | go-semaphore-v3 + DRBG kernel |
|---|---:|---:|---:|
| mean peak threads | 636 | 185 (**-71%**) | 184 (**-71%**) |
| median peak threads | 535 | 131 (**-76%**) | 138 (**-74%**) |
| p90 | 1174 | 383 (-67%) | 390 (-67%) |
| max | 2795 | 958 (-66%) | 578 (-79%) |

- **go-semaphore-v3 vs. stock baseline:** Welch's t ≈ 5.0 on both kernel variants — highly
  statistically significant (p < 0.0001), and the effect *strengthened* with more rounds rather
  than washing out as noise (the opposite of every earlier build-flawed comparison).
- **DRBG kernel vs. stock kernel (both with go-semaphore-v3):** Welch's t = 0.031 — essentially no
  difference. **The per-CPU-DRBG kernel — the more invasive half of the original proposal, requiring
  custom kernel RPMs and node reboots — contributes nothing measurable beyond the go-semaphore
  build alone.**
- **Open question:** goroutine dumps captured during spikes show the same watch-reconnect-storm
  signature (~90%+ of goroutines in `cacheWatcher.process`/`WatchServer.HandleHTTP`) with or
  without the fix — the semaphore's large effect on peak OS thread counts isn't explained by any
  visible change to that dominant goroutine population. The causal mechanism remains unconfirmed.
- **RAND_bytes concurrency** (measured directly via bpftrace uprobe on `RAND_bytes` in
  `libcrypto.so.3`) is bounded but not hard-capped at the theoretical 16 — likely because other
  OpenSSL-internal call sites into `RAND_bytes` don't route through the semaphore-gated Go wrapper.

Full data and methodology: `results/2026-08-01-stock-baseline-4xlcp-20rounds.md`,
`results/2026-08-03-go-semaphore-v3-stock-kernel-20rounds.md`,
`results/2026-08-03-go-semaphore-v3-drbg-kernel-20rounds.md`,
`results/2026-08-02-threaddump-analysis.md`. Build recipe: `containerfiles/Containerfile.go-semaphore`.

## Current Workload Configuration (go-semaphore / stock A-B comparison)

The workload actively used for the go-semaphore vs. stock kube-apiserver
comparison (doubled control plane, m6i.4xlarge masters) differs from the
Quick Start defaults above:

- **Scale:** 10 namespaces (`mount-spam-0`..`9`) × 290 pods = 2,900 total pods
- **Per-pod resources:**
  - 8 unique secrets + 8 unique configmaps (5 short key/value pairs each, 32 chars/value)
  - 8 unique large secrets @ 8KiB each
  - 8 unique large configmaps @ 8KiB each
  - Pod spec padded to ~8KB via 10 labels + 10 annotations (31-char keys/values) + 6 env vars (900B each)
  - Resources: 8Mi memory request/limit, 1m CPU
- **Per-namespace shared resources:** 1 common secret (1 file × 128KiB), 2 common configmaps (1 file × 256KiB each = 512KiB total)
- **maxPods:** 512 (KubeletConfig override on the worker pool)
- **Rollout mechanics:** batches of 5 pods/namespace per wave (up to 50 concurrent cluster-wide), polling every 5s (cap 300s) between waves

Exact invocation:

```bash
./setup_workload.sh -n 10 -p 290 -q 8 -w 8 -u 5 -v 32 -r 8 -i 8192 -o 8 -j 8192 \
  -s 1 -f 131072 -c 2 -z 262144 -b 5 -x 5 -g 300 -m 512
```

## Measured Results (OCP 4.22.1, CGo FIPS build)

All results use 10 namespaces × 240 pods/namespace = 2,400 total pods,
with workers at 750 maxPods. "Round 1 discarded" per convention.

**Note:** these measurements predate the retool to unique+common
secrets/configmaps (see Background above) and used the old all-unique-objects
shape (`-s`/`-c` = unique secrets/cms per pod). Kept here as a historical
baseline; re-measure with the current workload shape before comparing.

| Watch count | Rounds (2–5) peak threads | Notes |
|------------|--------------------------|-------|
| ~33k (7s+7c) | 73 / 116 / 644 / 292 | Bimodal — occasional large spike |
| ~65k (14s+14c) | 351 / 471 / 471 / 158 | Roughly linear scaling |

Compare to reflector-spam at ~32k watches: **180–3,475 threads** (much more
variable and extreme) because client-go reflectors reconnect more
simultaneously than the kubelet's watch manager.

## Notes on Thread Behavior

- **Threads do not decay while the process is running.** OS threads held after
  a spike persist until the kube-apiserver pod restarts. Go's thread trimmer
  is conservative and rarely reclaims them under ongoing watch load.
- **Rolling restart clears threads.** When the kube-apiserver pod is replaced
  as part of a new revision, the old process dies and all accumulated threads
  are released. The new pod starts fresh at ~20 threads.
- **Round 1 artifact.** If the previous round or any prior operation left
  elevated threads, round 1 will capture that carry-over as its "peak."
  Always discard round 1 when starting a fresh measurement session.
