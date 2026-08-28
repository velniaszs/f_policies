#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a capacity-scoped policy set in a workspace.
.DESCRIPTION
    POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets

    "Items - Create Policy Set" is listed in the operations table of the private-preview
    reference but has no detailed section, so the request body here is derived from
    observed API behaviour rather than documentation:

      - the service rejects a body without workloadPayload ("workloadPayload is required")
      - activation showed the service uses capacityId where the doc says scopeId

    Use -PayloadAsString if the service wants workloadPayload as an escaped JSON string,
    or -BodyJson to send a hand-written body and bypass all guessing.
.EXAMPLE
    .\new_policy_set.ps1 -WorkspaceId <ws> -CapacityId <cap> -DisplayName 'UBS capacity policy set'
.EXAMPLE
    # Send workloadPayload as an escaped JSON string instead of an object
    .\new_policy_set.ps1 -WorkspaceId <ws> -CapacityId <cap> -DisplayName 'Test' -PayloadAsString
.EXAMPLE
    # Full manual control while the create contract is unconfirmed
    .\new_policy_set.ps1 -WorkspaceId <ws> -DisplayName ignored -CapacityId <cap> -Verbose -BodyJson @'
    {
      "displayName": "Test",
      "description": "",
      "workloadPayload": { "scopeType": "Capacity", "capacityId": "<cap>" }
    }
'@
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$CapacityId,
    [Parameter(Mandatory)][string]$DisplayName,

    [ValidateLength(0, 256)]
    [string]$Description = '',

    [switch]$PayloadAsString,

    [string]$BodyJson,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

if ($BodyJson) {
    $body = $BodyJson
}
else {
    $payload = @{
        scopeType  = 'Capacity'
        capacityId = $CapacityId.ToString()
    }

    $bodyMap = @{
        displayName     = $DisplayName
        description     = $Description
        workloadPayload = if ($PayloadAsString) { $payload | ConvertTo-Json -Compress } else { $payload }
    }

    $body = $bodyMap | ConvertTo-Json -Depth 10
}

if (-not $PSCmdlet.ShouldProcess("workspace $WorkspaceId", "Create capacity policy set '$DisplayName' on capacity $CapacityId")) {
    return
}

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets"

Write-Verbose "POST $uri"
Write-Verbose $body
try {
    $policySet = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
}
catch {
    Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    throw
}

Write-Verbose "Created policy set $($policySet.id)"
$policySet
