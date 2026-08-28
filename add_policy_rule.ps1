#Requires -Version 5.1
<#
.SYNOPSIS
    Adds a policy rule, filtered on workspace IDs and/or item types.
.DESCRIPTION
    POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/policyRules

    Builds Dynamic conditions on 'workspace.id' and/or 'item.type' with an Allow effect.
    All conditions in a rule are ANDed - the effect applies only when every one matches.

    The API defines no Deny effect, so restrictions are expressed as allow-lists:
    use -Operator / -ItemTypeOperator NoneOf to exclude values.

    Each target property may appear only once per rule (DuplicateConditionTargetProperty).
.EXAMPLE
    # Allow external sharing only from approved workspaces
    .\add_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> `
                          -DisplayName 'Approved sharing' -Description 'Approved workspaces only' `
                          -Policy ExternalDataSharing `
                          -FilterWorkspaceId <ws1>,<ws2>
.EXAMPLE
    # Allow notebook creation everywhere EXCEPT the listed workspaces
    .\add_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> `
                          -DisplayName 'Notebooks outside restricted workspaces' `
                          -Description 'Block notebook creation in restricted workspaces' `
                          -Policy ItemCreation `
                          -FilterItemType Notebook `
                          -FilterWorkspaceId <restricted1>,<restricted2> -Operator NoneOf
.EXAMPLE
    # Allow every item type other than notebooks, anywhere
    .\add_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> `
                          -DisplayName 'All non-notebook items' -Description 'Everything else' `
                          -Policy ItemCreation `
                          -FilterItemType Notebook -ItemTypeOperator NoneOf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Description,

    [ValidateSet('ExternalDataSharing', 'ItemCreation')]
    [string]$Policy = 'ExternalDataSharing',

    [guid[]]$FilterWorkspaceId,

    [ValidateSet('AnyOf', 'NoneOf')]
    [string]$Operator = 'AnyOf',

    [string[]]$FilterItemType,

    [ValidateSet('AnyOf', 'NoneOf')]
    [string]$ItemTypeOperator = 'AnyOf',

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

if (-not $FilterWorkspaceId -and -not $FilterItemType) {
    throw 'Provide -FilterWorkspaceId and/or -FilterItemType; a rule needs at least one condition.'
}

$conditions = @()
$summary = @()

if ($FilterWorkspaceId) {
    $conditions += @{
        type           = 'Dynamic'
        targetProperty = 'workspace.id'
        predicate      = @{
            operator = $Operator
            # Force an array so a single value still serialises as a JSON list.
            values   = @($FilterWorkspaceId | ForEach-Object { $_.ToString() })
        }
    }
    $summary += "workspace.id $Operator $($FilterWorkspaceId.Count) value(s)"
}

if ($FilterItemType) {
    $conditions += @{
        type           = 'Dynamic'
        targetProperty = 'item.type'
        predicate      = @{
            operator = $ItemTypeOperator
            values   = @($FilterItemType)
        }
    }
    $summary += "item.type $ItemTypeOperator $($FilterItemType -join ',')"
}

$body = @{
    displayName = $DisplayName
    description = $Description
    policy      = $Policy
    conditions  = @($conditions)
    effects     = @(
        @{ type = 'Allow' }
    )
} | ConvertTo-Json -Depth 10

if (-not $PSCmdlet.ShouldProcess("policy set $PolicySetId", "Create '$Policy' rule '$DisplayName' ($($summary -join '; '))")) {
    return
}

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules"

Write-Verbose "POST $uri"
Write-Verbose $body
try {
    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
}
catch {
    Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    throw
}
