# Go thread/goroutine dump analysis during a peak thread-count event

**Date:** 2026-08-02
**Cluster:** fips-mode-5c8hc
**Environment:** stock kube-apiserver on stock kernel (post-baseline-collection state), doubled
m6i.4xlarge control plane, 2,900-pod workload.

## Method

Standard non-destructive Go `net/http/pprof` debug endpoints, captured from a *specific* master
(not round-robined through the API load balancer) by authenticating directly against
`https://localhost:6443` from inside a `chroot /host` session on that node, using the existing
admin kubeconfig's client certificate (no new credentials minted).

A monitor script (`threaddump_monitor.sh`, launched via `systemd-run` on all 3 masters) polled each
node's own `go_threads` value from its local `/metrics` endpoint every 3s, tracked a rolling
per-node minimum, and fired capture requests the instant a node's thread count exceeded
min+300 (delta-above-baseline, same convention as `run_rounds.sh`):

- `/debug/pprof/threadcreate?debug=2` — cumulative stack traces at every OS-thread-creation site
  since process start
- `/debug/pprof/goroutine?debug=1` — all goroutines grouped by identical stack, symbolized, with counts
- `/debug/pprof/goroutine?debug=2` — every goroutine individually, with runtime state annotation
  (`[select]`, `[syscall]`, `[chan receive]`, etc.)

A restart round was triggered via `forceRedeploymentReason`. Master `ip-10-0-86-117` hit a real
spike (1017 threads vs. a 28-thread rolling minimum, delta=989) shortly after its pod restarted.

## Timing caveat (important)

The `goroutine?debug=1` capture took ~2.6s and returned 196,195 total goroutines — captured near
the actual peak. The `goroutine?debug=2` capture, fired immediately after, took **76 seconds** to
complete (`runtime.Stack(all=true)` triggers a stop-the-world pause proportional to goroutine
count, plus the storm itself was consuming all available capacity) and by the time it returned,
the goroutine population had already collapsed to 10,781 — the storm had resolved. **This means
the full per-goroutine state dump reflects the immediate aftermath, not the literal peak
instant.** This is a real limitation of Go's own debug=2 endpoint under this kind of load, not a
bug in the capture script.

Raw files (in `threaddumps/` alongside this doc):
- `threadcreate_ip-10-0-86-117_delta989.txt`
- `goroutine_grouped_ip-10-0-86-117.txt` (196,195 goroutines, near-peak)
- `goroutine_full_ip-10-0-86-117.txt` (10,781 goroutines, ~76s after trigger, post-storm)

## Finding 1: the goroutine explosion is watch-serving infrastructure, not application logic

Of 196,195 total goroutines captured near-peak, **95.4% (187,115) are directly watch-related**:

| Count | % | Stack |
|---:|---:|---|
| 93,993 | 47.9% | `k8s.io/apiserver/pkg/storage/cacher.(*cacheWatcher).process` / `.processInterval` — per-watch dispatch loop pushing cached events to a client |
| 93,122 | 47.5% | `k8s.io/apiserver/pkg/endpoints/handlers.(*WatchServer).HandleHTTP` — per-connection HTTP handler blocked serving a watch stream to a client |

These come in matched pairs (one dispatch goroutine + one HTTP-handler goroutine per active watch
connection), meaning **roughly 93,000 concurrent watch connections were open on this one master**
at the moment of the spike — this directly confirms the "kubelet watch spam" thundering-herd
mechanism this test harness is built to reproduce.

The remaining ~4.6% (~9,080 goroutines) breaks down into supporting infrastructure, all
consistent with normal (if elevated-volume) apiserver operation:

| Count | Component |
|---:|---|
| 876 + 352 | gRPC client transport (reader/loopyWriter/keepalive) for the etcd client connection(s) |
| 730 | Variant watch-serving path (nested `ListResource` handler) |
| 663 | gRPC `newHTTP2Client` / controlBuffer machinery (etcd client) |
| 520 + 356 | gRPC client keepalive |
| 469 | Generic `context.propagateCancel` |
| 352 | HTTP/2 server connection serving (`net/http` + `golang.org/x/net/http2`) |
| 254 | `client-go` `Reflector.watch`/`startResync` — apiserver's own internal informers |
| 216 + 216 | `k8s.io/apiserver/pkg/storage/etcd3.(*watchChan)` — the apiserver's etcd-side watch (feeds the shared watch cache) |

None of these resolved stacks show TLS handshake, `crypto/rand`, cgo, or DRBG-related frames —
the handful of `crypto/tls.(*Conn).Read` frames present are blocked reads on an
**already-established** connection (idle keepalive), not active handshakes.

## Finding 2: OS-thread creation is scheduler-internal, not attributable to application code

The `threadcreate` profile (cumulative since process start) shows:

```
threadcreate profile: total 536
535 @ 0x0 0x0 0x0 ... (all-zero stack — unattributed)
1   @ runtime.allocm -> runtime.newm -> runtime.startTemplateThread -> runtime.main (startup thread)
```

**535 of 536 OS threads ever created by this process had no attributable Go-level call stack.**
This is the signature of Go's scheduler creating replacement M's (OS threads) via its own internal
`sysmon`/`retake`/`startm` machinery — which happens when a P has been detected blocked in a
syscall (including a cgo call) for too long, or when many goroutines become runnable at once and
idle M's must be spun up to run them — rather than threads created directly by identifiable
application code (e.g. an explicit `os/exec` call, which *would* show a normal stack here).

## Synthesis

Combining both findings: the watch-reconnect storm (~93K simultaneous client watches) is the
trigger, and the resulting OS-thread growth is scheduler-driven, not directly attributable in this
capture to a specific blocking call. This capture did **not** directly catch a goroutine mid-TLS-handshake
or mid-`RAND_bytes` — by the time the (slow) full dump returned, that transient window had passed.
This does **not** rule out the crypto/DRBG-contention hypothesis from earlier bpftrace work in this
investigation (which *did* directly observe OS threads blocked inside libcrypto via uprobes) — it's
consistent with it, since a burst of ~93K new watch connections would each require a fresh TLS
handshake (hence a fresh `RAND_bytes` call), but this particular tool (Go's own pprof) is not
well-suited to catching that specific transient window because generating the full dump is itself
slow under load and only fired once above threshold.

## Suggested follow-up (not yet done)

- Repeat capture using **only** `goroutine?debug=1`/`threadcreate?debug=2` (both fast, ~seconds)
  in a tight repeated loop through the whole spike window, instead of one-shot `debug=2`, to avoid
  the slow-dump timing miss.
- Re-run the bpftrace RAND_bytes/blocked-call-stack probes (already proven to work earlier this
  session) concurrently with a restart round, now that the cluster is stable post-baseline, to get
  the direct crypto-level evidence this capture didn't catch.
