#Requires -Version 5.1
<#
.SYNOPSIS
    Gets a policy set, optionally including its policy rules.
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

$policySet = Invoke-FabricApi -Method Get -Path "workspaces/$WorkspaceId/policySets/$PolicySetId"

if ($IncludeRules) {
    $rules = Invoke-FabricApi -Method Get `
        -Path "workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules" `
        -CollectionProperty 'value'

    $policySet | Add-Member -NotePropertyName 'policyRules' -NotePropertyValue $rules -Force
}

$policySet
