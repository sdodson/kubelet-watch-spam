# Root Cause Findings: kube-apiserver Thread Explosion

This document captures what the spike-capture tooling (`monitor_and_capture.sh`)
revealed about *why* kube-apiserver thread spikes happen during rolling
restarts, beyond the top-level FIPS/CGo mechanism already described in the
main [README.md](./README.md). Findings are from OCP 4.20.24 (Kubernetes
1.33, `client-go` v0.33.2).

## Summary

The thread explosion has two layers:

1. **Primary mechanism** (already known): `crypto/rand.Read()` in FIPS/CGo
   mode holds an OS thread per concurrent call. A mass watch-reconnect event
   creates thousands of new OS threads in seconds.
2. **Secondary amplification** (new finding, this document): kubelet's
   per-object secret/configmap watch manager cannot resync its local cache
   fast enough during a mass reconnect, causing volume mount failures that
   retry and add **additional** request load on top of the original storm.

## Finding 1: The reconnect burst is clean at moderate scale, throttled at high scale

Audit log captures across multiple rounds show:

- At typical spike volumes (~20-40k requests in a 10s window), kube-apiserver
  serves nearly everything with `200 OK` — a clean, uniform reconnect burst.
- At the highest-volume events (e.g. one round saw 37,611 requests in 10s on
  a single node), the API Priority & Fairness (APF) filter begins returning
  `429 Too Many Requests` (534 in that window). APF's retry-after value is
  **adaptive**, not fixed — see `dropped_requests_tracker.go`: it starts at 1
  second and doubles (capped at 32s) when drops exceed `3x` the current value
  within that window. At the observed drop rate (~53/sec), it would have
  self-escalated to 2-4+ seconds within the same burst.
- The 429s were a small fraction of total burst traffic (~1.4% in the worst
  case observed) — the overwhelming majority of thread-creating connections
  succeeded on the first attempt. **Throttling is a symptom of an already-large
  burst, not the primary driver of burst size.**

## Finding 2: Watch volume is not evenly distributed across control-plane nodes

In every captured spike, one control-plane node consistently absorbed
50-60% more reconnect traffic than its peers in the same window (e.g. 37.6k
vs 23.5k requests on two nodes during the same 10-second burst). This is
consistent with connection redistribution behavior after a node restart —
watches previously pinned to a terminated instance land disproportionately
on whichever backend the load balancer/client considers "available" first,
rather than spreading evenly.

## Finding 3 (new): kubelet's per-object watch manager cache-sync timeouts amplify the storm

This is the most actionable finding, found only by capturing **kubelet**
journal logs (not just apiserver audit logs) at the moment of a spike.

### What we found

kubelet runs one independent `Reflector.ListAndWatch` goroutine **per
referenced Secret and ConfigMap** (confirmed directly: 19,271 distinct
Secret reflectors and 19,247 distinct ConfigMap reflectors captured on a
single node in one capture window) — not one shared informer per namespace.
This is the default behavior of kubelet's `WatchingSecretManager` /
`WatchingConfigMapManager` (`configMapAndSecretChangeDetectionStrategy:
Watch`, the kubelet default).

When kube-apiserver restarts, **all of these per-object watches must
re-establish simultaneously**. On two independently-captured nodes during
this test, the local cache-sync step could not keep up:

| Error | Node A | Node B |
|-------|-------:|-------:|
| `Couldn't get secret ...: failed to sync secret cache: timed out waiting for the condition` | 35,109 | 39,731 |
| `Couldn't get configMap ...: failed to sync configmap cache: timed out waiting for the condition` | 36,800 | 41,030 |
| `MountVolume.SetUp failed` (downstream of the above) | 71,400 | 80,252 |

Each `MountVolume.SetUp` failure retries on a 4-second backoff
(`nestedpendingoperations.go`), which issues **additional** `get`/`list`
calls against kube-apiserver — on top of the original reconnect burst. This
explains why the audit log's busiest bucket showed elevated `list` volume
(733 in one capture) alongside the expected flood of `watch` calls: pure
watch-reconnect storms shouldn't need many `list` calls, but cache-timeout
retries do.

