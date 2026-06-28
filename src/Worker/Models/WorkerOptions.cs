namespace AcaQueueRepro.Worker.Models;

/// <summary>
/// Strongly-typed configuration for the worker, bound from environment variables / appsettings.
/// </summary>
public sealed class WorkerOptions
{
    /// <summary>Azure Storage connection string used for queue + table access.</summary>
    public string StorageConnectionString { get; set; } = string.Empty;

    /// <summary>Name of the queue to poll for job messages.</summary>
    public string QueueName { get; set; } = "jobs";

    /// <summary>Azure Table used to persist durable job state.</summary>
    public string StateTableName { get; set; } = "jobstate";

    /// <summary>How long a received message stays invisible while being processed.</summary>
    public int VisibilityTimeoutSeconds { get; set; } = 1800;

    /// <summary>Delay between empty-queue polls.</summary>
    public int PollIntervalSeconds { get; set; } = 5;

    /// <summary>How often to emit/persist progress while a job runs.</summary>
    public int ProgressIntervalSeconds { get; set; } = 30;

    /// <summary>
    /// Max seconds the host waits for in-flight work to drain on SIGTERM before the process exits.
    /// Should align with the platform's terminationGracePeriodSeconds (customer-confirmed: 600) so
    /// the worker doesn't self-abandon work the platform would still have allowed to finish.
    /// </summary>
    public int ShutdownTimeoutSeconds { get; set; } = 600;

    /// <summary>
    /// How many messages to receive per poll. Defaults to 1 so each replica processes one
    /// long-running job at a time, matching the customer scenario.
    /// </summary>
    public int MessagesPerPoll { get; set; } = 1;

    /// <summary>
    /// Execution model:
    ///   "loop" (default) — long-running Container App replica: poll forever (App deployment).
    ///   "once"           — event-driven Container Apps Job execution: process exactly one
    ///                      message, then exit 0 so the Job execution completes.
    ///   "drain"          — warm Container Apps Job execution: poll forever like "loop" so the
    ///                      execution sits warm and processes messages with no per-message cold
    ///                      pull, BUT stop pulling new work and exit 0 cleanly before the job's
    ///                      replicaTimeout (activeDeadlineSeconds) fires, so a fresh execution
    ///                      rolls over without a mid-message SIGKILL. Combines the App's warm
    ///                      pickup with the Job's run-to-completion guarantee.
    /// One image supports all three deployment options; the platform deployment mode sets this.
    /// </summary>
    public string RunMode { get; set; } = "loop";

    /// <summary>
    /// In "once" mode, how many consecutive empty polls to tolerate before exiting. KEDA may start
    /// slightly more executions than there are messages; an execution that finds nothing exits
    /// cleanly instead of hanging.
    /// </summary>
    public int EmptyPollsBeforeExit { get; set; } = 3;

    /// <summary>
    /// "drain" mode only: the job's replicaTimeout (activeDeadlineSeconds), in seconds. The worker
    /// computes its hard deadline as process-start + this value and stops pulling new messages once
    /// it is within <see cref="DrainSafetyMarginSeconds"/> of it, then exits 0 to roll over. 0
    /// disables deadline-aware draining (the execution then relies solely on the platform deadline
    /// and may be SIGKILLed mid-message — not recommended for warm jobs).
    /// </summary>
    public int ReplicaDeadlineSeconds { get; set; } = 0;

    /// <summary>
    /// "drain" mode only: how many seconds before the replicaTimeout deadline to stop accepting new
    /// messages. Because the deadline is anchored at in-container process start while the platform's
    /// replicaTimeout clock starts earlier (at execution/pod creation, ahead by the cold-start
    /// delta: 3 GB pull + scheduling, measured here at ~47.5 s and up to ~120-162 s under capacity
    /// pressure), this margin must exceed the worst-case cold-start delta — otherwise the worker's
    /// computed deadline can land *after* the real platform deadline and a job gets SIGKILLed
    /// mid-flight. (The per-message hand-back plus <see cref="DrainCleanupBufferSeconds"/> separately
    /// guarantees an accepted job can finish before the deadline, so this margin covers cold-start
    /// drift, not job duration.) Default 300 s to comfortably clear the observed worst case.
    /// </summary>
    public int DrainSafetyMarginSeconds { get; set; } = 300;

    /// <summary>
    /// "drain" mode only: deterministic per-execution spread (seconds) subtracted from the drain
    /// deadline, derived from the execution name, so floor executions started together do NOT all
    /// roll over at the same instant (which would briefly drop the warm floor to zero during the
    /// replacement image pulls). 0 disables staggering.
    /// </summary>
    public int DrainStaggerSeconds { get; set; } = 0;

    /// <summary>
    /// "drain" mode only: extra slack (seconds) added when deciding whether a freshly-received
    /// message can finish before the drain deadline. If now + job duration + this buffer would
    /// exceed the deadline, the worker hands the message back (makes it immediately visible) for
    /// another warm execution and rolls over, rather than starting work it cannot finish in time.
    /// </summary>
    public int DrainCleanupBufferSeconds { get; set; } = 10;
}
