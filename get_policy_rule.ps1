#Requires -Version 5.1
<#
.SYNOPSIS
    Gets a single policy rule, or lists all policy rules in a policy set.
.DESCRIPTION
    GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules/{policyRuleId}
    GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules

    Omit -PolicyRuleId to list every rule in the policy set (paged).
    Requires Item.Read.All or Item.ReadWrite.All.
.EXAMPLE
    .\get_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> -PolicyRuleId <rule>
.EXAMPLE
    .\get_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> | Format-Table
.EXAMPLE
    # Show the workspace IDs each rule filters on
    .\get_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> -ShowFilters
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [guid]$PolicyRuleId,

    [switch]$ShowFilters,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules"

$rules = @()

if ($PSBoundParameters.ContainsKey('PolicyRuleId')) {
    $uri = "$base/$PolicyRuleId"
    Write-Verbose "GET $uri"
    try {
        $rules = @(Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
            -ContentType 'application/json' -ErrorAction Stop)
    }
    catch {
        Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
        throw
    }
}
else {
    $uri = $base
    do {
        Write-Verbose "GET $uri"
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
                -ContentType 'application/json' -ErrorAction Stop
        }
        catch {
            Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
            throw
        }

        $rules += $response.value

        $uri = $null
        if ($response.PSObject.Properties.Name -contains 'continuationUri') { $uri = $response.continuationUri }
    }
    while ($uri)
}

if ($ShowFilters) {
    $rules | Select-Object `
        id,
        displayName,
        policy,
        @{ Name = 'operator'; Expression = {
            ($_.conditions | Where-Object { $_.type -eq 'Dynamic' -and $_.targetProperty -eq 'workspace.id' }).predicate.operator
        } },
        @{ Name = 'filterWorkspaceIds'; Expression = {
            ($_.conditions | Where-Object { $_.type -eq 'Dynamic' -and $_.targetProperty -eq 'workspace.id' }).predicate.values -join ', '
        } },
        lastModifiedDateTime
}
else {
    $rules
}
