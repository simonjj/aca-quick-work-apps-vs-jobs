# Results

Record the conclusion of the reproduction here once you have run it. This file maps directly to
the success criteria in `instructions.md` §8.

## Outcome

> Status: **TBD** — fill in after running the repro.

Select one:

- [ ] **Success Case 1 — Failure reproduced**
- [ ] **Success Case 2 — Failure not reproduced, but ruled out clearly**

## Success Case 1 evidence checklist

Fill in the specifics (job ids, replica names, timestamps) from `collect-evidence.ps1` and the
Kusto queries in `repro.md`.

- [ ] At least one queue message processed by a worker replica — job id(s): ____
- [ ] Worker logged `JobStarted` for that job — replica: ____
- [ ] Job did **not** log `JobCompleted`.
- [ ] Durable state shows `Started`/`Progress` but no `Completed`.
- [ ] Worker received shutdown / disappeared during the job window — evidence: ____
- [ ] ACA/KEDA/system logs show scale-in / replica termination / revision deactivation in the
      same window — evidence: ____
- [ ] Exact deployment settings + batch that caused it:
  - minReplicas / maxReplicas / queueLength / queueLengthStrategy: ____
  - batch: ____
  - image mode: lightweight | ~3 GB

## Success Case 2 evidence checklist (if not reproduced)

- [ ] All configurations tested (link rows in `observations.md`).
- [ ] Batch sizes and job durations tested: ____
- [ ] Replica counts observed: ____
- [ ] Queue visibility / dequeue behavior observed: ____
- [ ] Evidence that every started job completed (started == completed): ____
- [ ] Explanation of why premature termination did not occur: ____
- [ ] Recommended next experiments: ____

## Summary

<!-- 2–4 sentences: what happened, under what settings, and the key evidence. -->
