<#
.SYNOPSIS
    Shared helpers for the repro scripts. Dot-source this file: . "$PSScriptRoot/_common.ps1"
#>

function Get-AzdEnv {
    <#
        Returns a hashtable of the current azd environment's values (outputs + config),
        e.g. STORAGE_ACCOUNT_NAME, AZURE_RESOURCE_GROUP, WORKER_RESOURCE_NAME.
    #>
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        throw "azd (Azure Developer CLI) is not installed or not on PATH."
    }

    $raw = azd env get-values 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        throw "Could not read azd environment. Run 'azd up' (or 'azd env select <name>') first."
    }

    $map = @{}
    foreach ($line in $raw) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*"?(.*?)"?\s*$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

function Get-StorageConnectionString {
    param([hashtable]$EnvValues)

    $account = $EnvValues['STORAGE_ACCOUNT_NAME']
    $rg = $EnvValues['AZURE_RESOURCE_GROUP']
    if ([string]::IsNullOrWhiteSpace($account) -or [string]::IsNullOrWhiteSpace($rg)) {
        throw "STORAGE_ACCOUNT_NAME / AZURE_RESOURCE_GROUP not found in azd environment. Has 'azd up' completed?"
    }

    $cs = az storage account show-connection-string `
        --name $account `
        --resource-group $rg `
        --query connectionString -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cs)) {
        throw "Failed to fetch storage connection string. Are you logged in with 'az login'?"
    }
    return $cs
}

function Get-LogAnalyticsCustomerId {
    param([hashtable]$EnvValues)

    $ws = $EnvValues['LOG_ANALYTICS_WORKSPACE_NAME']
    $rg = $EnvValues['AZURE_RESOURCE_GROUP']
    if ([string]::IsNullOrWhiteSpace($ws) -or [string]::IsNullOrWhiteSpace($rg)) {
        throw "LOG_ANALYTICS_WORKSPACE_NAME / AZURE_RESOURCE_GROUP not found in azd environment."
    }

    $id = az monitor log-analytics workspace show `
        --resource-group $rg --workspace-name $ws `
        --query customerId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
        throw "Failed to fetch Log Analytics workspace id."
    }
    return $id
}
