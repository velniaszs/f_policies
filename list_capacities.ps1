#Requires -Version 5.1
<#
.SYNOPSIS
    Lists Fabric capacities, either the ones the caller can access or all of them (admin).
.DESCRIPTION
    Default (Core API) - capacities where the principal is an administrator or a contributor:
        GET https://api.fabric.microsoft.com/v1/capacities
        Scope: Capacity.Read.All or Capacity.ReadWrite.All

    -AsAdmin (Power BI admin API) - every capacity in the organization:
        GET https://api.powerbi.com/v1.0/myorg/admin/capacities
        Caller must be a Fabric administrator or a service principal. Max 200 requests/hour.
        Note this is a different host and needs a Power BI audience token, not a Fabric one.
        Fabric has no /v1/admin/capacities endpoint.

    Use the returned id as -CapacityId when creating a capacity-scoped policy set.
.EXAMPLE
    .\list_capacities.ps1 | Format-Table
.EXAMPLE
    .\list_capacities.ps1 -AsAdmin | Format-Table
.EXAMPLE
    .\list_capacities.ps1 -AsAdmin -State Active
#>
[CmdletBinding()]
param(
    [switch]$AsAdmin,

    [string]$State,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

if ($AsAdmin) {
    $headers = @{ Authorization = "Bearer $(Get-FabricToken -Scope $script:PowerBiApiScope)" }
    $uri = 'https://api.powerbi.com/v1.0/myorg/admin/capacities'
}
else {
    $headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
    $uri = 'https://api.fabric.microsoft.com/v1/capacities'
}

$capacities = @()

do {
    Write-Verbose "GET $uri"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
            -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw (Get-FabricErrorText -ErrorRecord $_)
    }

    $capacities += $response.value

    # The Power BI admin route is not paged; only the Fabric route returns a continuation URI.
    $uri = $null
    if ($response.PSObject.Properties.Name -contains 'continuationUri') { $uri = $response.continuationUri }
}
while ($uri)

if ($State) {
    $capacities = $capacities | Where-Object { $_.state -eq $State }
}

if ($AsAdmin) {
    $capacities | Select-Object id, displayName, sku, region, state, capacityUserAccessRight, admins
}
else {
    $capacities | Select-Object id, displayName, sku, region, state
}
