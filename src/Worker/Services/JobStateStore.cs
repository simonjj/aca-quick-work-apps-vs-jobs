using AcaQueueRepro.Worker.Models;
using Azure.Data.Tables;
using Microsoft.Extensions.Logging;

namespace AcaQueueRepro.Worker.Services;

/// <summary>
/// Persists durable job state to Azure Table Storage. Each call appends a new row, producing an
/// append-only audit trail keyed by jobId.
/// </summary>
public sealed class JobStateStore
{
    private readonly TableClient _table;
    private readonly ILogger<JobStateStore> _logger;

    public JobStateStore(TableClient table, ILogger<JobStateStore> logger)
    {
        _table = table;
        _logger = logger;
    }

    public async Task RecordAsync(JobStateRecord record, CancellationToken cancellationToken)
    {
        try
        {
            await _table.AddEntityAsync(record, cancellationToken);
        }
        catch (Exception ex)
        {
            // State persistence failures must be loud: losing a state record undermines the repro.
            _logger.LogError(ex,
                "Failed to persist state {State} for job {JobId} (replica {Replica})",
                record.State, record.JobId, record.ReplicaName);
            throw;
        }
    }
}
