# Benchmark: App-replicas-as-queue-workers vs. ACA Jobs (≈3 GB image)

Cold-start phase timing for the deployment options of this template, measured on a real
deployment in **Sweden Central** with the customer-aligned configuration (the `flexjob` lane was
measured separately in **South Central US** — see its section below). The same worker image is
used for all — run in `loop` mode for the App, `once` mode for the event Job and Flex Job, and
`drain` mode for the warm Job — padded to the customer's real image size.

| | |
|---|---|
| Region | `swedencentral` |
| App resource group | `apps-as-jobs-APPS` (Container App `ca-worker-…`, KEDA azure-queue, min=2/max=15) |
| Job resource group | `apps-as-jobs-JOBS` (Container Apps **Job**, event trigger, replicaTimeout=3600) |
| Warm-Job resource group | `apps-as-jobs-WARMJOB` (Container Apps **Job**, event trigger, `minExecutions=2`, `replicaTimeout=3600`, worker `drain` mode) |
| Image | **3,302,838,059 bytes = 3.30 GB (3.08 GiB)** — confirmed via kubelet `ImagePulled` log |
| Scaler (both) | `azure-queue`, `queueLength=1`, `queueLengthStrategy=all`, `pollingInterval=30s` |
| Work simulated | 180 s per message |
| Telemetry | Azure Monitor / Log Analytics — `ContainerAppSystemLogs_CL` (kubelet phase events) + `ContainerAppConsoleLogs_CL` (worker logs) |

> The regional ACA Kusto cluster was not reachable from the test network, so all platform timing
> was taken from the per-environment Log Analytics workspaces, which carry the same kubelet phase
> events (`AssigningReplica`,
> `PullingImage`, `ImagePulled`, `ContainerCreated`, `ContainerStarted`, `ContainerAppReady`).
> The `ImagePulled` message itself reports the exact pull duration, so the headline pull number
> is kubelet-authoritative (no log-ingestion jitter).

---

## Headline result

**The 3 GB image pulls in ~45–52 s on a cold node — and that cost is essentially identical for
Apps and Jobs.** The App's real advantage is **not pulling faster; it is *not pulling at all*** on
warm replicas and warm nodes:

| Path | "message in queue → worker processing it" |
|---|---|
| **App — pre-warmed `min=2` replica** | **1–3 seconds** (no scheduling, no pull, no container start) |
| App — scale-out replica on a **warm node** (image cached) | 22–52 s (≈0 s pull) |
| App — scale-out replica on a **cold node** (full 3 GB pull) | ~168 s¹ |
| **Job — every execution (always cold)** | **~92 s** |
| **Warm-Job — pickup on the warm `minExecutions=2` floor** | **1.8–4.2 seconds** (real worker already polling, image cached on-node) |
| Warm-Job — burst above the floor, **warm node** (image cached) | 2–5 s (≈0.1 s pull) |
| Warm-Job — burst above the floor, **cold node** (full 3 GB pull) | ~46–49 s (47.5 s pull); up to ~120–162 s under capacity pressure |
| **Flex-Job — first execution on a cold Flex node** (full 3 GB pull) | **~85 s** (~52 s pull) |
| **Flex-Job — execution on a warm Flex node** (image cached) | **~18 seconds** (0.1 s pull; Flex nodes never scale to zero, so the image persists) |

¹ Includes queue-wait behind the pre-warmed replicas, which had already drained the early messages.

This is exactly why the customer chose Apps: with warm `min=2` replicas, short/bursty work starts in
**single-digit seconds**, never paying the ~50 s pull. A Job pays the full cold start — dominated by
the ~52 s 3 GB pull — on **every** execution.

---

## 3 GB image pull time (`PullingImage` → `ImagePulled`, kubelet-reported)

| Deployment | Samples | Min | Avg | Max |
|---|---|---|---|---|
| **App — cold node** | 9 | 44.4 s | **46.6 s** | 49.9 s |
| **App — warm node (cached)** | 7 | — | **~0 s** ("already present") | — |
| **Job — every execution** | 6 | 50.5 s | **51.6 s** | 52.8 s |

- Cold-pull times are within noise of each other (same ACR, same region, same image). The Job
  average is slightly higher because all 6 executions pulled **simultaneously** (shared egress).
- **7 of 16** App replicas in the scale-out landed on nodes that had already cached the image and
  pulled in **~0 s**. No Job execution benefited from caching in this run — each got a fresh pod.

---

## Full phase breakdown (cold path)

