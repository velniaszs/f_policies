#Requires -Version 5.1
<#
.SYNOPSIS
    Lists workspaces with the capacity each one is assigned to.
.DESCRIPTION
    GET https://api.fabric.microsoft.com/v1/workspaces

    Returns workspaces the principal can access. Each workspace carries capacityId and
    capacityRegion; both are absent when the workspace is not assigned to a capacity
    (for example Personal workspaces). Requires Workspace.Read.All or Workspace.ReadWrite.All.
.EXAMPLE
    .\list_workspaces.ps1 | Format-Table
.EXAMPLE
    # Only workspaces on one capacity - use this to pick -FilterWorkspaceId values for a rule
    .\list_workspaces.ps1 -CapacityId 3f9c2b6e-7a41-4c8d-9e5f-1b2a6d7c8e90
.EXAMPLE
    # Which capacity does this workspace sit on?
    .\list_workspaces.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229
.EXAMPLE
    # Group the tenant view by capacity
    .\list_workspaces.ps1 -GroupByCapacity
#>
[CmdletBinding()]
param(
    [guid]$WorkspaceId,
    [guid]$CapacityId,
    [switch]$GroupByCapacity,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = 'https://api.fabric.microsoft.com/v1/workspaces'
$workspaces = @()

do {
    Write-Verbose "GET $uri"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
            -ContentType 'application/json' -ErrorAction Stop
    }
    catch {
        Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
        throw
    }

    $workspaces += $response.value

    $uri = $null
    if ($response.PSObject.Properties.Name -contains 'continuationUri') { $uri = $response.continuationUri }
}
while ($uri)

if ($PSBoundParameters.ContainsKey('WorkspaceId')) {
    $workspaces = $workspaces | Where-Object { $_.id -eq $WorkspaceId }
}

if ($PSBoundParameters.ContainsKey('CapacityId')) {
    $workspaces = $workspaces | Where-Object {
        ($_.PSObject.Properties.Name -contains 'capacityId') -and $_.capacityId -eq $CapacityId
    }
}

$projected = $workspaces | Select-Object `
    id,
    displayName,
    type,
    @{ Name = 'capacityId';     Expression = { if ($_.PSObject.Properties.Name -contains 'capacityId')     { $_.capacityId }     else { '(none)' } } },
    @{ Name = 'capacityRegion'; Expression = { if ($_.PSObject.Properties.Name -contains 'capacityRegion') { $_.capacityRegion } else { '' } } }

if ($GroupByCapacity) {
    $projected | Sort-Object capacityId, displayName | Group-Object capacityId |
        ForEach-Object {
            Write-Host ''
            Write-Host "Capacity $($_.Name)  ($($_.Count) workspace(s))" -ForegroundColor Cyan
            $_.Group | Select-Object id, displayName, type, capacityRegion | Format-Table -AutoSize | Out-Host
        }
}
else {
    $projected
}
