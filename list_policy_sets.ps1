#Requires -Version 5.1
<#
.SYNOPSIS
    Lists policy sets in a workspace.
.DESCRIPTION
    GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets
.EXAMPLE
    .\list_policy_sets.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229
.EXAMPLE
    .\list_policy_sets.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 -Recursive:$false | Format-Table
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [guid]$RootFolderId,
    [bool]$Recursive = $true,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }

$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets" +
       "?recursive=$($Recursive.ToString().ToLowerInvariant())"
if ($PSBoundParameters.ContainsKey('RootFolderId')) { $uri += "&rootFolderId=$RootFolderId" }

$policySets = @()

do {
    Write-Verbose "GET $uri"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
            -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw (Get-FabricErrorText -ErrorRecord $_)
    }

    $policySets += $response.value

    $uri = $null
    if ($response.PSObject.Properties.Name -contains 'continuationUri') { $uri = $response.continuationUri }
}
while ($uri)

$policySets | Select-Object `
    id,
    displayName,
    description,
    @{ Name = 'scopeType'; Expression = { $_.properties.scope.type } },
    @{ Name = 'scopeId';   Expression = { if ($_.properties.scope.PSObject.Properties.Name -contains 'id') { $_.properties.scope.id } } },
    @{ Name = 'status';    Expression = { $_.properties.status } },
    workspaceId