Representative cold Job execution (`…-gj2ds`) vs. cold App scale-out replica (`…-7g2kw`).
Enqueue → completion. Times from `ContainerAppSystemLogs_CL` (second precision) and the kubelet
pull message (ms precision).

| # | Phase | Source | **Job (cold)** | **App (cold scale-out)** |
|---|---|---|---|---|
| 1 | queue lands → workload dispatch | enqueue → `AssigningReplica` | ~20 s (gated by 30 s KEDA poll) | ~30 s (poll + scale decision)² |
| 2 | dispatch → compute node ready | `AssigningReplica` → node/sidecar up | ~1 s | ~1 s |
| 3 | node ready → image pull start | → `PullingImage` | ~17 s (sidecar/init prep) | ~1–17 s |
| 4 | **image pull start → pull complete (3 GB)** | `PullingImage` → `ImagePulled` | **51.6 s** | **46.6 s** |
| 5 | pull complete → workload running | `ImagePulled` → `ContainerStarted` → `WorkerReady` | ~2–3 s (.NET init 1.15 s) | ~2–3 s |
| 6 | workload running → workload complete | `WorkerReady` → `JobCompleted` | 180 s (simulated work) | 180 s (simulated work) |
| | **Enqueue → worker processing** | `queueLatencyMs` | **~92 s** | ~168 s² / **1–3 s warm** |

² App scale-out in the test sub was additionally throttled by subscription capacity
(`AssigningReplicaFailed`, `Preempted`, `TriggeredScaleUp`), inflating the cold-node wait. The
**pull** phase (#4) is the clean, capacity-independent number.

- **Worker process init** (`ProcessUptimeMs`, container start → worker ready to poll) was
  **~1.0–1.3 s** for both — negligible next to the 3 GB pull.
- Job execution end-to-end: enqueue ~15:47:33 → execution end 15:52:15 (≈ 282 s, of which 180 s is
  the simulated work and ~52 s is the pull).

---

## Interpretation

1. **Cold start is dominated by the 3 GB pull (~50 s), not by scheduling or app init.** Scheduling
   is ~20–30 s (mostly the 30 s KEDA polling interval) and worker init is ~1 s.

2. **Apps win by avoiding the pull, not by pulling faster.** Pre-warmed `min=2` replicas process
   the first messages in **1–3 s**, and warm-node scale-out skips the pull (~0 s). This validates
   the customer's "Apps because a 3 GB cold start blows our 30 s budget" rationale **for short,
   latency-sensitive, bursty work**.

3. **For long jobs the calculus flips.** A ~52 s pull is <2 % overhead on a 60-minute job. There the
   App's lack of a per-replica lifetime guarantee (KEDA/HPA is level-triggered and can SIGTERM a
   replica mid-job on scale-in) outweighs the cold-start saving, and an ACA **Job**
   (`replicaTimeout=3600`, never scaled-in while running) is the safer construct. See
   `next-fix-hypotheses.md`.

4. **Node image caching is real but non-deterministic.** It made 7/16 App scale-out replicas start
   instantly here, but it cannot be relied on (depends on node placement). Jobs got no caching
   benefit in this run.

---

## Warm-Job lane (`warmjob` mode)

The `warmjob` deployment mode is an ACA **event-driven Job** with `minExecutions=2` and a worker
running in **`drain`** mode (poll-loop that stops accepting new work `DrainSafetyMarginSeconds`
before `replicaTimeout` and exits 0 so a fresh execution rolls over). The goal: get the App's
**warm single-digit-second pickup** while keeping the Job **run-to-completion guarantee** (a running
Job execution is never scaled-in mid-work, unlike an App replica).

Measured on `apps-as-jobs-WARMJOB` (swedencentral, same 3.30 GB image):

| Scenario | message → worker processing | Pull phase |
|---|---|---|
| **Warm pickup** — steady-state `minExecutions=2` floor, worker already polling, image cached on-node | **1.8 s & 4.2 s** (2 samples) | none (already running) |
| Burst above floor, lands on a **warm node** (image cached) | 2–5 s | ~0.1 s ("already present") |
| Burst above floor, lands on a **cold node** | ~46–49 s | **47.5 s** (full 3 GB) |
| Burst above floor, cold node **+ capacity pressure** (`AssigningReplicaFailed`) | ~120–162 s | 47.5 s + node provisioning |

**Two findings that matter:**

