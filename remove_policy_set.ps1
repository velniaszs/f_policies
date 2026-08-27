#Requires -Version 5.1
<#
.SYNOPSIS
    Deletes a policy set, optionally deactivating it from its scope first.
.DESCRIPTION
    POST   https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}/deactivate  (-Deactivate)
    DELETE https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets/{policySetId}

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

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$PolicySetId"

if ($Deactivate) {
    Write-Verbose "GET $uri"
    try {
        $policySet = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers `
            -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw (Get-FabricErrorText -ErrorRecord $_)
    }

    if ($policySet.properties.status -eq 'Active') {
        $scopeType = $policySet.properties.scope.type
        if ($PSCmdlet.ShouldProcess("policy set $PolicySetId", "Deactivate from $scopeType scope")) {
            $deactivateUri = "$uri/deactivate"
            $deactivateBody = @{ scopeType = $scopeType } | ConvertTo-Json

            Write-Verbose "POST $deactivateUri"
            try {
                Invoke-RestMethod -Uri $deactivateUri -Method Post -Headers $headers `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($deactivateBody)) `
                    -ContentType 'application/json; charset=utf-8' -UseBasicParsing -ErrorAction Stop | Out-Null
            }
            catch {
                throw (Get-FabricErrorText -ErrorRecord $_)
            }

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

Write-Verbose "DELETE $uri"
try {
    Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers `
        -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop | Out-Null
}
catch {
    throw (Get-FabricErrorText -ErrorRecord $_)
}

Write-Verbose "Deleted policy set $PolicySetId"
