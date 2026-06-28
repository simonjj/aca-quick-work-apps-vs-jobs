<#
.SYNOPSIS
    Tear down all Azure resources created for the repro.

.DESCRIPTION
    Runs `azd down` to delete the resource group and all resources. Use -Purge to also purge
    soft-deletable resources so names can be reused immediately.

.EXAMPLE
    ./scripts/cleanup.ps1
    ./scripts/cleanup.ps1 -Purge
#>
[CmdletBinding()]
param(
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw "azd (Azure Developer CLI) is not installed or not on PATH."
}

$azdArgs = @('down', '--force')
if ($Purge) { $azdArgs += '--purge' }

Write-Host "Tearing down all resources (azd $($azdArgs -join ' '))..." -ForegroundColor Yellow
azd @azdArgs