1. **`minExecutions` does provide a real warm floor.** With an *empty* queue, exactly 2 executions
   stayed in `Running` and idle-polling across repeated checks — **unlike a vanilla KEDA ScaledJob,
   which creates zero jobs when the queue is empty.** ACA maps `minExecutions` → KEDA
   `MinReplicaCount`, which keeps the floor alive. This is what makes warm pickup possible at all.

2. **Burst *above* the floor is still cold — identical to the plain `jobs` lane.** The warm floor
   only covers steady-state load equal to `minExecutions`. Any message beyond that spins up a new
   execution that pays the full ~47.5 s 3 GB pull on a cold node (or ~0.1 s if it happens to land on
   a node that already cached the image). So `warmjob` **does not** fix burst cold-start — it only
   removes it for the warm-floor portion of the load. To shrink burst cold-start you still need a
   smaller image, node-level image caching, or a larger `minExecutions` floor.

### ⚠️ Deployment caveat — placeholder floor on first `azd up`

`azd` provisions the Job with a **placeholder image** (the ACA `quickstart` "Listening on :80…"
container) and only swaps in the real worker image during `azd deploy`. But `minExecutions=2`
launches its two floor executions **at provision time, against the placeholder**, and ACA does
**not** restart already-running executions when the image is updated — they linger until
`replicaTimeout` (up to 1 h). The result: immediately after `azd up` the "warm floor" is two
placeholder containers that never poll the queue, so the **first** burst is served entirely by
cold, freshly-spawned real-worker executions (this is exactly what produced a 92 s first-pickup
before the floor was corrected).

**Fix for a clean warm floor:** after the real image is live, stop the stale placeholder
executions so KEDA respawns the floor on the real worker image:

```pwsh
az containerapp job execution list -g apps-as-jobs-WARMJOB -n <job> \
  --query "[?properties.status=='Running'].name" -o tsv |
  ForEach-Object { az containerapp job stop -g apps-as-jobs-WARMJOB -n <job> --job-execution-name $_ }
# then confirm the new floor logs the real worker ("QueuePolling"/JobReceived), not "Listening on :80"
```

A drain-mode execution does **not** idle-exit, so once the floor is the real worker it stays warm
until `replicaTimeout` rollover.

---

## Flex-Job lane (`flexjob` mode)

The `flexjob` deployment mode is the **same** event-driven ACA **Job** as the `jobs` lane (`once`
worker, one execution per message, `minExecutions=0` so it scales from zero) — the only difference
is that it runs on a **Flex workload profile** instead of the default Consumption pool. Flex
profiles are single-tenant and **do not scale their node pool to zero**, so once a node has pulled
the ~3 GB image it stays warm and the image remains cached on-node.

Measured on `apps-as-jobs-FLEXJOB` (**southcentralus**, sub `Private Test Sub ACAPMS`), Job
`cj-worker-…` on `workloadProfileName=flex` (`workloadProfileType: Flex`, 0.5 CPU / 2 GiB — Flex
requires fixed CPU/memory combos, so the template snaps the default `0.5/1Gi` to `0.5/2Gi`), same
3.30 GB image (`3,303,756,238 bytes`), `queueLength=1`, `pollingInterval=30s`.

> **Region caveat.** This lane was measured in **South Central US**, while the App/Jobs/Warm-Job
> lanes were measured in Sweden Central. Cold-pull time is region/ACR-dependent, so treat the
> cross-lane comparison as directional. The **within-lane** cold-vs-warm delta below is
> same-region, same-ACR, same-image and is the meaningful result.

Two bursts were driven at the same Flex Job, back-to-back:

| Scenario | message → worker processing | 3 GB pull (kubelet) |
|---|---|---|
| **Burst 1 — cold Flex nodes** (first pull), 6 executions | **84–87 s** | 50.9, 51.5, 52.4, 53.0, 53.4, 53.7 s (**avg ~52.5 s**) |
| **Burst 2 — warm Flex nodes** (image cached), 6 executions ~2 min later | **~18 s** (17.9–18.1 s) | 113, 116, 117, 140, 140, 142 **ms** ("already present") |

**Three findings that matter:**

1. **The first pull is fully cold — identical to the plain `jobs` lane.** On a freshly-provisioned
   Flex node the 3 GB image pulls in ~52 s, and end-to-end pickup is ~85 s. Flex gives **no**
   cold-start advantage on the very first execution per node.

2. **Flex converts the per-execution pull into a one-time warm-up.** Because Flex nodes don't scale
   to zero, the node and its cached image persist between bursts. The second burst — landing on the
   now-warm nodes — pulled in **~0.1 s** and picked up work in **~18 s**. So unlike the Consumption
   `jobs` lane (where each execution tends to get a fresh pod on a cold node and pays the full ~52 s
   pull *every* time), Flex pays the pull **once** and every later execution skips it.

