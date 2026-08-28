#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end example: create a capacity policy set, add a workspace-filtered rule, activate it.
.DESCRIPTION
    Runs the four calls in order and carries the generated IDs forward:

      0. GET  /v1/capacities                                             (list_capacities.ps1)
      1. POST /v1/workspaces/{ws}/policySets                             (new_policy_set.ps1)
      2. POST /v1/workspaces/{ws}/policySets/{ps}/policyRules            (add_policy_rule.ps1)
      3. POST /v1/workspaces/{ws}/policySets/{ps}/activate               (activate_policy_set.ps1)
      4. GET  /v1/workspaces/{ws}/policySets/{ps}                        (get_policy_set.ps1)

    Credentials come from -TenantId/-ClientId/-ClientSecret or the
    FABRIC_TENANT_ID / FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET environment variables.

    Nothing is cleaned up - the policy set is left active. Use remove_policy_set.ps1 -Deactivate
    to tear it down.
.EXAMPLE
    .\call_create_policyset.ps1 -WorkspaceId <ws> -CapacityId <cap> -FilterWorkspaceId <ws1>,<ws2>
.EXAMPLE
    # Take over the capacity from whichever policy set is currently active
    .\call_create_policyset.ps1 -WorkspaceId <ws> -CapacityId <cap> -FilterWorkspaceId <ws1> -AllowReplace
.EXAMPLE
    # Create and add the rule, but leave it inactive
    .\call_create_policyset.ps1 -WorkspaceId <ws> -CapacityId <cap> -FilterWorkspaceId <ws1> -SkipActivate
.EXAMPLE
    # ItemCreation policy instead of external data sharing
    .\call_create_policyset.ps1 -WorkspaceId <ws> -CapacityId <cap> -FilterWorkspaceId <ws1> -Policy ItemCreation
.EXAMPLE
    # Block notebook creation in specific workspaces:
    # allow Notebook creation only where workspace.id is NoneOf the restricted list.
    .\call_create_policyset.ps1 -WorkspaceId <ws> -CapacityId <cap> `
                                -Policy ItemCreation `
                                -FilterItemType Notebook `
                                -FilterWorkspaceId <restricted1>,<restricted2> -Operator NoneOf `
                                -PolicySetDisplayName 'Notebook creation control' `
                                -PolicyRuleDisplayName 'Notebooks outside restricted workspaces' `
                                -PolicyRuleDescription 'Block notebook creation in restricted workspaces'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$CapacityId,

    [guid[]]$FilterWorkspaceId,

    [string[]]$FilterItemType,

    [ValidateSet('AnyOf', 'NoneOf')]
    [string]$ItemTypeOperator = 'AnyOf',

    [string]$PolicySetDisplayName = 'UBS capacity policy set',
    [string]$PolicySetDescription = 'Created by call_create_policyset.ps1',
    [string]$PolicyRuleDisplayName = 'Allow for approved workspaces',
    [string]$PolicyRuleDescription = 'Created by call_create_policyset.ps1',

    [ValidateSet('ExternalDataSharing', 'ItemCreation')]
    [string]$Policy = 'ExternalDataSharing',

    [ValidateSet('AnyOf', 'NoneOf')]
    [string]$Operator = 'AnyOf',

    [switch]$AllowReplace,
    [switch]$SkipActivate,
    [switch]$ListCapacitiesFirst,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Number, [string]$Title)
    Write-Host ''
    Write-Host ("=== {0}) {1} " -f $Number, $Title).PadRight(78, '=') -ForegroundColor Cyan
}

$auth = @{}
if ($TenantId)     { $auth.TenantId = $TenantId }
if ($ClientId)     { $auth.ClientId = $ClientId }
if ($ClientSecret) { $auth.ClientSecret = $ClientSecret }

# ---------------------------------------------------------------------------
# 0) GET /v1/capacities
# ---------------------------------------------------------------------------
if ($ListCapacitiesFirst) {
    Write-Step -Number 0 -Title 'List capacities'
    & (Join-Path $PSScriptRoot 'list_capacities.ps1') @auth |
        Format-Table -AutoSize | Out-Host
}

# ---------------------------------------------------------------------------
# 1) POST /v1/workspaces/{workspaceId}/policySets
# ---------------------------------------------------------------------------
Write-Step -Number 1 -Title "Create capacity policy set on $CapacityId"

$policySet = & (Join-Path $PSScriptRoot 'new_policy_set.ps1') @auth `
    -WorkspaceId $WorkspaceId `
    -CapacityId $CapacityId `
    -DisplayName $PolicySetDisplayName `
    -Description $PolicySetDescription `
    -Confirm:$false

Write-Host "Policy set id: $($policySet.id)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2) POST /v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules
# ---------------------------------------------------------------------------
$ruleArgs = @{}
if ($FilterWorkspaceId) { $ruleArgs.FilterWorkspaceId = $FilterWorkspaceId; $ruleArgs.Operator = $Operator }
if ($FilterItemType)    { $ruleArgs.FilterItemType = $FilterItemType; $ruleArgs.ItemTypeOperator = $ItemTypeOperator }

$filterSummary = @()
if ($FilterWorkspaceId) { $filterSummary += "workspace.id $Operator" }
if ($FilterItemType)    { $filterSummary += "item.type $ItemTypeOperator $($FilterItemType -join ',')" }

Write-Step -Number 2 -Title "Add '$Policy' rule ($($filterSummary -join '; '))"

$rule = & (Join-Path $PSScriptRoot 'add_policy_rule.ps1') @auth @ruleArgs `
    -WorkspaceId $WorkspaceId `
    -PolicySetId $policySet.id `
    -DisplayName $PolicyRuleDisplayName `
    -Description $PolicyRuleDescription `
    -Policy $Policy `
    -Confirm:$false

Write-Host "Policy rule id: $($rule.id)" -ForegroundColor Green
$rule.conditions | ConvertTo-Json -Depth 10 | Out-Host

# ---------------------------------------------------------------------------
# 3) POST /v1/workspaces/{workspaceId}/policySets/{policySetId}/activate
# ---------------------------------------------------------------------------
if ($SkipActivate) {
    Write-Step -Number 3 -Title 'Activate (skipped)'
    Write-Host 'Skipped - policy set stays Inactive.' -ForegroundColor Yellow
}
else {
    Write-Step -Number 3 -Title "Activate on Capacity scope $CapacityId"

    & (Join-Path $PSScriptRoot 'activate_policy_set.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -PolicySetId $policySet.id `
        -AllowReplace:$AllowReplace `
        -Confirm:$false
}

# ---------------------------------------------------------------------------
# 4) GET /v1/workspaces/{workspaceId}/policySets/{policySetId}
# ---------------------------------------------------------------------------
Write-Step -Number 4 -Title 'Verify'

$final = & (Join-Path $PSScriptRoot 'get_policy_set.ps1') @auth `
    -WorkspaceId $WorkspaceId `
    -PolicySetId $policySet.id `
    -IncludeRules

$final | ConvertTo-Json -Depth 10 | Out-Host

Write-Host ''
Write-Host "Status: $($final.properties.status)" -ForegroundColor Cyan
Write-Host "Tear down with: .\remove_policy_set.ps1 -WorkspaceId $WorkspaceId -PolicySetId $($policySet.id) -Deactivate"
