#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a policy set in a workspace (Items - Create Policy Set).
.DESCRIPTION
    POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/policySets

    Body (CreatePolicySetRequest):
        {
          "displayName": "...",
          "description": "...",
          "folderId": "<uuid>",
          "creationPayload": { "scope": { "type": "Tenant" | "Capacity", "id": "<uuid>" } }
        }

    "creationPayload" and "definition" are mutually exclusive. Use -DefinitionPayload to send a
    policySet.json item definition instead of a creation payload, or -BodyJson for a hand-written body.

    The operation is long running: the service answers 201 with the created policy set, or 202 with
    Location / x-ms-operation-id / Retry-After headers. On 202 this script polls the operation until it
    completes and then returns the created policy set, unless -NoWait is specified.

    Permissions: contributor workspace role. Scope: Item.ReadWrite.All.
    The workspace must be on a supported Fabric capacity.
.EXAMPLE
    # Capacity-scoped policy set
    .\new_policy_set.ps1 -WorkspaceId <ws> -CapacityId <cap> -DisplayName 'Test policy set' -Verbose
.EXAMPLE
    # Tenant-scoped policy set
    .\new_policy_set.ps1 -WorkspaceId <ws> -ScopeType Tenant -DisplayName 'Tenant policy set'
.EXAMPLE
    # Create from an item definition (policySet.json), policy rules included
    .\new_policy_set.ps1 -WorkspaceId <ws> -DisplayName 'Test policy set' -DefinitionPayload @'
    {
      "properties": { "scope": { "type": "Capacity" } },
      "policyRules": [
        {
          "displayName": "Item Creation Policy",
          "description": "Allow specific item types",
          "policy": "ItemCreation",
          "conditions": [
            { "type": "Dynamic", "targetProperty": "item.type",
              "predicate": { "operator": "AnyOf", "values": [ "Notebook" ] } }
          ],
          "then": [ { "effect": "Allow" } ]
        }
      ]
    }
'@
.EXAMPLE
    # Hand-written body; -ScopeType and -CapacityId are ignored when -BodyJson is used
    .\new_policy_set.ps1 -WorkspaceId <ws> -DisplayName 'ignored' -BodyJson @'
    {
      "displayName": "Test policy set",
      "creationPayload": { "scope": { "type": "Capacity", "id": "<cap>" } }
    }
'@
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'CreationPayload')]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][string]$DisplayName,

    [Parameter(ParameterSetName = 'CreationPayload')]
    [ValidateSet('Tenant', 'Capacity')]
    [string]$ScopeType = 'Capacity',

    [Parameter(ParameterSetName = 'CreationPayload')]
    [guid]$CapacityId,

    # Contents of the policySet.json definition part, as raw JSON - base64 encoding is done here.
    [Parameter(Mandatory, ParameterSetName = 'Definition')]
    [string]$DefinitionPayload,

    # Contents of the .platform definition part, as raw JSON.
    [Parameter(ParameterSetName = 'Definition')]
    [string]$PlatformPayload,

    [ValidateLength(0, 256)]
    [string]$Description = '',

    [guid]$FolderId,

    [Parameter(Mandatory, ParameterSetName = 'BodyJson')]
    [string]$BodyJson,

    # Return the 202 operation details instead of waiting for provisioning to finish.
    [switch]$NoWait,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

function Get-ResponseHeader {
    param($Response, [string]$Name)

    $key = $Response.Headers.Keys | Where-Object { $_ -eq $Name } | Select-Object -First 1
    if (-not $key) { return $null }

    $value = $Response.Headers[$key]
    if ($value -is [array]) { return $value[0] }
    $value
}

