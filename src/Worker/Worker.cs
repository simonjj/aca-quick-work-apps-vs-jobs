using System.Diagnostics;
using System.Text.Json;
using AcaQueueRepro.Worker.Models;
using AcaQueueRepro.Worker.Services;
using Azure.Storage.Queues;
using Azure.Storage.Queues.Models;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace AcaQueueRepro.Worker;

/// <summary>
/// The queue-driven worker. Polls one message at a time, simulates a long-running job, emits and
/// persists progress, and only deletes the message after a successful completion. On shutdown
/// (SIGTERM from ACA scale-in / revision change) it records an Interrupted state and leaves the
/// message in the queue, which is the core evidence path for the reproduction.
///
/// RunMode "loop" (default) keeps polling forever — the long-running Container App replica model.
/// RunMode "once" processes a single message and exits 0 — the event-driven Container Apps Job
/// model. RunMode "drain" polls forever like "loop" (so a warm Job execution avoids the per-message
/// cold pull) but stops accepting new work and exits 0 cleanly shortly before the job's
/// replicaTimeout, so a fresh execution rolls over instead of the platform SIGKILLing a job
/// mid-message. The same image therefore powers all three deployment options of the template.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly QueueClient _queue;
    private readonly JobStateStore _stateStore;
    private readonly WorkerOptions _options;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly ILogger<Worker> _logger;

    private readonly bool _runOnce;
    private readonly bool _drain;

    private readonly string _replicaName =
        Environment.GetEnvironmentVariable("CONTAINER_APP_REPLICA_NAME")
        ?? Environment.GetEnvironmentVariable("CONTAINER_APP_JOB_EXECUTION_NAME")
        ?? Environment.MachineName;
    private readonly int _processId = Environment.ProcessId;

    public Worker(
        QueueClient queue,
        JobStateStore stateStore,
        IOptions<WorkerOptions> options,
        IHostApplicationLifetime lifetime,
        ILogger<Worker> logger)
    {
        _queue = queue;
        _stateStore = stateStore;
        _options = options.Value;
        _lifetime = lifetime;
        _logger = logger;
        _runOnce = string.Equals(_options.RunMode, "once", StringComparison.OrdinalIgnoreCase);
        _drain = string.Equals(_options.RunMode, "drain", StringComparison.OrdinalIgnoreCase);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Benchmark anchor: time from container/process start to the worker being ready to pull
        // its first message. Combined with the platform system logs this bounds the cold-start path.
        var modeLabel = _runOnce ? "once" : _drain ? "drain" : "loop";

        // "drain" mode: derive the hard rollover deadline and stop accepting new work
        // DrainSafetyMarginSeconds before it so the in-flight job can finish and the execution exits 0
        // (a replacement execution rolls over) instead of being SIGKILLed. A deterministic
        // per-execution stagger keeps floor executions from rolling over in lockstep.
        //
        // IMPORTANT: the deadline is anchored to the in-container process start, but the platform's
        // replicaTimeout (activeDeadlineSeconds) clock starts earlier, at execution/pod creation —
        // ahead of process start by the whole cold-start delta (3 GB image pull + scheduling, which
        // this repo measured at ~47.5 s and up to ~120-162 s under capacity pressure). So the
        // effective margin against the real SIGKILL is (margin + stagger - coldStartDelta), NOT
        // margin. DrainSafetyMarginSeconds must therefore exceed the worst-case cold-start delta
        // (the per-message hand-back + DrainCleanupBufferSeconds separately covers job duration).
        var drainDeadlineUtc = DateTime.MaxValue;
        if (_drain && _options.ReplicaDeadlineSeconds > 0)
        {
            var margin = Math.Max(0, _options.DrainSafetyMarginSeconds);
            var stagger = _options.DrainStaggerSeconds > 0
                ? (int)((uint)_replicaName.GetHashCode() % (uint)(_options.DrainStaggerSeconds + 1))
                : 0;
            var windowSeconds = _options.ReplicaDeadlineSeconds - margin - stagger;
            if (windowSeconds < 1)
            {
                // Misconfiguration: replicaTimeout <= margin + stagger. Clamping to a 1 s deadline
                // would make every execution roll over before pulling a single message — an infinite
                // re-pull/roll-over churn that processes zero work. Fail loud and disable
                // deadline-aware draining instead (the floor still processes work; it now relies on
                // the platform deadline, which is no worse than plain event Jobs).
                _logger.LogError(
                    "DrainMisconfigured ReplicaDeadlineSeconds={Deadline}s <= DrainSafetyMarginSeconds({Margin}s)+stagger({Stagger}s); " +
                    "deadline-aware draining DISABLED to avoid roll-over churn. Increase replicaTimeout or lower the margin so the usable window is positive.",
                    _options.ReplicaDeadlineSeconds, margin, stagger);
            }
            else
            {
                drainDeadlineUtc = Process.GetCurrentProcess().StartTime.ToUniversalTime()
                    .AddSeconds(windowSeconds);
            }
        }

        _logger.LogInformation(
            "WorkerReady RunMode={RunMode} Replica={Replica} Pid={Pid} Queue={Queue} VisibilityTimeout={Vis}s ProgressInterval={Prog}s DrainDeadlineUtc={Deadline:o} ProcessUptimeMs={Uptime:F0}",
            modeLabel, _replicaName, _processId, _options.QueueName,
            _options.VisibilityTimeoutSeconds, _options.ProgressIntervalSeconds,
            drainDeadlineUtc == DateTime.MaxValue ? (object)"none" : drainDeadlineUtc,
            (DateTime.UtcNow - Process.GetCurrentProcess().StartTime.ToUniversalTime()).TotalMilliseconds);

        var emptyPolls = 0;
        var errorPolls = 0;
        var drainDeadlineReached = false;

        while (!stoppingToken.IsCancellationRequested)
        {
            // Warm Job rollover: stop pulling new work once we are within the safety margin of the
            // replicaTimeout, finish nothing new, and exit cleanly so a fresh execution takes over.
            if (_drain && DateTime.UtcNow >= drainDeadlineUtc)
            {
                _logger.LogInformation(
                    "DrainDeadlineReached Replica={Replica} Pid={Pid} — within {Margin}s of replicaTimeout; stopping new pulls and exiting execution 0 for warm rollover.",
                    _replicaName, _processId, _options.DrainSafetyMarginSeconds);
                drainDeadlineReached = true;
                break;
            }

            QueueMessage? message = null;
            try
            {
                QueueMessage[] received = await _queue.ReceiveMessagesAsync(
                    maxMessages: _runOnce ? 1 : _options.MessagesPerPoll,
                    visibilityTimeout: TimeSpan.FromSeconds(_options.VisibilityTimeoutSeconds),
                    cancellationToken: stoppingToken);

                message = received.FirstOrDefault();
                errorPolls = 0;
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error receiving messages; backing off.");
                if (_runOnce && ++errorPolls >= Math.Max(1, _options.EmptyPollsBeforeExit))
                {
                    _logger.LogWarning(
                        "RunOnce: {Polls} consecutive receive errors; exiting execution to avoid hanging until replicaTimeout. Replica={Replica}",
                        errorPolls, _replicaName);
                    break;
                }

                await SafeDelay(TimeSpan.FromSeconds(_options.PollIntervalSeconds), stoppingToken);
                continue;
            }

            if (message is null)
            {
                if (_runOnce && ++emptyPolls >= Math.Max(1, _options.EmptyPollsBeforeExit))
                {
                    _logger.LogInformation(
                        "RunOnce: no message after {Polls} empty poll(s); exiting execution cleanly. Replica={Replica}",
                        emptyPolls, _replicaName);
                    break;
                }

                await SafeDelay(TimeSpan.FromSeconds(_options.PollIntervalSeconds), stoppingToken);
                continue;
            }

            emptyPolls = 0;

            // Warm Job near rollover: if this message's job cannot finish before the drain deadline,
            // hand it straight back (make it visible again) for another warm execution and roll over,
            // instead of starting work that the replicaTimeout would SIGKILL mid-flight.
            if (_drain && drainDeadlineUtc != DateTime.MaxValue)
            {
                var peek = TryParse(message);
                var estDuration = peek is null ? 0 : Math.Max(peek.DurationSeconds, 0);
                var estEnd = DateTime.UtcNow.AddSeconds(estDuration + Math.Max(0, _options.DrainCleanupBufferSeconds));
                if (estEnd > drainDeadlineUtc)
                {
                    _logger.LogInformation(
                        "DrainHandBack job={JobId} message={MessageId} replica={Replica} — {Dur}s job cannot finish before deadline; returning to queue and rolling over.",
                        peek?.JobId ?? "?", message.MessageId, _replicaName, estDuration);
                    try
                    {
                        await _queue.UpdateMessageAsync(
                            message.MessageId, message.PopReceipt, visibilityTimeout: TimeSpan.Zero,
                            cancellationToken: CancellationToken.None);
                    }
                    catch (Exception ex)
                    {
                        _logger.LogWarning(ex, "DrainHandBack: failed to reset visibility for message {MessageId}; it will reappear after its visibility timeout.", message.MessageId);
                    }
                    drainDeadlineReached = true;
                    break;
                }
            }

            await ProcessMessageAsync(message, stoppingToken);

            if (_runOnce)
            {
                _logger.LogInformation(
                    "RunOnce: processed one message; exiting execution. Replica={Replica}", _replicaName);
                break;
            }
        }

        if ((_runOnce || drainDeadlineReached) && !stoppingToken.IsCancellationRequested)
        {
            // Event-driven Job execution (once) or warm Job rollover (drain): signal the host to
            // stop so the process exits 0 and the execution is recorded as succeeded.
            _lifetime.StopApplication();
        }
        else
        {
            _logger.LogWarning(
                "Shutdown signal received (SIGTERM/scale-in). Replica={Replica} Pid={Pid} is stopping its poll loop.",
                _replicaName, _processId);
        }
    }

    private async Task ProcessMessageAsync(QueueMessage message, CancellationToken stoppingToken)
    {
        JobPayload? payload = TryParse(message);
        if (payload is null)
        {
            _logger.LogError(
                "Could not parse job payload for message {MessageId} (dequeueCount={Count}). Leaving message for inspection.",
                message.MessageId, message.DequeueCount);
            return;
        }

        var jobId = payload.JobId;
        var duration = Math.Max(payload.DurationSeconds, 0);
        var attempt = message.DequeueCount;

        // Benchmark phase 1 anchor: time from enqueue (payload.createdAt) to this replica/execution
        // actually receiving the message. Captures queue-land -> workload-dispatch latency.
        var queueLatencyMs = payload.CreatedAt == default
            ? -1
            : (DateTimeOffset.UtcNow - payload.CreatedAt).TotalMilliseconds;

        _logger.LogInformation(
            "JobReceived job={JobId} message={MessageId} dequeueCount={Attempt} duration={Duration}s replica={Replica} queueLatencyMs={QueueLatency:F0}",
            jobId, message.MessageId, attempt, duration, _replicaName, queueLatencyMs);

        await Record(JobState.Started, jobId, message, duration, 0, attempt, stoppingToken);
        _logger.LogInformation(
            "JobStarted job={JobId} message={MessageId} replica={Replica} pid={Pid}",
            jobId, message.MessageId, _replicaName, _processId);

        // Optional memory pressure to make the payload feel realistic.
        byte[]? ballast = null;
        if (payload.PayloadSize is > 0)
        {
            ballast = new byte[payload.PayloadSize.Value * 1024];
            Array.Fill(ballast, (byte)1);
        }

        try
        {
            await SimulateWorkAsync(payload, message, attempt, stoppingToken);

            await Record(JobState.Completed, jobId, message, duration, 100, attempt, stoppingToken);
            _logger.LogInformation(
                "JobCompleted job={JobId} message={MessageId} replica={Replica} duration={Duration}s",
                jobId, message.MessageId, _replicaName, duration);

            // Only delete after durable completion is recorded.
            await _queue.DeleteMessageAsync(message.MessageId, message.PopReceipt, CancellationToken.None);
            _logger.LogInformation("MessageDeleted job={JobId} message={MessageId}", jobId, message.MessageId);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // SIGTERM during a job: record interruption and DO NOT delete the message.
            _logger.LogWarning(
                "JobInterrupted job={JobId} message={MessageId} replica={Replica} pid={Pid} — shutdown during in-flight work; message left in queue.",
                jobId, message.MessageId, _replicaName, _processId);
            await TryRecordInterrupted(jobId, message, duration, attempt);
            throw;
        }
        catch (JobFailModeException ex)
        {
            _logger.LogError(ex,
                "JobFailed job={JobId} message={MessageId} replica={Replica} failMode={FailMode}",
                jobId, message.MessageId, _replicaName, payload.FailMode);
            await Record(JobState.Failed, jobId, message, duration, ex.ProgressPercent, attempt, CancellationToken.None);
            // Leave the message so retry/dequeue behavior is observable.
        }
        catch (Exception ex)
        {
            // Transient fault (e.g. a storage blip in Record/DeleteMessage) while processing. Log and
            // leave the message for retry, but do NOT let it fault the BackgroundService — a warm
            // loop/drain execution must survive transient errors instead of crashing the whole
            // replica (which would non-cleanly drop the execution and churn the warm floor).
            _logger.LogError(ex,
                "JobError job={JobId} message={MessageId} replica={Replica} — unexpected error; leaving message for retry.",
                jobId, message.MessageId, _replicaName);
        }
        finally
        {
            GC.KeepAlive(ballast);
        }
    }

    private async Task SimulateWorkAsync(JobPayload payload, QueueMessage message, long attempt, CancellationToken stoppingToken)
    {
        var duration = TimeSpan.FromSeconds(Math.Max(payload.DurationSeconds, 0));
        var progressInterval = TimeSpan.FromSeconds(Math.Max(_options.ProgressIntervalSeconds, 1));
        var start = Stopwatch.StartNew();

        while (start.Elapsed < duration)
        {
            var remaining = duration - start.Elapsed;
            var step = remaining < progressInterval ? remaining : progressInterval;
            await Task.Delay(step, stoppingToken);

            var percent = duration > TimeSpan.Zero
                ? Math.Min(100, start.Elapsed.TotalSeconds / duration.TotalSeconds * 100.0)
                : 100;

            await Record(JobState.Progress, payload.JobId, message, payload.DurationSeconds, percent, attempt, stoppingToken);
            _logger.LogInformation(
                "JobProgress job={JobId} message={MessageId} replica={Replica} progress={Progress:F1}% elapsed={Elapsed:F0}s",
                payload.JobId, message.MessageId, _replicaName, percent, start.Elapsed.TotalSeconds);

            MaybeInjectFailure(payload, percent);
        }
    }

    private static void MaybeInjectFailure(JobPayload payload, double percent)
    {
        if (string.IsNullOrWhiteSpace(payload.FailMode))
        {
            return;
        }

        // Inject only once we are clearly mid-job (>50%) so Started/Progress exist without Completed.
        if (percent < 50)
        {
            return;
        }

        switch (payload.FailMode.Trim().ToLowerInvariant())
        {
            case "throw":
                throw new JobFailModeException(percent, "Injected failMode=throw");
            case "exit":
                // Simulate an unexpected crash: no Interrupted/Failed record is written.
                Environment.FailFast($"Injected failMode=exit for job {payload.JobId}");
                break;
        }
    }

    private async Task TryRecordInterrupted(string jobId, QueueMessage message, int duration, long attempt)
    {
        try
        {
            // Use a short independent timeout so we still capture evidence during the 30s shutdown window.
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await Record(JobState.Interrupted, jobId, message, duration, -1, attempt, cts.Token);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to record Interrupted state for job {JobId}", jobId);
        }
    }

    private Task Record(JobState state, string jobId, QueueMessage message, int duration, double percent, long attempt, CancellationToken ct)
    {
        var record = JobStateRecord.Create(
            state, jobId, message.MessageId, _replicaName, _processId, duration, percent, attempt);
        return _stateStore.RecordAsync(record, ct);
    }

    private JobPayload? TryParse(QueueMessage message)
    {
        try
        {
            // Queue messages may be base64-encoded (default for many SDKs/CLIs); fall back to raw text.
            var body = message.Body.ToString();
            return JsonSerializer.Deserialize<JobPayload>(body);
        }
        catch
        {
            try
            {
                var decoded = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(message.MessageText));
                return JsonSerializer.Deserialize<JobPayload>(decoded);
            }
            catch
            {
                return null;
            }
        }
    }

    private static async Task SafeDelay(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, ct);
        }
        catch (OperationCanceledException)
        {
            // shutdown; ignore.
        }
    }
}

/// <summary>Raised when a job's configured failMode triggers a controlled failure.</summary>
public sealed class JobFailModeException : Exception
{
    public double ProgressPercent { get; }

    public JobFailModeException(double progressPercent, string message) : base(message)
    {
        ProgressPercent = progressPercent;
    }
}
