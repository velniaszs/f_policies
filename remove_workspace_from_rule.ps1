#Requires -Version 5.1
<#
.SYNOPSIS
    Removes one or more workspace IDs from the 'workspace.id' filter of an existing policy rule.
.DESCRIPTION
    GET   https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules/{policyRuleId}
    PATCH https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules/{policyRuleId}

    Reads the rule, drops the given IDs from the predicate values of its 'workspace.id'
    condition, and PATCHes the full conditions array back (PATCH replaces conditions wholesale).

    If the removal would leave the filter empty, the script stops - the API rejects an empty
    values list (PropertyMinCount). Delete the rule instead with remove_policy_rule.ps1.
.EXAMPLE
    .\remove_workspace_from_rule.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 `
                                     -PolicySetId 41ce06d1-d81b-4ea0-bc6d-2ce3dd2f8e87 `
                                     -PolicyRuleId 00013c9d-062a-4f92-8eda-cef8503426bc `
                                     -FilterWorkspaceId 9763b213-de8c-484f-8e41-e1c9de4c8429
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [Parameter(Mandatory)][guid]$PolicyRuleId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [guid[]]$FilterWorkspaceId,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$ruleUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules/$PolicyRuleId"

Write-Verbose "GET $ruleUri"
try {
    $rule = Invoke-RestMethod -Uri $ruleUri -Method Get -Headers $headers `
        -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
}
catch {
    throw (Get-FabricErrorText -ErrorRecord $_)
}

$condition = $rule.conditions | Where-Object {
    $_.type -eq 'Dynamic' -and $_.targetProperty -eq 'workspace.id'
} | Select-Object -First 1

if (-not $condition) {
    throw "Policy rule $PolicyRuleId has no Dynamic condition on 'workspace.id'."
}

$toRemove = $FilterWorkspaceId | ForEach-Object { $_.ToString() }
$current  = @($condition.predicate.values)
$retained = @($current | Where-Object { $toRemove -notcontains $_ })

$removed = @($current | Where-Object { $toRemove -contains $_ })
if (-not $removed.Count) {
    Write-Warning "None of the specified workspace IDs are present in rule $PolicyRuleId. Nothing to do."
    return $rule
}

if (-not $retained.Count) {
    throw "Removing those workspace IDs would leave rule $PolicyRuleId with an empty filter. Delete the rule instead (remove_policy_rule.ps1)."
}

# PATCH replaces the whole conditions array, so rebuild every condition, not just the edited one.
$conditions = foreach ($existing in $rule.conditions) {
    if ($existing -eq $condition) {
        @{
            type           = $existing.type
            targetProperty = $existing.targetProperty
            predicate      = @{
                operator = $existing.predicate.operator
                values   = $retained
            }
        }
    }
    elseif ($existing.type -eq 'Dynamic') {
        @{
            type           = $existing.type
            targetProperty = $existing.targetProperty
            predicate      = @{
                operator = $existing.predicate.operator
                values   = @($existing.predicate.values)
            }
        }
    }
    else {
        @{ type = $existing.type; value = $existing.value }
    }
}

$body = @{ conditions = @($conditions) } | ConvertTo-Json -Depth 10

if (-not $PSCmdlet.ShouldProcess("policy rule $PolicyRuleId", "Remove $($removed.Count) workspace ID(s) from the workspace.id filter")) {
    return
}

Write-Verbose "PATCH $ruleUri"
try {
    Invoke-RestMethod -Uri $ruleUri -Method Patch -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -UseBasicParsing -ErrorAction Stop
}
catch {
    throw (Get-FabricErrorText -ErrorRecord $_)
}