### Why this matters

This is a feedback loop, not just a one-time cost:

```
apiserver restarts
  → all per-object kubelet watches reconnect simultaneously
  → local cache can't sync fast enough (too many concurrent reflectors)
  → MountVolume.SetUp fails, retries after 4s
  → retries add more get/list load on an already-overloaded apiserver
  → thread creation continues longer / to a higher peak than a clean
    one-shot reconnect would produce
```

This plausibly explains node-to-node variance in spike severity: a node
whose kubelets get stuck in this retry loop keeps generating apiserver load
well past the initial reconnect window, while a node whose kubelets
resync cleanly does not.

### A related upstream bug — already fixed before our test ran

[kubernetes/kubernetes#126958](https://github.com/kubernetes/kubernetes/issues/126958)
describes the *exact* symptom string we captured
(`failed to sync secret/configmap cache: timed out waiting for the
condition`), on Kubernetes 1.29, when the `WatchList` feature is enabled.
Root cause there: kubelet's cache-sync poll (`wait.PollImmediate(10ms, 1s,
hasSynced)`) times out after exactly 1 second, but the apiserver's
WatchList "cache is now synced" bookmark event was emitted on a *jittered*
timer (`wait.Jitter(1s, 0.25)` → 1.0-1.25s) — so the bookmark could
legitimately arrive after the kubelet had already given up.

**Confirmed fix**: [PR #127012](https://github.com/kubernetes/kubernetes/pull/127012)
("send bookmark right now after sending all items in watchCache store"),
merged 2024-09-26, **milestone v1.32** — removes the jitter wait and sends
the bookmark immediately once the watch cache store is confirmed fresh
(demonstrated fix: bookmark latency dropped from 741-866ms to 8-13ms).

This means the specific timing race in #126958 was **already fixed before
our 1.33 test cluster existed** — it cannot be what produced the errors we
captured. Our failures must come from a distinct (if related) mechanism:
not a single client losing a ~1s timing race against a jittered bookmark,
but **tens of thousands of reflectors on one node simultaneously exceeding
their fixed 1-second sync budget** under sheer concurrent load — a volume
problem, not a timer-jitter problem. The fix in #127012 tightens the
jitter window but doesn't change the fact that the sync timeout itself
(`wait.PollImmediate(10ms, 1s, hasSynced)`) is fixed at 1 second regardless
of how many objects are syncing concurrently on that node.

## What changes in Kubernetes 1.34 - 1.36

We have **not** re-run this benchmark against 1.34+ yet. Unlike the initial
pass at this section (based on release notes only), the following is
verified by reading the actual kubelet/client-go source at the `v1.36.0`
tag directly.

### The per-object watch architecture is unchanged in 1.36

`pkg/kubelet/util/manager/watch_based_manager.go` at `v1.36.0` is,
mechanically, the same design present in our 1.33 test cluster:

- Each secret/configmap still gets its **own dedicated reflector**
  (`cache.NewReflectorWithOptions`, one per object, field-selected on
  `metadata.name`) — not a shared per-namespace informer.
- The sync-wait is still exactly:
  ```go
  wait.PollImmediate(10*time.Millisecond, time.Second, item.hasSynced)
  ```
  A **fixed 1-second timeout**, regardless of how many other objects are
  concurrently syncing on the same node. This is the exact mechanism behind
  the errors we captured, and it has not changed.
- One new-since-our-test detail: `MinWatchTimeout: 30 * time.Minute`
  (comment: *"Bump default 5m MinWatchTimeout to avoid recreating watches
  too often"*) — this reduces how often watches get proactively torn down
  and re-established in **steady state**, but has no effect on a mass
  reconnect triggered by an apiserver restart, which is what our test
  measures.

### What *did* change: `WatchListClient` defaults to on starting v1.35

kubelet's `pkg/kubelet/secret/secret_manager.go` (and the configmap
equivalent) unconditionally wrap their reflector's `ListerWatcher`:

```go
listWatcherWithWatchListSemanticsWrapper := func(lw *cache.ListWatch) cache.ListerWatcher {
    return cache.ToListWatcherWithWatchListSemantics(lw, kubeClient)
}
```

Whether this actually changes behavior is gated by the client-go
**`WatchListClient`** feature (`staging/src/k8s.io/client-go/features/known_features.go`):

```go
WatchListClient: {
    {Version: version.MustParse("1.30"), Default: false, PreRelease: Beta},
    {Version: version.MustParse("1.35"), Default: true,  PreRelease: Beta},
},
```

**Beta since 1.30 (opt-in, default off) → default *on* starting v1.35.**
Since kubelet inherits this from the client-go version it's built against
with no separate kubelet-specific gate, **every kubelet secret/configmap
reflector on Kubernetes 1.35+ uses WatchList-streaming semantics by
default**, where on our 1.33/1.34 cluster it would still use the
traditional List-then-Watch pattern.

In `staging/src/k8s.io/client-go/tools/cache/reflector.go`, this means the
reflector's initial sync is a single streaming connection (an
`itemsAreEndedByBookmark`-terminated stream) instead of a separate paginated
LIST call followed by a WATCH — with graceful fallback to classic
List+Watch if the server rejects the stream (`fallbackToList` in
`ListAndWatchWithContext`).

### Net assessment for a 1.35+/1.36 re-test

- **The thundering-herd *count* is unchanged.** A node with N referenced
  secrets/configmaps still opens N independent reflectors simultaneously
  after an apiserver restart, on 1.36 exactly as on 1.33. WatchList doesn't
  reduce how many concurrent watch-establishment operations happen.
- **The fixed 1-second `hasSynced` timeout is unchanged.** This is the
  actual trigger for the errors we captured, and nothing in 1.34-1.36
  touches it.
- **What plausibly improves**: on 1.35+, each of those N reflectors
  populates via a lighter-weight streaming initial-sync instead of a
  discrete LIST + WATCH pair, and (combined with `SnapshottableCache`,
  default-on since 1.34, and streaming LIST responses, beta since 1.33)
  the *server-side* cost of serving thousands of these concurrently should
  be measurably lower. If each individual sync completes faster under
  load, fewer of them would be expected to blow through the still-fixed
  1-second client-side timeout — which would show up as **fewer**
  `failed to sync secret/configmap cache` errors and fewer downstream
  `MountVolume.SetUp` retries, not as a different failure mode entirely.
- **This does not touch the primary FIPS/CGo mechanism** — thread creation
  from `crypto/rand.Read()` in CGo mode is a Go-runtime/OpenSSL
  characteristic, completely orthogonal to any of the above. A 1.35+/1.36
  re-test would only be expected to show a smaller *secondary*
  amplification (Finding 3), not a different peak-thread-count story from
  the primary mechanism.

**This is a testable, falsifiable prediction** — worth an actual re-run on
an OCP release built on Kubernetes 1.35+ (OCP 4.22, per the version mapping
in `[[fips-rand-thread-explosion]]` memory) with the same kubelet log
capture tooling, watching specifically for the `Couldn't get secret` /
`Couldn't get configMap` / `MountVolume.SetUp failed` error volumes to
drop relative to the 1.33 baseline captured here.