switch ($PSCmdlet.ParameterSetName) {
    'BodyJson' {
        $body = $BodyJson
        $action = 'Create policy set from the supplied body'
    }
    'Definition' {
        $parts = @(
            @{
                path        = 'policySet.json'
                payload     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($DefinitionPayload))
                payloadType = 'InlineBase64'
            }
        )
        if ($PlatformPayload) {
            $parts += @{
                path        = '.platform'
                payload     = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($PlatformPayload))
                payloadType = 'InlineBase64'
            }
        }

        $bodyMap = @{
            displayName = $DisplayName
            description = $Description
            definition  = @{ parts = $parts }
        }
        if ($PSBoundParameters.ContainsKey('FolderId')) { $bodyMap.folderId = $FolderId.ToString() }

        $body = $bodyMap | ConvertTo-Json -Depth 10
        $action = "Create policy set '$DisplayName' from an item definition"
    }
    default {
        $scope = @{ type = $ScopeType }
        if ($ScopeType -eq 'Capacity') {
            if (-not $PSBoundParameters.ContainsKey('CapacityId')) {
                throw '-CapacityId is required when -ScopeType is Capacity.'
            }
            $scope.id = $CapacityId.ToString()
        }
        elseif ($PSBoundParameters.ContainsKey('CapacityId')) {
            throw '-CapacityId cannot be combined with -ScopeType Tenant.'
        }

        $bodyMap = @{
            displayName     = $DisplayName
            description     = $Description
            creationPayload = @{ scope = $scope }
        }
        if ($PSBoundParameters.ContainsKey('FolderId')) { $bodyMap.folderId = $FolderId.ToString() }

        $body = $bodyMap | ConvertTo-Json -Depth 10
        $action = "Create $ScopeType policy set '$DisplayName'"
        if ($ScopeType -eq 'Capacity') { $action += " on capacity $CapacityId" }
    }
}

if (-not $PSCmdlet.ShouldProcess("workspace $WorkspaceId", $action)) {
    return
}

$headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets"

Write-Verbose "POST $uri"
Write-Verbose $body
try {
    $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ContentType 'application/json; charset=utf-8' -UseBasicParsing -ErrorAction Stop
}
catch {
    Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    throw
}

if ([int]$response.StatusCode -ne 202) {
    $policySet = $response.Content | ConvertFrom-Json
    Write-Verbose "Created policy set $($policySet.id)"
    return $policySet
}

# 202 Accepted - provisioning continues asynchronously.
$operationId = Get-ResponseHeader -Response $response -Name 'x-ms-operation-id'
$location    = Get-ResponseHeader -Response $response -Name 'Location'
$retryAfter  = Get-ResponseHeader -Response $response -Name 'Retry-After'
if (-not $retryAfter) { $retryAfter = 30 }

Write-Verbose "Accepted (202). operationId=$operationId location=$location retryAfter=$retryAfter"

if ($NoWait) {
    return [pscustomobject]@{
        status      = 'Accepted'
        operationId = $operationId
        location    = $location
        retryAfter  = [int]$retryAfter
    }
}

if (-not $operationId) {
    throw 'The service returned 202 without an x-ms-operation-id header, so the operation cannot be polled. Re-run with -NoWait.'
}

$operationUri = "https://api.fabric.microsoft.com/v1/operations/$operationId"
do {
    Start-Sleep -Seconds ([int]$retryAfter)

    $headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
    Write-Verbose "GET $operationUri"
    try {
        $operation = Invoke-RestMethod -Uri $operationUri -Method Get -Headers $headers -ErrorAction Stop
    }
    catch {
        Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
        throw
    }

    Write-Verbose "Operation status: $($operation.status)"
}
while ($operation.status -in @('NotStarted', 'Running', 'Undefined'))

if ($operation.status -ne 'Succeeded') {
    throw "Policy set creation operation $operationId ended with status '$($operation.status)'. $($operation.error.errorCode) - $($operation.error.message)"
}

try {
    $policySet = Invoke-RestMethod -Uri "$operationUri/result" -Method Get -Headers $headers -ErrorAction Stop
}
catch {
    Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    throw
}

Write-Verbose "Created policy set $($policySet.id)"
$policySet
