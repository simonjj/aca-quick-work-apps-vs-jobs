<#
.SYNOPSIS
    Apply a reproduction profile (scaling settings) and optionally enqueue a job batch.

.DESCRIPTION
    Sets the azd environment variables that drive the Container App scale rule, re-provisions
    the infrastructure so the new scaling takes effect, then (optionally) enqueues jobs.

    Profile A (control):  minReplicas=1, maxReplicas=1  -> jobs should all complete.
    Profile B (failure):  minReplicas=0, maxReplicas=5  -> scale-in may kill in-flight jobs.

.EXAMPLE
    ./scripts/run-repro.ps1 -Profile B
    ./scripts/run-repro.ps1 -Profile A -Batch "10x300"
    ./scripts/run-repro.ps1 -Profile B -SkipEnqueue
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('A', 'B')]
    [string]$Profile,

    [string]$Batch,
    [switch]$SkipEnqueue
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/_common.ps1"

# ---- Profile definitions -------------------------------------------------------------
$profiles = @{
    A = @{ MIN_REPLICAS = '1'; MAX_REPLICAS = '1'; QUEUE_LENGTH = '1'; QUEUE_LENGTH_STRATEGY = 'all';         DefaultBatch = '10x300,10x600' }
    B = @{ MIN_REPLICAS = '0'; MAX_REPLICAS = '5'; QUEUE_LENGTH = '1'; QUEUE_LENGTH_STRATEGY = 'visibleonly'; DefaultBatch = '10x900,10x1500' }
}
$p = $profiles[$Profile]

Write-Host "Applying Profile ${Profile}: minReplicas=$($p.MIN_REPLICAS) maxReplicas=$($p.MAX_REPLICAS) queueLength=$($p.QUEUE_LENGTH) strategy=$($p.QUEUE_LENGTH_STRATEGY)" -ForegroundColor Cyan

foreach ($key in 'MIN_REPLICAS', 'MAX_REPLICAS', 'QUEUE_LENGTH', 'QUEUE_LENGTH_STRATEGY') {
    azd env set $key $p[$key] | Out-Null
}

Write-Host "Re-provisioning infrastructure to apply scaling profile..." -ForegroundColor Cyan
azd provision
if ($LASTEXITCODE -ne 0) { throw "azd provision failed." }

if ($SkipEnqueue) {
    Write-Host "Provisioning complete. Skipping enqueue (-SkipEnqueue)." -ForegroundColor Green
    return
}

$batchToUse = if ($Batch) { $Batch } else { $p.DefaultBatch }
Write-Host "Enqueuing batch: $batchToUse" -ForegroundColor Cyan
& "$PSScriptRoot/enqueue.ps1" -Batch $batchToUse

Write-Host ""
Write-Host "Repro running. Watch scaling and then collect evidence:" -ForegroundColor Green
Write-Host "  ./scripts/collect-evidence.ps1" -ForegroundColor Green
