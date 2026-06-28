<#
.SYNOPSIS
    Collect evidence and answer: "Did a job start and then fail to complete because its replica
    was terminated?"

.DESCRIPTION
    1. Reads all durable job-state records from Table Storage and reports any job that has a
       Started/Progress record but no Completed record (the core failure signal).
    2. Runs Log Analytics (Kusto) queries for shutdown signals and KEDA scale decisions in the
       same window, so terminations can be correlated to the incomplete jobs.

    Log ingestion into Log Analytics can lag several minutes; re-run if the system-log section
    is empty shortly after a run.

.EXAMPLE
    ./scripts/collect-evidence.ps1
    ./scripts/collect-evidence.ps1 -LookbackMinutes 120
#>
[CmdletBinding()]
param(
    [int]$LookbackMinutes = 60
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_common.ps1"
$envValues = Get-AzdEnv

$connectionString = Get-StorageConnectionString -EnvValues $envValues
$tableName = $envValues['STATE_TABLE_NAME']
if ([string]::IsNullOrWhiteSpace($tableName)) { $tableName = 'jobstate' }

Write-Host "=== Durable job state ($tableName) ===" -ForegroundColor Cyan
$json = az storage entity query `
    --table-name $tableName `
    --connection-string $connectionString `
    --query "items[].{job:JobId,state:State,replica:ReplicaName,pid:ProcessId,ts:TimestampUtc,progress:ProgressPercent,attempt:AttemptNumber}" `
    -o json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
    Write-Warning "No state records found yet (or table query failed)."
} else {
    $records = $json | ConvertFrom-Json
    $byJob = $records | Group-Object job

    $started = 0; $completed = 0; $interrupted = 0; $failed = 0
    $orphans = @()

    foreach ($g in $byJob) {
        $states = $g.Group.state
        if ($states -contains 'Started') { $started++ }
        if ($states -contains 'Completed') { $completed++ }
        if ($states -contains 'Interrupted') { $interrupted++ }
        if ($states -contains 'Failed') { $failed++ }

        $hasStart = ($states -contains 'Started') -or ($states -contains 'Progress')
        if ($hasStart -and ($states -notcontains 'Completed') -and ($states -notcontains 'Failed')) {
            $replicas = ($g.Group.replica | Sort-Object -Unique) -join ','
            $maxProgress = ($g.Group.progress | Measure-Object -Maximum).Maximum
            $orphans += [pscustomobject]@{
                Job          = $g.Name
                MaxProgress  = [math]::Round([double]$maxProgress, 1)
                Replicas     = $replicas
                Interrupted  = ($states -contains 'Interrupted')
                Attempts     = ($g.Group.attempt | Measure-Object -Maximum).Maximum
            }
        }
    }

    Write-Host ("Jobs: started={0} completed={1} interrupted={2} failed={3}" -f $started, $completed, $interrupted, $failed)
    Write-Host ""

    if ($orphans.Count -gt 0) {
        Write-Host "*** STARTED-BUT-NEVER-COMPLETED JOBS (failure signal) ***" -ForegroundColor Red
        $orphans | Format-Table -AutoSize
    } else {
        Write-Host "No started-but-incomplete jobs found. Every started job has a Completed/Failed record." -ForegroundColor Green
    }
}

# ---- Log Analytics correlation -------------------------------------------------------
Write-Host ""
Write-Host "=== Container App system logs: shutdown / scale-in (last $LookbackMinutes min) ===" -ForegroundColor Cyan
try {
    $customerId = Get-LogAnalyticsCustomerId -EnvValues $envValues

    $shutdownQuery = @"
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(${LookbackMinutes}m)
| where Log_s has_any ('SIGTERM', 'scale', 'terminat', 'deactiv', 'Stopping', 'Replica')
| project TimeGenerated, RevisionName_s, ReplicaName_s, Reason_s, Log_s
| order by TimeGenerated desc
| take 50
"@

    $kedaQuery = @"
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(${LookbackMinutes}m)
| where EventSource_s == 'KEDA'
| project TimeGenerated, Type_s, Reason_s, Log_s
| order by TimeGenerated desc
| take 50
"@

    Write-Host "-- Shutdown / replica lifecycle --"
    az monitor log-analytics query --workspace $customerId --analytics-query $shutdownQuery -o table 2>$null

    Write-Host ""
    Write-Host "-- KEDA scale decisions --"
    az monitor log-analytics query --workspace $customerId --analytics-query $kedaQuery -o table 2>$null
}
catch {
    Write-Warning "Could not query Log Analytics: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "More queries are documented in docs/repro.md and docs/observations.md." -ForegroundColor DarkGray
