#Requires -Version 5.1
<#
.SYNOPSIS
    Test harness that calls every Fabric Policies script in this repo as a worked example.
.DESCRIPTION
    Runs a full policy set lifecycle end to end. Fill in the parameters below (or pass them
    on the command line) before running. Credentials left empty fall back to the
    FABRIC_TENANT_ID / FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET environment variables.

    Use -Step to run only part of the sequence, together with -PolicySetId / -PolicyRuleId
    to target objects that already exist.

    FOR TEST PURPOSES ONLY - do not commit real credentials into this file.
.EXAMPLE
    .\main.ps1 -WorkspaceId <ws> -CapacityId <cap> -FilterWorkspaceId <ws1>,<ws2>
.EXAMPLE
    .\main.ps1 -Step List -WorkspaceId <ws>
.EXAMPLE
    .\main.ps1 -Step AddRule,RemoveWorkspaceFromRule -WorkspaceId <ws> -PolicySetId <ps> -FilterWorkspaceId <ws1>,<ws2>
#>
[CmdletBinding()]
param(
    # --- Authentication (service principal). Empty = fall back to environment variables. ---
    [string]$TenantId     = '',
    [string]$ClientId     = '',
    [string]$ClientSecret = '',

    # --- Target objects ---
    [string]$WorkspaceId = '',
    [string]$CapacityId  = '',

    # Two or more workspace IDs: step 5 removes the first one and keeps the rest.
    [string[]]$FilterWorkspaceId = @('', ''),

    # --- Reuse existing objects instead of creating them ---
    [string]$PolicySetId  = '',
    [string]$PolicyRuleId = '',

    # --- Payload values ---
    [string]$PolicySetDisplayName = 'Test capacity policy set',
    [string]$PolicySetDescription = 'Created by main.ps1 for testing.',
    [string]$PolicyRuleDisplayName = 'Test workspace filter rule',
    [string]$PolicyRuleDescription = 'Created by main.ps1 for testing.',

    [ValidateSet('ExternalDataSharing', 'ItemCreation')]
    [string]$Policy = 'ExternalDataSharing',

    [ValidateSet('AnyOf', 'NoneOf')]
    [string]$Operator = 'AnyOf',

    [ValidateSet('List', 'Create', 'Get', 'AddRule', 'RemoveWorkspaceFromRule', 'RemoveRule', 'RemovePolicySet')]
    [string[]]$Step = @('List', 'Create', 'Get', 'AddRule', 'RemoveWorkspaceFromRule', 'RemoveRule', 'RemovePolicySet')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Number, [string]$Title)
    Write-Host ''
    Write-Host ("=== {0}) {1} " -f $Number, $Title).PadRight(78, '=') -ForegroundColor Cyan
}

function Assert-Guid {
    param([string]$Value, [string]$Name)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "Parameter -$Name must be a GUID. Current value: '$Value'."
    }
}

# Only non-empty values are splatted, so the scripts can fall back to environment variables.
$auth = @{}
if ($TenantId)     { $auth.TenantId = $TenantId }
if ($ClientId)     { $auth.ClientId = $ClientId }
if ($ClientSecret) { $auth.ClientSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force }

Assert-Guid -Value $WorkspaceId -Name 'WorkspaceId'

# ---------------------------------------------------------------------------
# 1) List policy sets
# ---------------------------------------------------------------------------
if ($Step -contains 'List') {
    Write-Step -Number 1 -Title 'List policy sets'

    & (Join-Path $PSScriptRoot 'list_policy_sets.ps1') @auth -WorkspaceId $WorkspaceId |
        Format-Table -AutoSize | Out-Host
}