## Empirical confirmation on OCP 4.22.3 (Kubernetes 1.35.5) — final results

We upgraded the test cluster 4.20.24 → 4.21.22 → 4.22.3 (no custom images —
4.22 ships OpenSSL 3.5 stock) and re-ran the same 128k-watch, 15-minute-
cooldown protocol with `monitor_and_capture.sh` active throughout. We
stopped after round 7 (skipped the planned round 8) once the pattern was
clearly established; round 1 is discarded per the usual carry-over
convention.

### Peak thread counts (rounds 2-7)

| Condition | p75 | p90 | Max | n |
|---|---:|---:|---:|---:|
| Baseline 4.20 (128k) | 2461 | 3725 | 3937 | 10 |
| openssl35 4.20 (128k, 15-min cooldown) | 996 | 1093 | 1097 | 7 |
| **4.22.3 stock (128k, 15-min cooldown)** | **834** | **1304** | **1715** | 6 |

Peak thread counts land in the same range as the 4.20 openssl35 build —
confirming the primary FIPS/CGo thread-creation mechanism is
version-independent, exactly as predicted (4.22 ships OpenSSL 3.5 stock,
same underlying fix, no custom image needed to get it).

### Kubelet-side cache-sync errors — the actual finding of this investigation

Across all 9 audit-log spikes captured with full kubelet-log context
(31 total source-node observations):

