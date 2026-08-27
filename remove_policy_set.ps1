#Requires -Version 5.1
<#
.SYNOPSIS
    Deletes a policy set, optionally deactivating it from its scope first.
.DESCRIPTION
    An active policy set may need to be deactivated before deletion. Use -Deactivate to
    call the deactivate endpoint for the policy set's own scope type before deleting.
.EXAMPLE
    .\remove_policy_set.ps1 -WorkspaceId cfafbeb1-8037-4d0c-896e-a46fb27ff229 `
                            -PolicySetId 5b218778-e7a5-4d73-8187-f10824047715 -Deactivate
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$PolicySetId,
    [switch]$Deactivate,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

if ($Deactivate) {
    $policySet = Invoke-FabricApi -Method Get -Path "workspaces/$WorkspaceId/policySets/$PolicySetId"

    if ($policySet.properties.status -eq 'Active') {
        $scopeType = $policySet.properties.scope.type
        if ($PSCmdlet.ShouldProcess("policy set $PolicySetId", "Deactivate from $scopeType scope")) {
            Invoke-FabricApi -Method Post `
                -Path "workspaces/$WorkspaceId/policySets/$PolicySetId/deactivate" `
                -Body @{ scopeType = $scopeType } | Out-Null
            Write-Verbose "Deactivated policy set $PolicySetId from $scopeType scope"
        }
    }
    else {
        Write-Verbose "Policy set $PolicySetId is not active; skipping deactivation."
    }
}

if (-not $PSCmdlet.ShouldProcess("policy set $PolicySetId in workspace $WorkspaceId", 'Delete')) {
    return
}

Invoke-FabricApi -Method Delete -Path "workspaces/$WorkspaceId/policySets/$PolicySetId" | Out-Null

Write-Verbose "Deleted policy set $PolicySetId"
