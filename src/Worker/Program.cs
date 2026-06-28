using AcaQueueRepro.Worker;
using AcaQueueRepro.Worker.Models;
using AcaQueueRepro.Worker.Services;
using Azure.Data.Tables;
using Azure.Storage.Queues;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

var builder = Host.CreateApplicationBuilder(args);

// Structured JSON logs make the Log Analytics Kusto queries in /docs reliable.
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o =>
{
    o.IncludeScopes = false;
    o.UseUtcTimestamp = true;
});

// Bind WORKER_* style config. Environment variables override appsettings.json.
builder.Services
    .AddOptions<WorkerOptions>()
    .Bind(builder.Configuration.GetSection("Worker"))
    .PostConfigure(o =>
    {
        // Allow the canonical AzureWebJobsStorage / STORAGE_CONNECTION_STRING names too.
        if (string.IsNullOrWhiteSpace(o.StorageConnectionString))
        {
            o.StorageConnectionString =
                builder.Configuration["STORAGE_CONNECTION_STRING"]
                ?? builder.Configuration["AzureWebJobsStorage"]
                ?? string.Empty;
        }
    })
    .Validate(o => !string.IsNullOrWhiteSpace(o.StorageConnectionString),
        "A storage connection string is required (Worker:StorageConnectionString, STORAGE_CONNECTION_STRING or AzureWebJobsStorage).")
    .ValidateOnStart();

builder.Services.AddSingleton(sp =>
{
    var o = sp.GetRequiredService<IOptions<WorkerOptions>>().Value;
    var client = new QueueClient(o.StorageConnectionString, o.QueueName);
    client.CreateIfNotExists();
    return client;
});

builder.Services.AddSingleton(sp =>
{
    var o = sp.GetRequiredService<IOptions<WorkerOptions>>().Value;
    var client = new TableClient(o.StorageConnectionString, o.StateTableName);
    client.CreateIfNotExists();
    return client;
});

builder.Services.AddSingleton<JobStateStore>();
builder.Services.AddHostedService<Worker>();

// ACA sends SIGTERM then SIGKILLs after terminationGracePeriodSeconds (customer-confirmed: 600).
// Give the host that full window to drain in-flight work instead of self-abandoning early.
var shutdownTimeoutSeconds = builder.Configuration.GetValue("Worker:ShutdownTimeoutSeconds", 600);
builder.Services.Configure<HostOptions>(o =>
    o.ShutdownTimeout = TimeSpan.FromSeconds(shutdownTimeoutSeconds));

var host = builder.Build();

var startupLogger = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Startup");
startupLogger.LogInformation("ACA queue worker repro starting up.");

host.Run();
