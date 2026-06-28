# Reproduction guide

This walks through running the two deployment profiles and determining whether the scale-down
failure reproduced.

## The question we are answering

> Did a job **start** and then **fail to complete** because its replica was terminated during a
> scale-in / revision change?

The worker only deletes a queue message **after** it has durably recorded `Completed`. So if a
replica is killed mid-job:

- Table Storage shows `Started`/`Progress` but no `Completed`.
- The queue message becomes visible again (after the visibility timeout) and is re-processed,
  so `AttemptNumber` / dequeueCount climbs.
- ACA system logs show a SIGTERM / scale-in / replica termination in the same window.

## Profiles

| Profile | minReplicas | maxReplicas | queueLength | strategy | Intent |
| --- | --- | --- | --- | --- | --- |
| **A — control** | 1 | 1 | 1 | `all` | Conservative; jobs should all complete. |
| **B — failure** | 0 | 5 | 1 | `visibleonly` | Scale to many replicas, then let queue depth drop while long jobs are still running so replicas are scaled in. |

The scale settings are applied by re-provisioning (`azd provision`) with different parameters.
`scripts/run-repro.ps1` does this for you.

## Run Profile A (baseline)

```pwsh
./scripts/run-repro.ps1 -Profile A -Batch "10x300"
```

Wait for the jobs (~5 min each) to finish, then:

```pwsh
./scripts/collect-evidence.ps1
```

Expected: `started == completed`, no started-but-incomplete jobs.

## Run Profile B (failure)

```pwsh
./scripts/run-repro.ps1 -Profile B
```

This applies the aggressive scaling profile and enqueues a burst of long jobs
(`10x900,10x1500` by default). The intended dynamic:

1. Queue depth spikes → KEDA scales the app out to several replicas.
2. Each replica dequeues a long job (15–25 min) and makes the message invisible.
3. With `queueLengthStrategy: visibleonly`, the **visible** queue depth quickly drops to ~0
   because in-flight messages are invisible.
4. KEDA sees low/zero visible depth and scales replicas back in — **while jobs are still
   running** — sending SIGTERM and then SIGKILL after 30s.
5. Killed jobs never record `Completed`; their messages reappear and are retried.

Watch replica counts while it runs:

```pwsh
$rg = (azd env get-values | Select-String AZURE_RESOURCE_GROUP).ToString().Split('=')[1].Trim('"')
$app = (azd env get-values | Select-String WORKER_RESOURCE_NAME).ToString().Split('=')[1].Trim('"')
az containerapp replica list -g $rg -n $app -o table
```

After ~20–30 minutes:

```pwsh
./scripts/collect-evidence.ps1 -LookbackMinutes 90
```

## Determining the outcome

**Failure reproduced** if all of these hold (see `docs/results.md` to record them):

- At least one job logged `JobStarted` but never `JobCompleted`.
- Table state shows `Started`/`Progress` without `Completed` for that job.
- System logs show SIGTERM / scale-in / replica termination in the same window.
- `AttemptNumber` > 1 for the affected job (message was retried).

**Failure not reproduced** if every started job has a `Completed` record. Then iterate: increase
job durations, increase `maxReplicas`, enqueue larger bursts, or confirm `visibleonly` is taking
effect. Record what you tried in `docs/observations.md`.

## Useful Kusto queries (Log Analytics)

Worker application logs are in `ContainerAppConsoleLogs_CL`; platform logs in
`ContainerAppSystemLogs_CL`.

**Started jobs without completion:**

```kusto
let started =
    ContainerAppConsoleLogs_CL
    | where Log_s has 'JobStarted'
    | extend job = extract(@'job=(\S+)', 1, Log_s)
    | distinct job;
let completed =
    ContainerAppConsoleLogs_CL
    | where Log_s has 'JobCompleted'
    | extend job = extract(@'job=(\S+)', 1, Log_s)
    | distinct job;
started
| join kind=leftanti completed on job
| project job
```

**Shutdown signals received by the worker:**

```kusto
ContainerAppConsoleLogs_CL
| where Log_s has 'Shutdown signal received' or Log_s has 'JobInterrupted'
| project TimeGenerated, RevisionName_s, ReplicaName_s, Log_s
| order by TimeGenerated desc
```

**KEDA scale decisions:**

```kusto
ContainerAppSystemLogs_CL
| where EventSource_s == 'KEDA'
| project TimeGenerated, Reason_s, Log_s
| order by TimeGenerated desc
```

**Replica lifecycle / termination events:**

```kusto
ContainerAppSystemLogs_CL
| where Reason_s in ('ScalingReplica','KillingReplica','StoppingReplica') or Log_s has 'SIGTERM'
| project TimeGenerated, RevisionName_s, ReplicaName_s, Reason_s, Log_s
| order by TimeGenerated desc
```

**Job duration distribution (completed jobs):**

```kusto
ContainerAppConsoleLogs_CL
| where Log_s has 'JobCompleted'
| extend duration = toint(extract(@'duration=(\d+)s', 1, Log_s))
| summarize count() by bin(duration, 300)
```

**Duplicate processing (same job started on >1 replica or >1 attempt):**

```kusto
ContainerAppConsoleLogs_CL
| where Log_s has 'JobStarted'
| extend job = extract(@'job=(\S+)', 1, Log_s), replica = extract(@'replica=(\S+)', 1, Log_s)
| summarize starts = count(), replicas = dcount(replica) by job
| where starts > 1 or replicas > 1
```

## Cleanup

```pwsh
./scripts/cleanup.ps1 -Purge
```