| Metric | 4.20 (Kubernetes 1.33) | 4.22.3 (Kubernetes 1.35) |
|---|---|---|
| Nodes affected | 100% (every captured node) | **10%** (3 of 31 observations) |
| Per-node error count when it occurs | 35,109 - 80,252 | Hundreds to low thousands (worst observed: 6,105) |

The `Couldn't get secret`/`Couldn't get configMap`/`MountVolume.SetUp
failed` cache-sync-timeout errors that dominated every single 4.20 capture
are **not eliminated but dramatically reduced** on 4.22.3 — both in how
often they occur (10% of nodes vs. 100%) and in magnitude when they do
(10-40x lower). This is consistent with the predicted mechanism:
`WatchListClient` defaulting on in Kubernetes 1.35 makes each of kubelet's
thousands of per-object reflector syncs cheaper/faster server-side, so
fewer of them blow through the still-unchanged fixed 1-second client-side
sync timeout — without eliminating the possibility entirely under the
heaviest bursts.

**Bottom line: the hypothesis is confirmed.** The secondary kubelet-side
amplification loop documented in Finding 3 is substantially mitigated by
Kubernetes 1.35's `WatchListClient` default flip, and — per the source
review above — this should persist unchanged into 1.36 (the next OpenShift
release), since it stays on the same etcd-client and grpc-go generations
without reverting any of the relevant changes.

## Appendix: an unrelated but notable side-finding — etcd-client gRPC connection churn

