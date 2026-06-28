using System.Text.Json;
using Azure.Storage.Queues;

// Simple job generator / enqueuer CLI for the ACA queue-worker scale-down repro.
//
// Usage:
//   Enqueuer --connection "<storage-connection-string>" [--queue jobs] \
//            [--batch "10x300,10x600,5x1500"] [--preset mixed|a|b|smoke] \
//            [--failMode none|throw|exit] [--payloadSize 0]
//
// A batch term "NxS" means N jobs of S seconds each. --preset is a convenience shortcut.
// The connection string may also come from STORAGE_CONNECTION_STRING / AzureWebJobsStorage.

var options = ArgParser.Parse(args);

var connection = options.Get("connection")
    ?? Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING")
    ?? Environment.GetEnvironmentVariable("AzureWebJobsStorage");

if (string.IsNullOrWhiteSpace(connection))
{
    Console.Error.WriteLine("ERROR: a storage connection string is required (--connection, STORAGE_CONNECTION_STRING or AzureWebJobsStorage).");
    return 1;
}

var queueName = options.Get("queue") ?? "jobs";
var failMode = options.Get("failMode") ?? "none";
var payloadSize = int.TryParse(options.Get("payloadSize"), out var ps) ? ps : 0;

var spec = options.Get("batch") ?? PresetToSpec(options.Get("preset") ?? "smoke");
var jobs = ExpandSpec(spec).ToList();
if (jobs.Count == 0)
{
    Console.Error.WriteLine("ERROR: no jobs to enqueue. Provide --batch \"NxS,...\" or --preset.");
    return 1;
}

var queue = new QueueClient(connection, queueName);
await queue.CreateIfNotExistsAsync();

Console.WriteLine($"Enqueuing {jobs.Count} job(s) to queue '{queueName}' (failMode={failMode}, payloadSize={payloadSize}KB)...");

var runId = DateTime.UtcNow.ToString("yyyyMMddHHmmss");
var n = 0;
foreach (var durationSeconds in jobs)
{
    n++;
    var job = new
    {
        jobId = $"{runId}-{n:D4}-{durationSeconds}s",
        durationSeconds,
        createdAt = DateTimeOffset.UtcNow,
        payloadSize = payloadSize > 0 ? payloadSize : (int?)null,
        failMode = string.Equals(failMode, "none", StringComparison.OrdinalIgnoreCase) ? null : failMode
    };

    var json = JsonSerializer.Serialize(job);
    await queue.SendMessageAsync(json);
    Console.WriteLine($"  + {job.jobId} ({durationSeconds}s / {durationSeconds / 60.0:F1}min)");
}

Console.WriteLine($"Done. Enqueued {jobs.Count} job(s). Total simulated work: {jobs.Sum() / 60.0:F1} replica-minutes.");
return 0;

static string PresetToSpec(string preset) => preset.ToLowerInvariant() switch
{
    // Quick local sanity check.
    "smoke" => "3x30",
    // Profile A: conservative, short-to-medium jobs expected to all complete.
    "a" => "10x300,10x600",
    // Profile B: long jobs + a burst so queue depth drops while work is still in flight.
    "b" => "10x900,10x1500",
    // Mixed durations per the instructions.
    "mixed" => "1x300,1x600,1x900,1x1200,1x1500",
    _ => preset // allow passing a raw spec to --preset too
};

static IEnumerable<int> ExpandSpec(string spec)
{
    foreach (var term in spec.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
    {
        var parts = term.Split('x', 'X');
        if (parts.Length != 2
            || !int.TryParse(parts[0], out var count)
            || !int.TryParse(parts[1], out var seconds)
            || count <= 0 || seconds <= 0)
        {
            Console.Error.WriteLine($"WARN: skipping invalid batch term '{term}' (expected NxS).");
            continue;
        }

        for (var i = 0; i < count; i++)
        {
            yield return seconds;
        }
    }
}

internal sealed class ArgParser
{
    private readonly Dictionary<string, string> _values = new(StringComparer.OrdinalIgnoreCase);

    public static ArgParser Parse(string[] args)
    {
        var p = new ArgParser();
        for (var i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            var key = args[i][2..];
            var value = i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal)
                ? args[++i]
                : "true";
            p._values[key] = value;
        }

        return p;
    }

    public string? Get(string key) => _values.TryGetValue(key, out var v) ? v : null;
}