3. **Flex is not an App-style warm floor.** The residual **~18 s** warm pickup is KEDA polling +
   pod scheduling + the init `metadata-check` container + .NET init — **not** image pull. A fresh
   pod is still scheduled per message; there is no always-running replica already polling the queue.
   So Flex removes the **image-pull** portion of cold start (~52 s → ~0.1 s) but keeps the
   **pod-scheduling** portion. It lands *between* the plain Job (~92 s every time) and the
   App/Warm-Job warm floor (1.8–4.2 s), while retaining the Job's run-to-completion guarantee (a
   running execution is never scaled-in mid-work).

**When to reach for `flexjob`:** steady or recurring queue load where you want the Job
run-to-completion guarantee and can tolerate ~18 s pickup, and where a persistent (never-scale-to-
zero) node pool is acceptable — it removes the repeated 3 GB pull tax without the drain-mode
complexity of `warmjob`. For the lowest possible pickup on bursty, latency-sensitive work, the App
or Warm-Job floor is still faster.

---

## How to reproduce

```pwsh
# App variant (default)
azd env new apps   --location swedencentral
azd env set DEPLOYMENT_MODE app              -e apps
azd env set AZURE_RESOURCE_GROUP_NAME apps-as-jobs-APPS -e apps
azd up -e apps

# Job variant
azd env new jobs   --location swedencentral
azd env set DEPLOYMENT_MODE jobs             -e jobs
azd env set AZURE_RESOURCE_GROUP_NAME apps-as-jobs-JOBS -e jobs
azd up -e jobs

# Warm-Job variant (event Job kept warm via minExecutions, drain-mode worker)
azd env new warmjob --location swedencentral
azd env set DEPLOYMENT_MODE warmjob          -e warmjob
azd env set AZURE_RESOURCE_GROUP_NAME apps-as-jobs-WARMJOB -e warmjob
azd env set WARM_JOB_MIN_EXECUTIONS 2        -e warmjob
azd up -e warmjob
# IMPORTANT: after the real 3 GB image is live, stop the placeholder floor executions so the
# warm floor respawns on the real worker image (see "Deployment caveat" above).

# Flex-Job variant (same event Job, scheduled on a Flex workload profile).
# Flex is region-specific; confirm availability first:
#   az containerapp env workload-profile list-supported --location southcentralus -o table
azd env new flexjob --location southcentralus
azd env set DEPLOYMENT_MODE flexjob          -e flexjob
azd env set AZURE_RESOURCE_GROUP_NAME apps-as-jobs-FLEXJOB -e flexjob
azd up -e flexjob
# The Flex cold-vs-warm effect shows across two back-to-back bursts: the first pays the ~52 s pull
# on cold nodes; the second (nodes now warm, image cached) pulls in ~0.1 s. Flex nodes do not scale
# to zero, so the image persists between bursts.

# Build the real 3 GB image server-side in ACR (avoids a slow/flaky 3 GB local push),
# then point the resource at it:
az acr build -r <acr> -t aca-quick-work-apps-vs-jobs/worker:bench3gb \
    --platform linux/amd64 --build-arg IMAGE_PADDING_GB=3 -f Dockerfile.benchmark .
az containerapp     update -g apps-as-jobs-APPS -n <app> --image <acr>/…:bench3gb   # App
az containerapp job update -g apps-as-jobs-JOBS -n <job> --image <acr>/…:bench3gb   # Job
az containerapp job update -g apps-as-jobs-FLEXJOB -n <job> --image <acr>/…:bench3gb # Flex Job

# Drive load, then harvest phase timings from Log Analytics:
dotnet run --project src/Enqueuer -- --connection <cs> --queue jobs --batch "18x180"
#   ContainerAppSystemLogs_CL | where Reason_s == 'ImagePulled'
#     | extend pullSec = toreal(extract('in ([0-9.]+)s', 1, Log_s))
```

> **Tip:** build the heavy image with `az acr build` (server-side). Pushing a 3 GB layer from a
> laptop through the Docker Desktop proxy is slow and prone to `broken pipe`. `Dockerfile.benchmark`
> is the amd64-native variant used for ACR builds (the classic ACR dependency scanner cannot parse
> the `--platform=$BUILDPLATFORM` directives in the cross-build `Dockerfile`).