While comparing apiserver pod logs between the 4.20 and 4.22.3 captures
(not kubelet logs this time — the apiserver's own log), we found a large,
consistent difference in an unrelated subsystem: kube-apiserver's internal
etcd client generates far more gRPC connection churn on 4.22.3.

### What we measured

Comparing two similarly long-running apiserver pod log captures:

| | 4.20 (4h10m pod lifetime) | 4.22.3 (2h46m pod lifetime) |
|---|---|---|
| Total `addrConn.createTransport failed` warnings | 20 | ~2,958 |
| Steady-state rate (excluding startup) | ~1 every 12 min | ~1 every 3-4 seconds |
| Dominant failure reason | `authentication handshake failed: context canceled` | `Error while dialing: operation was canceled` |
| Target distribution | Rotates evenly across all 3 etcd peers + localhost | 502 of 508 steady-state errors hit **one single peer** |

etcd itself showed no crash-restarts and the `etcd` ClusterOperator
reported fully healthy throughout — this is not an etcd availability
problem. It looks like kube-apiserver's etcd client repeatedly opens and
then abandons connection attempts to one specific peer, continuously, for
the pod's entire lifetime.

### Likely mechanism: grpc-go's `pick_first` Happy Eyeballs default flip, landing in the same release as etcd's resolver rewrite

**Correction from initial write-up**: the relevant dependency changes land
at the **4.20 → 4.21 boundary**, not 4.21 → 4.22 as first framed. We only
captured apiserver pod logs at 4.20 and 4.22.3 (4.21 was a brief stepping
stone we didn't instrument), but version evidence says 4.21 already carries
both changes:

| Dependency | 4.20 | 4.21.22 | 4.22.3 | 1.36 (next release) |
|---|---|---|---|---|
| `go.etcd.io/etcd/client/v3` | v3.5.21 | v3.6.4 | v3.6.5 | v3.6.8 |
| `google.golang.org/grpc` | v1.68.1 | **v1.72.1** | v1.72.2 | v1.79.3 |
| Go | 1.24.0 | 1.24.0 | 1.25.0 | 1.26.0 |

Two changes, read together, plausibly explain the signature we captured:

1. **etcd client v3.6.0-rc.5** ([PR #19782](https://github.com/etcd-io/etcd/pull/19782)):
   *"Replace `resolver.State.Addresses` with `resolver.State.Endpoint.Addresses`"*
   — restructures how the etcd client's gRPC resolver presents member
   addresses to the balancer, grouping addresses under `Endpoint` objects
   (following grpc-go's own deprecation of the flat `Addresses` field).
   This is a prerequisite for a single logical target to carry *multiple*
   candidate addresses. Present from v3.6.0 onward — i.e. already in 4.21.
2. **grpc-go v1.72.0** (confirmed via [release notes](https://github.com/grpc/grpc-go/releases/tag/v1.72.0)):
   *"pickfirst: The new pick first LB policy is made the default. The new
   LB policy implements the Happy Eyeballs algorithm"* — when a resolver
   presents multiple addresses for one target, `pick_first` now **races
   concurrent connection attempts** (RFC 8305) and cancels whichever
   attempts don't win. OCP 4.20's grpc-go (v1.68.1) predates this entirely
   — the old `pick_first` made one attempt at a time, no racing, no
   cancellation. **4.21.22 already ships v1.72.1 — past the v1.72.0 default
   flip.** We separately confirmed v1.71.0's release notes make no mention
   of `pick_first` or Happy Eyeballs at all, so the flip happens at exactly
   v1.72.0, not gradually across 1.69-1.71.

Together: etcd's resolver rewrite makes multi-address endpoints possible,
and grpc-go's now-default Happy-Eyeballs `pick_first` races and cancels
losing candidates among them — which is exactly what `operation was
canceled` during dial means. If something about the connection topology
keeps re-triggering this race against the same peer repeatedly (rather
than settling once), you'd see exactly our observed steady drumbeat.

**Practical implication**: since 4.21 already carries both dependency
versions, **OCP 4.21 should exhibit the same etcd-client gRPC connection
churn as 4.22.3** — we just don't have a direct log capture to confirm it
empirically, only version evidence. If this mechanism is ever revisited,
capturing apiserver pod logs on a 4.21 cluster would close that gap.

**Correction to an earlier cross-reference.** An earlier draft of this
document (and this project's memory, `[[fips-rand-thread-explosion]]`)
attributed some kubelet watch-reconnect staggering behavior between OCP
4.20 and 4.21 to this same grpc-go `pick_first` change. **That's very
likely incorrect.** kubelet talks to kube-apiserver over plain HTTP(S) via
`client-go`'s REST client (`net/http`) — it never uses
`google.golang.org/grpc` or its balancer machinery. The `pick_first`
Happy-Eyeballs change can only affect gRPC-based clients, which in this
codebase means kube-apiserver's **etcd client**, not kubelet's watch path.
Whatever caused the kubelet-side staggering noted in that earlier memory
(gRPC v1.68→v1.72 was the framing used there) needs a different
explanation — possibly the `client-go` v0.33.2 HTTP/2 connection-pool
behavior, or something else in the request path — and that memory note
should be revisited/corrected separately from this document's etcd-client
finding, which stands on its own.

### Status for Kubernetes 1.36 (the next OpenShift release)

**No reversion expected.** 1.36 stays on the etcd client v3.6.x line
(v3.6.8 — a patch bump from 4.22's v3.6.5, not a generation change; the
changelog entries between them relate to gRPC metadata handling, not the
resolver/dial path) and grpc-go moves further past the `pick_first`
default flip (v1.79.3, vs. the v1.72.0 flip point). **This behavior should
persist unchanged into the next OpenShift release** — if it matters, it's
not a transient 4.22-only artifact.

### Impact assessment

No functional impact observed in our test — etcd and its ClusterOperator
remained fully healthy throughout, and this churn is a background
subsystem unrelated to the kubelet watch-storm/FIPS-thread investigation
this document otherwise covers. Flagging it here because: (a) it's a real,
large, measurable behavioral difference we stumbled into as a side effect
of comparing apiserver logs across versions, (b) sustained high-frequency
connection-attempt churn against one peer is the kind of thing that could
matter more under heavier real-world load or a degraded network path than
our synthetic test exercises, and (c) it reinforces that dependency bumps
in this version range (grpc-go crossing 1.72, etcd client crossing 3.6)
have real, observable behavioral consequences beyond the kubelet-watch
mechanism this document is primarily about — worth keeping in mind for any
future investigation of connection-related apiserver behavior on 4.22+.

We have not confirmed this explanation with gRPC-level connectivity
tracing or a line-by-line diff of the resolver/balancer code — treat it as
a well-sourced, plausible lead, not a proven root cause.

### Correction: kubelet does not use gRPC

An earlier draft of this document (and this project's memory,
`[[fips-rand-thread-explosion]]`) attributed some kubelet watch-reconnect
staggering behavior between OCP 4.20 and 4.21 to this same grpc-go
`pick_first` change. **That's very likely incorrect.** kubelet talks to
kube-apiserver over plain HTTP(S) via `client-go`'s REST client
(`net/http`) — it never uses `google.golang.org/grpc` or its balancer
machinery. `pick_first`/Happy-Eyeballs can only affect gRPC-based clients,
which in this codebase means kube-apiserver's **etcd client**, not
kubelet's watch path. Whatever caused the kubelet-side staggering noted in
that earlier memory needs a different explanation (see the client-go
review below, which found no transport-level change that would explain
it either) — that memory note should be revisited separately from this
document's etcd-client finding, which stands on its own.

## Full review: grpc-go v1.72.0 → v1.79.3

Requested follow-up: review every release in the range spanning OCP 4.21
(v1.72.1) / 4.22 (v1.72.2) through Kubernetes 1.36 (v1.79.3) for anything
else relevant to connection management, balancers, keepalive, retries, or
backoff. Compiled from official release notes on each tagged release.

| Version | Relevant changes |
|---|---|
| v1.72.0 | `pick_first` made default; implements Happy Eyeballs (RFC 8305) — the change discussed above. |
| v1.72.1 | Bug fixes only: HTTP proxy no longer attempted for non-TCP addresses; fixed RPCs incorrectly failing with `INTERNAL` instead of `CANCELLED`/`DEADLINE_EXCEEDED` on mid-stream `RST_STREAM`. No balancer/dial behavior change. |
| v1.72.2 | Bug fixes only: restored `NO_PROXY` env var support for locally-resolved addresses; fixed a panic in `least_request` balancer on resolver errors. **This is what OCP 4.22.3 ships.** |
| v1.72.3 / v1.73.1 | Both: fixed a regression preventing streams from being cancelled/timed out while blocked on flow control (identical fix backported to both lines). |
| v1.73.0 | `least_request` LB policy enabled by default for xDS (opt-out via env var) — xDS-only, not applicable here. Added `CallAuthority` call option. **Server-side**: non-positive `grpc-timeout` header values now rejected (a regression, see v1.74.2). |
| v1.74.2 | Reverted part of the v1.73.0 regression: explicitly re-allowed `0s` `grpc-timeout` header values for compatibility with older gRPC-Java clients. New `Balancer.ExitIdle` interface requirement (previously optional). New `WithStaticStreamWindowSize`/`WithStaticConnWindowSize` dial options for fixed (vs. dynamic BDP-based) HTTP/2 flow-control windows — opt-in, not default. |
| v1.74.3 | Bug fixes only (flow-control regression backport, xDS load-reporting data race). |
| v1.75.0 | **`round_robin` balancer**: now randomizes the order addresses are connected to, "to spread out initial RPC load between clients" — default-on, but this is `round_robin`, not `pick_first`; etcd's client would need to be configured to use `round_robin` for this to apply (unconfirmed whether it is). xDS fallback env-var override removed (no longer possible to disable). |
| v1.75.1 | Bug fixes only (stats-handler data race, flow-control regression). |
| v1.76.0 | Fixed a race causing `pick_first` to get stuck in `IDLE` state on backend address change — a **reliability fix directly in the code path we're investigating**, though it fixes a stuck/hang scenario rather than changing steady-state churn behavior. |
| v1.77.0 | **Removed support for reverting to the old `pick_first` policy** (the `GRPC_EXPERIMENTAL_ENABLE_NEW_PICK_FIRST=false` escape hatch no longer works) — the new Happy-Eyeballs `pick_first` is now the only option, no fallback. Fixed a `pick_first` bug where duplicate addresses weren't ignored. Added address shuffling for resolver updates lacking endpoints (relevant to non-`Endpoint`-based resolvers falling back to `pick_first`). Read-deadline added when closing a transport to avoid indefinite blocking on a broken connection. |
| v1.78.0 | Connectivity-state transition fixes around resolver creation and idle-timeout handling — none change `pick_first`/etcd-client behavior directly. |
| v1.79.0 | **`pick_first`: added weighted random shuffling of endpoints (gRFC A113), enabled by default** (opt-out via `GRPC_EXPERIMENTAL_PF_WEIGHTED_SHUFFLING`) — layers randomized endpoint ordering on top of the existing Happy-Eyeballs racing. `weightedtarget` balancer now only handles `Endpoints`, dropping legacy `Addresses` support (continues the same Endpoint-based resolver trend as etcd client v3.6). New opt-in `random_subsetting` LB policy (gRFC A68). |
| v1.79.1-v1.79.3 | Bug/security fixes only (User-Agent header cleanup, stats-logging noise reduction, a `:path` header authorization-bypass fix on the server side). **This is what Kubernetes 1.36 ships.** |

**No explicit keepalive, application-level retry-policy, or generic backoff
default changes were found anywhere in this range.** The `pick_first`
default flip (v1.72.0) remains the single most relevant change for our
etcd-client churn finding. v1.79.0's weighted-shuffling addition is the
next most relevant — if this is ever re-tested against a Kubernetes
1.36-based OpenShift release, expect the "one peer takes the brunt"
pattern we captured on 4.22.3 to look more randomized/spread across peers
rather than concentrated on a single one, since shuffling was layered on
top of the same racing-and-canceling mechanism, not reverted.

## Full review: client-go changes affecting kubelet's connection to kube-apiserver (1.33 → 1.36)

Since kubelet uses `client-go`'s HTTP-based REST client, not gRPC, we
separately reviewed the actual code paths kubelet's watches ride on,
comparing `v1.33.0` against `v1.36.0` directly (not release notes —
line-by-line diffs of the source).

### HTTP transport layer: unchanged

`staging/src/k8s.io/client-go/transport/cache.go` (the base `http.Transport`
construction used by every client-go client, including kubelet's) is
**byte-for-byte identical** between 1.33 and 1.36:

- `MaxIdleConnsPerHost` = 25 (`idleConnsPerHost` constant)
- Dialer: 30s connect timeout, 30s TCP keep-alive
- `TLSHandshakeTimeout` = 10s

`staging/src/k8s.io/apimachinery/pkg/util/net/http.go` (`SetTransportDefaults`
→ `configureHTTP2Transport`) is also **unchanged**:

- HTTP/2 `ReadIdleTimeout` = 30s (env override: `HTTP2_READ_IDLE_TIMEOUT_SECONDS`)
- HTTP/2 `PingTimeout` = 15s (env override: `HTTP2_PING_TIMEOUT_SECONDS`)

**Conclusion**: there is no transport-level change in this range that
would explain any kubelet-side connection-timing difference. This
reinforces the correction above — whatever the earlier project memory was
describing about kubelet reconnect staggering, it isn't explained by
either the grpc-go bump (wrong subsystem entirely) or a client-go
transport-layer change (nothing changed here either).

### Reflector backoff/retry: refactored, not behaviorally changed by default

We initially suspected `staging/src/k8s.io/client-go/tools/cache/reflector.go`
had gained a new exponential-backoff mechanism between 1.33 and 1.36 —
**this turned out to be wrong on closer inspection**, worth documenting
precisely since it's an easy mistake to make from a surface-level diff:

- The exponential backoff parameters — `800ms` initial, `30s` cap, `2min`
  reset, `2.0` factor, `1.0` jitter, with the exact comment *"We used to
  make the call every 1sec (1 QPS), the goal here is to achieve ~98%
  traffic reduction when API server is not healthy"* — **already exist
  verbatim in 1.33** via `wait.NewExponentialBackoffManager(...)`. 1.36
  expresses the identical values as named constants
  (`defaultBackoffInit`, `defaultBackoffMax`, etc.) feeding a
  `wait.DelayFunc`-based `delayHandler` instead of a `wait.BackoffManager`
  interface — a code-structure refactor with the same numbers, not a
  behavior change.
- Watch-timeout randomization range is also **unchanged by default**: 1.33
  computes `minWatchTimeout * rand[1.0, 2.0)`; 1.36 computes
  `minWatchTimeout + rand[0,1) * (maxWatchTimeout - minWatchTimeout)`
  with `defaultMaxWatchTimeout = 2 * defaultMinWatchTimeout` — algebraically
  the same `[minWatchTimeout, 2*minWatchTimeout)` range either way. The
  only difference is 1.36 exposes the multiplier as a configurable
  `maxWatchTimeout`/`ReflectorOptions` field instead of a hardcoded `2x`.

**What genuinely is new in 1.36**, none of it relevant to reconnect-storm
timing:

- A `Backoff *wait.Backoff` field added to `ReflectorOptions`, letting a
  caller override the (still-identical-by-default) backoff config. Per an
  inline `TODO(#136943)`, this isn't yet plumbed through
  `SharedInformerFactory` — so kubelet's watch-based manager has no way to
  actually use this override today even if it wanted to.
- The `UseWatchList *bool` field (tri-state: nil/true/false, letting
  higher layers pre-decide) became a private plain `bool` — an API
  simplification, not a behavior change for kubelet's default path.
- WatchList-fallback logging got quieter: 1.33 logs at `Error` level
  (*"The watchlist request ended with an error, falling back..."*); 1.36
  logs at `V(4).Info` (*"Data couldn't be fetched in watchlist mode.
  Falling back to regular list. This is expected..."*) — a pure
  observability change; operators watching for ERROR-level logs won't see
  WatchList fallbacks as noisy errors on 1.36.
- New `ReflectorBookmarkStore` / `TransformingStore` interfaces, a
  `VeryShortWatchError` typed error (replacing a bare `fmt.Errorf`), and
  correctness fixes around resource-version propagation ordering and
  rejecting unsupported `Table`-kind watch events (#132926). None of these
  touch reconnect timing or backoff.

**Bottom line**: nothing in client-go's actual kubelet-facing code path
changed in a way that would produce the etcd-client-style connection
churn we found, nor does it explain the (now-suspect) earlier claim about
kubelet reconnect staggering. That claim needs to be tracked down
separately — it isn't in the transport layer or the reflector's own
backoff/timeout logic.

## Tooling used

All findings above came from `monitor_and_capture.sh`, which watches
`go_threads{job="apiserver"}` and, the moment a spike is detected, captures
before rotation/restart can destroy the evidence:

- The apiserver's current audit log (`_audit.jsonl`) + an automated
  verb/URI/user burst breakdown (`_analysis.txt`)
- The kubelet journal (last 20 minutes) from the top 5 source nodes
  identified *from the audit log itself* (`_kubelet_<host>.log`) — this is
  what surfaced Finding 3; audit logs alone only show the apiserver side
- The kube-apiserver pod's own container log (`_apiserver_pod.log`)

See `monitor_and_capture.sh -h` for usage.
