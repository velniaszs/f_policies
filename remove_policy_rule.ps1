#Requires -Version 5.1
<#
.SYNOPSIS
    Deletes a policy rule from a policy set.
.DESCRIPTION
    DELETE https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules/{policyRuleId}
.EXAMPLE
    .\remove_policy_rule.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 `
                             -PolicySetId 5b218778-e7a5-4d73-8187-f10824047715 `
                             -PolicyRuleId 00013c9d-062a-4f92-8eda-cef8503426bc
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [Parameter(Mandatory)][guid]$PolicyRuleId,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

if (-not $PSCmdlet.ShouldProcess("policy rule $PolicyRuleId in policy set $PolicySetId", 'Delete')) {
    return
}

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules/$PolicyRuleId"

Write-Verbose "DELETE $uri"
try {
    Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers `
        -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop | Out-Null
}
catch {
    throw (Get-FabricErrorText -ErrorRecord $_)
}

Write-Verbose "Deleted policy rule $PolicyRuleId"
