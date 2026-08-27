#Requires -Version 5.1
<#
.SYNOPSIS
    Activates a policy set on a scope (PolicySet - Activation - Activate).
.DESCRIPTION
    POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/activate
    POST .../activate?allowReplace={allowReplace}

    Body: { "scopeType": "Tenant" | "Capacity", "scopeId": <uuid>, "capacityId": <uuid> }

    The reference documents scopeId, but the preview service validates capacityId and fails
    with PropertyCannotBeDefault when it is absent, so both are sent for capacity scope.

    When -ScopeType/-ScopeId are omitted they are read from the policy set's own
    properties.scope, which avoids InvalidActivationScope (the activation scope type
    must match the policy set scope type).

    Only a single policy set can be active on a given scope - use -AllowReplace to
    take over from the one currently active.

    Permissions: read permission on the policy set. Scope: Item.Read.All.
.EXAMPLE
    .\activate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps>
.EXAMPLE
    .\activate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps> -AllowReplace
.EXAMPLE
    .\activate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps> -ScopeType Capacity -ScopeId <cap>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,

    [ValidateSet('Tenant', 'Capacity')]
    [string]$ScopeType,

    [guid]$ScopeId,

    [switch]$AllowReplace,

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

if (-not $ScopeType -or -not $PSBoundParameters.ContainsKey('ScopeId')) {
    Write-Verbose "GET $policySetUri"
    try {
        $policySet = Invoke-RestMethod -Uri $policySetUri -Method Get -Headers $headers `
            -ContentType 'application/json' -ErrorAction Stop
    }
    catch {
        Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
        throw
    }

    if (-not $ScopeType) { $ScopeType = $policySet.properties.scope.type }

    if (-not $PSBoundParameters.ContainsKey('ScopeId')) {
        if ($policySet.properties.scope.PSObject.Properties.Name -contains 'id') {
            $ScopeId = $policySet.properties.scope.id
        }
        else {
            throw "Policy set $PolicySetId has no scope id (scope type '$ScopeType'). Pass -ScopeId explicitly."
        }
    }

    Write-Verbose "Resolved scope from the policy set: $ScopeType / $ScopeId"
}

$uri = "$policySetUri/activate"
if ($AllowReplace) { $uri += '?allowReplace=True' }

# The doc documents scopeId, but the live preview API rejects a missing capacityId
# ("PropertyCannotBeDefault - property capacityId..."). Send both; unknown properties are ignored.
$bodyMap = @{
    scopeType = $ScopeType
    scopeId   = $ScopeId.ToString()
}
if ($ScopeType -eq 'Capacity') { $bodyMap.capacityId = $ScopeId.ToString() }

$body = $bodyMap | ConvertTo-Json

$action = "Activate on $ScopeType scope $ScopeId"
if ($AllowReplace) { $action += ' (replacing any active policy set)' }

if (-not $PSCmdlet.ShouldProcess("policy set $PolicySetId", $action)) {
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

Write-Host "Activated policy set $PolicySetId on $ScopeType scope $ScopeId." -ForegroundColor Green
