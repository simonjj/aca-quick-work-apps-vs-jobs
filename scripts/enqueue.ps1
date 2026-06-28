<#
.SYNOPSIS
    Enqueue test jobs into the worker's storage queue.

.DESCRIPTION
    Reads connection details from the current azd environment, then uses the Enqueuer CLI
    (src/Enqueuer) to push job messages onto the queue.

.EXAMPLE
    ./scripts/enqueue.ps1 -Preset b
    ./scripts/enqueue.ps1 -Batch "10x300,10x600" -FailMode none
    ./scripts/enqueue.ps1 -Batch "5x1500" -FailMode throw
#>
[CmdletBinding()]
param(
    [string]$Preset = 'smoke',
    [string]$Batch,
    [ValidateSet('none', 'throw', 'exit')]
    [string]$FailMode = 'none',
    [int]$PayloadSize = 0
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

. "$PSScriptRoot/_common.ps1"
$envValues = Get-AzdEnv

$connectionString = Get-StorageConnectionString -EnvValues $envValues
$queueName = $envValues['QUEUE_NAME']
if ([string]::IsNullOrWhiteSpace($queueName)) { $queueName = 'jobs' }

$enqueuerArgs = @('run', '--project', (Join-Path $repoRoot 'src/Enqueuer/Enqueuer.csproj'), '-c', 'Release', '--',
    '--connection', $connectionString,
    '--queue', $queueName,
    '--failMode', $FailMode,
    '--payloadSize', "$PayloadSize")

if ($Batch) {
    $enqueuerArgs += @('--batch', $Batch)
} else {
    $enqueuerArgs += @('--preset', $Preset)
}

Write-Host "Enqueuing jobs to queue '$queueName'..." -ForegroundColor Cyan
dotnet @enqueuerArgs
