# Next: mitigation hypotheses

**Out of scope for this repository.** This repo only *demonstrates* the scale-down-loses-work
failure (and the `warmjob` mode that avoids it). The ideas below are **not** implemented here; they
are recorded as candidates for follow-up work.

## Candidate mitigations

| Candidate | Idea | Trade-offs / notes |
| --- | --- | --- |
| **Graceful draining** | On SIGTERM, stop dequeuing and finish the in-flight job before exiting. | Bounded by ACA's 30s SIGTERM→SIGKILL window — only helps for jobs that can finish (or checkpoint) within 30s. |
| **Lease renewal** | Periodically extend the message visibility timeout while processing. | Keeps the message owned during long work; does not by itself prevent the replica being killed. |
| **Checkpoint / resume** | Persist progress so a retried job resumes instead of restarting. | Requires idempotent, resumable job design. Pairs well with retJ. |
| **Idempotency framework** | De-duplicate by jobId so re-processing after retry is safe. | Needed regardless, because queue delivery is at-least-once. |
| **Scaler tuning** | Use `queueLengthStrategy: all`, longer cooldown, `minReplicas` ≥ in-flight count, or a custom metric counting in-flight jobs. | Reduces premature scale-in but may over-provision. |
| **ACA Jobs migration** | Run each message as an ACA Job execution (event-driven). | **Rejected by this customer:** their ~3 GB image makes per-execution cold-start exceed their 30s tolerance. |
| **Service Bus migration** | Use Service Bus sessions/locks with auto-renew. | Larger change; better long-running semantics than Storage Queue. |
| **Durable Functions / orchestrator** | Externalize long-running orchestration. | Largest change; revisit only if simpler fixes fail. |

## Recommended sequence (after repro)

1. Add **idempotency** (jobId de-dup) — required for any at-least-once queue.
2. Add **graceful draining** + **lease renewal** for jobs short enough to finish in the shutdown
   window.
3. Add **checkpoint/resume** for long jobs that cannot finish within 30s.
4. Re-tune the **scaler** to avoid removing replicas with in-flight work.
5. Only then evaluate larger architectural moves (Service Bus / orchestrator), keeping the ~3 GB
   warm-image constraint front of mind.
