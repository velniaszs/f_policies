#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a capacity-scoped policy set in a workspace.
.DESCRIPTION
    NOTE: "Items - Create Policy Set" is listed in the operations table of
    'Fabric Policies - REST API Reference.docx' but the document contains no detailed
    section for it. The request shape below follows the Items group convention
    (POST to the collection, PolicySetProperties body). Verify against the live
    private-preview spec if the call fails with InvalidRequest.
.EXAMPLE
    .\new_policy_set.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 `
                         -CapacityId 3f9c2b6e-7a41-4c8d-9e5f-1b2a6d7c8e90 `
                         -DisplayName 'UBS capacity policy set'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$CapacityId,
    [Parameter(Mandatory)][string]$DisplayName,

    [ValidateLength(0, 256)]
    [string]$Description = '',

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$body = @{
    displayName = $DisplayName
    description = $Description
    properties  = @{
        scope = @{
            type = 'Capacity'
            id   = $CapacityId.ToString()
        }
    }
} | ConvertTo-Json -Depth 10

if (-not $PSCmdlet.ShouldProcess("workspace $WorkspaceId", "Create capacity policy set '$DisplayName' on capacity $CapacityId")) {
    return
}

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets"

Write-Verbose "POST $uri"
try {
    $policySet = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -UseBasicParsing -ErrorAction Stop
}
catch {
    throw (Get-FabricErrorText -ErrorRecord $_)
}

Write-Verbose "Created policy set $($policySet.id)"
$policySet
