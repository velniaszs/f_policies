#Requires -Version 5.1
<#
.SYNOPSIS
    Adds a policy rule to a capacity-scoped policy set, filtered on workspace IDs.
.DESCRIPTION
    Creates a rule with a single Dynamic condition on 'workspace.id' and an Allow effect.
    Use -Operator NoneOf to invert the filter (allow everywhere except the listed workspaces).
.EXAMPLE
    .\add_policy_rule.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 `
                          -PolicySetId 41ce06d1-d81b-4ea0-bc6d-2ce3dd2f8e87 `
                          -DisplayName 'Allow external sharing for approved workspaces' `
                          -Description 'Approved workspaces only' `
                          -Policy ExternalDataSharing `
                          -FilterWorkspaceId 9763b213-de8c-484f-8e41-e1c9de4c8429
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Description,

    [ValidateSet('ExternalDataSharing', 'ItemCreation')]
    [string]$Policy = 'ExternalDataSharing',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [guid[]]$FilterWorkspaceId,

    [ValidateSet('AnyOf', 'NoneOf')]
    [string]$Operator = 'AnyOf',

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
    policy      = $Policy
    conditions  = @(
        @{
            type           = 'Dynamic'
            targetProperty = 'workspace.id'
            predicate      = @{
                operator = $Operator
                # Force an array so a single ID still serialises as a JSON list.
                values   = @($FilterWorkspaceId | ForEach-Object { $_.ToString() })
            }
        }
    )
    effects     = @(
        @{ type = 'Allow' }
    )
}

if (-not $PSCmdlet.ShouldProcess("policy set $PolicySetId", "Create '$Policy' rule '$DisplayName' ($Operator on $($FilterWorkspaceId.Count) workspace(s))")) {
    return
}

Invoke-FabricApi -Method Post -Path "workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules" -Body $body
