using Azure;
using Azure.Data.Tables;

namespace AcaQueueRepro.Worker.Models;

/// <summary>
/// A single durable state record. One row is written per state transition so the table acts as
/// an append-only audit trail per job, letting a reviewer reconstruct exactly what happened and
/// on which replica.
///
/// PartitionKey = jobId so all events for a job are co-located and easy to query.
/// RowKey       = a lexicographically sortable key ("{ticks:D19}-{state}") so events sort in order.
/// </summary>
public sealed class JobStateRecord : ITableEntity
{
    public string PartitionKey { get; set; } = string.Empty; // jobId
    public string RowKey { get; set; } = string.Empty;       // {ticks}-{state}
    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string JobId { get; set; } = string.Empty;
    public string State { get; set; } = string.Empty;
    public string MessageId { get; set; } = string.Empty;
    public string ReplicaName { get; set; } = string.Empty;
    public int ProcessId { get; set; }
    public DateTimeOffset TimestampUtc { get; set; }
    public int DurationSeconds { get; set; }
    public double ProgressPercent { get; set; }
    public long AttemptNumber { get; set; } // dequeueCount

    public static JobStateRecord Create(
        JobState state,
        string jobId,
        string messageId,
        string replicaName,
        int processId,
        int durationSeconds,
        double progressPercent,
        long attemptNumber)
    {
        var nowUtc = DateTimeOffset.UtcNow;
        return new JobStateRecord
        {
            PartitionKey = jobId,
            RowKey = $"{nowUtc.UtcTicks:D19}-{state}",
            JobId = jobId,
            State = state.ToString(),
            MessageId = messageId,
            ReplicaName = replicaName,
            ProcessId = processId,
            TimestampUtc = nowUtc,
            DurationSeconds = durationSeconds,
            ProgressPercent = progressPercent,
            AttemptNumber = attemptNumber
        };
    }
}
