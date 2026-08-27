#Requires -Version 5.1
<#
.SYNOPSIS
    Deactivates a policy set from a scope (PolicySet - Activation - Deactivate).
.DESCRIPTION
    POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/deactivate

    Body: { "scopeType": "Tenant" | "Capacity" }

    Note the request body carries only scopeType - unlike Activate there is no scopeId,
    which is how the private-preview reference documents it.

    When -ScopeType is omitted it is read from the policy set's own properties.scope.

    Permissions: read permission on the policy set. Scope: Item.Read.All.
.EXAMPLE
    .\deactivate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps>
.EXAMPLE
    .\deactivate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps> -ScopeType Capacity
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,

    [ValidateSet('Tenant', 'Capacity')]
    [string]$ScopeType,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$policySetUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId"

if (-not $ScopeType) {
    Write-Verbose "GET $policySetUri"
    try {
        $policySet = Invoke-RestMethod -Uri $policySetUri -Method Get -Headers $headers `
            -ContentType 'application/json' -ErrorAction Stop
    }
    catch {
        Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
        throw
    }

    $ScopeType = $policySet.properties.scope.type

    if ($policySet.properties.status -ne 'Active') {
        Write-Warning "Policy set $PolicySetId reports status '$($policySet.properties.status)'. Expect PolicySetNotActiveOnScope."
    }
}

$uri = "$policySetUri/deactivate"
$body = @{ scopeType = $ScopeType } | ConvertTo-Json

if (-not $PSCmdlet.ShouldProcess("policy set $PolicySetId", "Deactivate from $ScopeType scope")) {
    return
}

Write-Verbose "POST $uri"
try {
    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -ErrorAction Stop | Out-Null
}
catch {
    Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    throw
}

Write-Host "Deactivated policy set $PolicySetId from $ScopeType scope." -ForegroundColor Green