# ---------------------------------------------------------------------------
# 2) Create a capacity-level policy set
# ---------------------------------------------------------------------------
if ($Step -contains 'Create') {
    Write-Step -Number 2 -Title 'Create capacity-level policy set'
    Assert-Guid -Value $CapacityId -Name 'CapacityId'

    $created = & (Join-Path $PSScriptRoot 'new_policy_set.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -CapacityId $CapacityId `
        -DisplayName $PolicySetDisplayName `
        -Description $PolicySetDescription `
        -Confirm:$false

    $PolicySetId = $created.id
    Write-Host "Created policy set: $PolicySetId" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 3) Get the policy set
# ---------------------------------------------------------------------------
if ($Step -contains 'Get') {
    Write-Step -Number 3 -Title 'Get policy set'
    Assert-Guid -Value $PolicySetId -Name 'PolicySetId'

    & (Join-Path $PSScriptRoot 'get_policy_set.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -PolicySetId $PolicySetId `
        -IncludeRules |
        ConvertTo-Json -Depth 10 | Out-Host
}

# ---------------------------------------------------------------------------
# 4) Add a policy rule filtered on workspace IDs
# ---------------------------------------------------------------------------
if ($Step -contains 'AddRule') {
    Write-Step -Number 4 -Title 'Add policy rule with workspace filter'
    Assert-Guid -Value $PolicySetId -Name 'PolicySetId'

    if ($FilterWorkspaceId.Count -lt 2) {
        throw 'Provide at least two -FilterWorkspaceId values so that step 5 has something to remove.'
    }
    foreach ($id in $FilterWorkspaceId) { Assert-Guid -Value $id -Name 'FilterWorkspaceId' }

    $rule = & (Join-Path $PSScriptRoot 'add_policy_rule.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -PolicySetId $PolicySetId `
        -DisplayName $PolicyRuleDisplayName `
        -Description $PolicyRuleDescription `
        -Policy $Policy `
        -FilterWorkspaceId $FilterWorkspaceId `
        -Operator $Operator `
        -Confirm:$false

    $PolicyRuleId = $rule.id
    Write-Host "Created policy rule: $PolicyRuleId" -ForegroundColor Green
    $rule.conditions | ConvertTo-Json -Depth 10 | Out-Host
}

# ---------------------------------------------------------------------------
# 5) Remove the first workspace from the rule's filter
# ---------------------------------------------------------------------------
if ($Step -contains 'RemoveWorkspaceFromRule') {
    Write-Step -Number 5 -Title 'Remove a workspace from the rule filter'
    Assert-Guid -Value $PolicySetId -Name 'PolicySetId'
    Assert-Guid -Value $PolicyRuleId -Name 'PolicyRuleId'

    $target = $FilterWorkspaceId | Select-Object -First 1
    Assert-Guid -Value $target -Name 'FilterWorkspaceId'

    $updated = & (Join-Path $PSScriptRoot 'remove_workspace_from_rule.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -PolicySetId $PolicySetId `
        -PolicyRuleId $PolicyRuleId `
        -FilterWorkspaceId $target `
        -Confirm:$false

    Write-Host "Removed $target from the filter." -ForegroundColor Green
    $updated.conditions | ConvertTo-Json -Depth 10 | Out-Host
}

# ---------------------------------------------------------------------------
# 6) Delete the policy rule
# ---------------------------------------------------------------------------
if ($Step -contains 'RemoveRule') {
    Write-Step -Number 6 -Title 'Delete policy rule'
    Assert-Guid -Value $PolicySetId -Name 'PolicySetId'
    Assert-Guid -Value $PolicyRuleId -Name 'PolicyRuleId'

    & (Join-Path $PSScriptRoot 'remove_policy_rule.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -PolicySetId $PolicySetId `
        -PolicyRuleId $PolicyRuleId `
        -Confirm:$false

    Write-Host "Deleted policy rule: $PolicyRuleId" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 7) Delete the policy set
# ---------------------------------------------------------------------------
if ($Step -contains 'RemovePolicySet') {
    Write-Step -Number 7 -Title 'Delete policy set'
    Assert-Guid -Value $PolicySetId -Name 'PolicySetId'

    & (Join-Path $PSScriptRoot 'remove_policy_set.ps1') @auth `
        -WorkspaceId $WorkspaceId `
        -PolicySetId $PolicySetId `
        -Deactivate `
        -Confirm:$false

    Write-Host "Deleted policy set: $PolicySetId" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
