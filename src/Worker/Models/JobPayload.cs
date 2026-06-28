using System.Text.Json.Serialization;

namespace AcaQueueRepro.Worker.Models;

/// <summary>
/// The job payload carried by each queue message.
/// </summary>
public sealed class JobPayload
{
    [JsonPropertyName("jobId")]
    public string JobId { get; set; } = string.Empty;

    [JsonPropertyName("durationSeconds")]
    public int DurationSeconds { get; set; }

    [JsonPropertyName("createdAt")]
    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>Optional size (in KB) of an in-memory buffer to allocate to simulate payload weight.</summary>
    [JsonPropertyName("payloadSize")]
    public int? PayloadSize { get; set; }

    /// <summary>
    /// Optional failure injection: "none" (default), "throw" (raise mid-job), "exit" (crash the
    /// process mid-job to simulate an unexpected termination).
    /// </summary>
    [JsonPropertyName("failMode")]
    public string? FailMode { get; set; }
}
