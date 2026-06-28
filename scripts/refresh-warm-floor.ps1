<#
.SYNOPSIS
    Refreshes the warm-Job floor so it runs the real worker image (postdeploy hook).

.DESCRIPTION
    Only relevant for DEPLOYMENT_MODE=warmjob. azd provisions a Container Apps Job with a
    placeholder image and only swaps in the real worker image during `azd deploy`. But
    `minExecutions` launches its floor executions at provision time against the *placeholder*,
    and ACA does NOT restart already-running executions when the image is updated — so the
    "warm floor" would otherwise stay as placeholder containers (which never poll the queue)
    until replicaTimeout.

    This script stops only the **stale** running executions — those whose container image does
    NOT match the job's current (just-deployed) image — so KEDA respawns the floor on the real
    worker image. Executions already running the current image are LEFT ALONE, so re-running
    `azd deploy` while real drain workers are processing queue messages will NOT interrupt them.
    This makes the hook safe to run on every `postdeploy` and idempotent (a second run with no
    stale executions is a no-op).

    Best-effort: any failure is logged and ignored so it never blocks `azd up`. No-op for
    non-warmjob modes.
#>

$ErrorActionPreference = 'Continue'

. "$PSScriptRoot/_common.ps1"

try {
    $envValues = Get-AzdEnv
} catch {
    Write-Host "refresh-warm-floor: could not read azd env ($_); skipping."
    exit 0
}

$mode = $envValues['DEPLOYMENT_MODE']
if ($mode -ne 'warmjob') {
    Write-Host "refresh-warm-floor: DEPLOYMENT_MODE='$mode' (not 'warmjob'); nothing to do."
    exit 0
}

$job = $envValues['WORKER_RESOURCE_NAME']
$rg = $envValues['AZURE_RESOURCE_GROUP']
if ([string]::IsNullOrWhiteSpace($job) -or [string]::IsNullOrWhiteSpace($rg)) {
    Write-Host "refresh-warm-floor: WORKER_RESOURCE_NAME / AZURE_RESOURCE_GROUP missing; skipping."
    exit 0
}

# The image the job was just deployed with. Executions running anything else are stale
# (the provision-time placeholder, or a previous revision) and should be rolled over.
$currentImage = az containerapp job show -g $rg -n $job `
    --query "properties.template.containers[0].image" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentImage)) {
    Write-Host "refresh-warm-floor: could not read the job's current image (or az not available); skipping."
    exit 0
}
Write-Host "refresh-warm-floor: current job image is '$currentImage'."

$running = az containerapp job execution list -g $rg -n $job `
    --query "[?properties.status=='Running'].name" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($running)) {
    Write-Host "refresh-warm-floor: no running executions found (or az not available); skipping."
    exit 0
}

$stopped = 0
foreach ($name in ($running -split "`n" | Where-Object { $_ -and $_.Trim() })) {
    $name = $name.Trim()
    $execImage = az containerapp job execution show -g $rg -n $job --job-execution-name $name `
        --query "properties.template.containers[0].image" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($execImage)) {
        Write-Host "  ? $name - could not read image; leaving it alone (safe default)."
        continue
    }
    if ($execImage -eq $currentImage) {
        # Already on the real image - this is (or will become) the live warm floor / real work.
        # Never stop it: that would interrupt in-flight jobs and churn the floor.
        Write-Host "  = $name - already on current image; leaving running."
        continue
    }
    az containerapp job stop -g $rg -n $job --job-execution-name $name -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  stopped $name (stale image '$execImage')"
        $stopped++
    } else {
        Write-Host "  WARN: could not stop $name (continuing)"
    }
}

if ($stopped -eq 0) {
    Write-Host "refresh-warm-floor: no stale executions to refresh; floor is already on the real image."
} else {
    Write-Host "refresh-warm-floor: stopped $stopped stale execution(s). KEDA will respawn the minExecutions floor on the real worker image."
    Write-Host "  Verify with: az containerapp job execution list -g $rg -n $job  (new executions should log 'JobReceived', not 'Listening on :80')."
}
exit 0
