#Requires -Version 5.1
<#
.SYNOPSIS
    Gets a policy set, optionally including its policy rules.
.DESCRIPTION
    GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}
    GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules
.EXAMPLE
    .\get_policy_set.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 `
                         -PolicySetId 5b218778-e7a5-4d73-8187-f10824047715 -IncludeRules
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [switch]$IncludeRules,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }

$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId"
Write-Verbose "GET $uri"
try {
    $policySet = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
        -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
}
catch {
    throw (Get-FabricErrorText -ErrorRecord $_)
}

if ($IncludeRules) {
    $rulesUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules"
    $rules = @()

    do {
        Write-Verbose "GET $rulesUri"
        try {
            $response = Invoke-RestMethod -Uri $rulesUri -Method Get -Headers $headers `
                -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
        }
        catch {
            throw (Get-FabricErrorText -ErrorRecord $_)
        }

        $rules += $response.value

        $rulesUri = $null
        if ($response.PSObject.Properties.Name -contains 'continuationUri') { $rulesUri = $response.continuationUri }
    }
    while ($rulesUri)

    $policySet | Add-Member -NotePropertyName 'policyRules' -NotePropertyValue $rules -Force
}

$policySet
