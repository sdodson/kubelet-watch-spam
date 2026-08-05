# Cluster and workload configuration snapshot — before scale-down

**Date:** 2026-08-04
**Cluster:** fips-mode-5c8hc

Recorded immediately before deleting the workload and scaling the cluster down at the end of the
go-semaphore investigation, for reference if this environment is reused later.

## Control plane

- **Instance type:** `m6i.4xlarge` (16 vCPU / 64 GiB) — doubled from the original `m6i.2xlarge`
  early in this investigation to better match the customer's 48 vCPU / 192 GiB proportions.
- **Count:** 3 (managed via `ControlPlaneMachineSet cluster`, `spec.replicas: 3`)
- **Machines:** `fips-mode-5c8hc-master-5xr4p-1`, `fips-mode-5c8hc-master-qc4f6-0`,
  `fips-mode-5c8hc-master-xc927-2`

## Workers

- **Instance type:** `m6i.2xlarge` across all worker machinesets
- **Count:** 7 total, split across 3 machinesets:
  - `fips-mode-5c8hc-worker-us-east-2a`: 3 replicas
  - `fips-mode-5c8hc-worker-us-east-2b`: 2 replicas
  - `fips-mode-5c8hc-worker-us-east-2c`: 2 replicas
- **KubeletConfig:** `increase-max-pods`, `maxPods: 512`, applied to the worker
  `MachineConfigPool`

## Workload

- 10 namespaces (`mount-spam-0` through `mount-spam-9`), 290 pods each = 2,900 workload pods
- ~3,192 total running pods cluster-wide (workload + platform)
- Exact `setup_workload.sh` invocation (see README.md "Current Workload Configuration" section):
  ```bash
  ./setup_workload.sh -n 10 -p 290 -q 8 -w 8 -u 5 -v 32 -r 8 -i 8192 -o 8 -j 8192 \
    -s 1 -f 131072 -c 2 -z 262144 -b 5 -x 5 -g 300 -m 512
  ```

## kube-apiserver

- Image: `quay.io/sdodsonrht/getrandperf:go-semaphore` (the confirmed-working semaphore build)
- Kernel on all 3 masters: `5.14.0-730.el9.x86_64` (per-CPU-DRBG test kernel) — though this
  investigation's own results show the kernel contributes nothing measurable beyond the
  go-semaphore build alone (see `2026-08-03-go-semaphore-drbg-kernel-20rounds.md`)
- `--profiling=true` set via `unsupportedConfigOverrides.apiServerArguments` on the KubeAPIServer CR
- Namespace churn (`churn_namespace.sh`, default settings) was running against `mount-spam-9`

## Planned changes (this session)

1. Delete all workload pods (`app=mount-spam`) across all 10 namespaces.
2. Scale worker machinesets down to at most 3 total, instance type `m6i.large`.
3. Resize control plane from `m6i.4xlarge` to `m6i.xlarge` via `ControlPlaneMachineSet`.

## Result — cluster state after scale-down (2026-08-04/05)

All three changes above completed successfully:

- **Workload:** all `mount-spam-*` pods deleted (0 remaining).
- **Workers:** scaled to exactly 3, one `m6i.large` per AZ (`fips-mode-5c8hc-worker-us-east-2a`,
  `-2b`, `-2c`, 1 replica each). Done one machineset at a time (scale to 0, wait for old
  `m6i.2xlarge` machine to fully terminate, scale back to 1 to force recreation with the new
  `instanceType`) so at least 2 AZs of worker capacity remained available throughout.
- **Control plane:** `ControlPlaneMachineSet cluster` instance type patched to `m6i.xlarge`;
  CPMS performed its normal one-at-a-time rolling replacement (etcd-quorum-aware) of all 3
  masters. Final CP: `fips-mode-5c8hc-master-pqwz7-0` (us-east-2a), `-24q2f-1` (us-east-2b),
  `-kgx5x-2` (us-east-2c), all `m6i.xlarge`, all `Running`. CPMS shows `3/3/3` and no
  clusteroperators are Degraded. Each old-master drain showed the expected transient
  `EtcdQuorumOperator` pre-drain-hook block followed by `DrainRequeued`/`DrainProceeds` cycling
  on dozens of platform pods before draining successfully — consistent with prior CP resizes in
  this investigation, not a real problem.
- kube-apiserver image is still `quay.io/sdodsonrht/getrandperf:go-semaphore` (unchanged) and
  the DRBG test kernel is still installed on all 3 (new) masters (unchanged, since resize
  replaces machines but not their configured kernel override).
