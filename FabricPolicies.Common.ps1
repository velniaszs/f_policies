#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the Fabric Policies (PolicySet) private-preview REST APIs.
.DESCRIPTION
    Dot-source this file from the operation scripts:
        . (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')

    Authentication uses the Microsoft Entra client credentials flow (app-only).
    Supply the service principal either via parameters on each script, or via
    environment variables:

        $env:FABRIC_TENANT_ID
        $env:FABRIC_CLIENT_ID
        $env:FABRIC_CLIENT_SECRET

    The service principal needs the Fabric tenant setting "Service principals can
    use Fabric APIs" enabled, plus the app permissions required by each operation.
#>

Set-StrictMode -Version Latest

$script:FabricApiBaseUrl  = 'https://api.fabric.microsoft.com/v1'
$script:FabricApiScope    = 'https://api.fabric.microsoft.com/.default'
$script:FabricAuthority   = 'https://login.microsoftonline.com'

$script:FabricTenantId     = $null
$script:FabricClientId     = $null
$script:FabricClientSecret = $null   # SecureString
$script:FabricAccessToken  = $null
$script:FabricTokenExpiry  = [datetime]::MinValue

function Set-FabricCredential {
    <#
    .SYNOPSIS
        Stores the service principal used for the client credentials flow and clears any cached token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][securestring]$ClientSecret
    )

    $script:FabricTenantId     = $TenantId
    $script:FabricClientId     = $ClientId
    $script:FabricClientSecret = $ClientSecret
    $script:FabricAccessToken  = $null
    $script:FabricTokenExpiry  = [datetime]::MinValue
}

function Initialize-FabricAuth {
    <#
    .SYNOPSIS
        Resolves the service principal from explicit parameters or environment variables.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantId,
        [string]$ClientId,
        [securestring]$ClientSecret
    )

    if (-not $TenantId)     { $TenantId = $env:FABRIC_TENANT_ID }
    if (-not $ClientId)     { $ClientId = $env:FABRIC_CLIENT_ID }
    if (-not $ClientSecret -and $env:FABRIC_CLIENT_SECRET) {
        $ClientSecret = ConvertTo-SecureString $env:FABRIC_CLIENT_SECRET -AsPlainText -Force
    }

    if (-not $TenantId -or -not $ClientId -or -not $ClientSecret) {
        throw 'Missing credentials. Pass -TenantId/-ClientId/-ClientSecret, or set $env:FABRIC_TENANT_ID, $env:FABRIC_CLIENT_ID and $env:FABRIC_CLIENT_SECRET.'
    }

    Set-FabricCredential -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
}

function Get-FabricToken {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:FabricAccessToken -and (Get-Date) -lt $script:FabricTokenExpiry) {
        return $script:FabricAccessToken
    }

    if (-not $script:FabricTenantId) { Initialize-FabricAuth }

    $secret = [System.Net.NetworkCredential]::new('', $script:FabricClientSecret).Password

    $body = @{
        client_id     = $script:FabricClientId
        client_secret = $secret
        scope         = $script:FabricApiScope
        grant_type    = 'client_credentials'
    }

    $tokenUri = '{0}/{1}/oauth2/v2.0/token' -f $script:FabricAuthority, $script:FabricTenantId

    try {
        $response = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Token request failed for client $($script:FabricClientId): $(Get-FabricErrorText -ErrorRecord $_)"
    }
    finally {
        $secret = $null
        $body   = $null
    }

    $script:FabricAccessToken = $response.access_token
    # Renew a minute early to avoid using a token that expires mid-request.
    $script:FabricTokenExpiry = (Get-Date).AddSeconds([int]$response.expires_in - 60)

    $script:FabricAccessToken
}

function Get-FabricErrorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $status = ''
    $body   = $null

    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    }
    else {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $stream.Position = 0
            $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        }
        catch { }
    }

    $detail = $body
    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.PSObject.Properties.Name -contains 'errorCode') {
                $detail = '{0} - {1}' -f $parsed.errorCode, $parsed.message
                if ($parsed.PSObject.Properties.Name -contains 'requestId') {
                    $detail += " (requestId: $($parsed.requestId))"
                }
            }
        }
        catch { }
    }

    "Fabric API request failed [$status]. $detail"
}

function Get-FabricRetryAfterSeconds {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    try {
        $headers = $ErrorRecord.Exception.Response.Headers
        $value = $null
        if ($headers -is [System.Net.WebHeaderCollection]) { $value = $headers['Retry-After'] }
        else { $value = ($headers.GetValues('Retry-After') | Select-Object -First 1) }
        if ($value) { return [int]$value }
    }
    catch { }

    30
}

function Invoke-FabricApi {
    <#
    .SYNOPSIS
        Calls a Fabric REST endpoint, honouring 429 Retry-After and optional continuation-token paging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')]
        [string]$Method,

        # Path relative to https://api.fabric.microsoft.com/v1, e.g. 'workspaces/{id}/policySets'
        [Parameter(Mandatory)]
        [string]$Path,

        [hashtable]$Query,

        $Body,

        # Follow continuationToken and return the flattened contents of the named collection property.
        [string]$CollectionProperty,

        [int]$MaxRetries = 5
    )

    $headers = @{ Authorization = "Bearer $(Get-FabricToken)" }

    $queryPairs = @()
    if ($Query) {
        foreach ($key in $Query.Keys) {
            $value = $Query[$key]
            if ($null -ne $value -and "$value" -ne '') {
                $queryPairs += '{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString("$value")
            }
        }
    }

    $jsonBody = $null
    if ($null -ne $Body) { $jsonBody = $Body | ConvertTo-Json -Depth 25 }

    $collected = @()
    $continuationToken = $null

    while ($true) {
        $pairs = $queryPairs
        if ($continuationToken) {
            $pairs = $pairs + ('continuationToken={0}' -f [uri]::EscapeDataString($continuationToken))
        }

        $uri = '{0}/{1}' -f $script:FabricApiBaseUrl, $Path.TrimStart('/')
        if ($pairs.Count) { $uri += '?' + ($pairs -join '&') }

        Write-Verbose "$Method $uri"

        $attempt = 0
        $response = $null
        while ($true) {
            try {
                $params = @{
                    Uri             = $uri
                    Method          = $Method
                    Headers         = $headers
                    ContentType     = 'application/json; charset=utf-8'
                    UseBasicParsing = $true
                    ErrorAction     = 'Stop'
                }
                if ($jsonBody) { $params.Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody) }

                $raw = Invoke-WebRequest @params
                if ($raw.Content) { $response = $raw.Content | ConvertFrom-Json }
                break
            }
            catch {
                $status = 0
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }

                if ($status -eq 429 -and $attempt -lt $MaxRetries) {
                    $wait = Get-FabricRetryAfterSeconds -ErrorRecord $_
                    Write-Warning "Throttled (429). Retrying in $wait second(s)..."
                    Start-Sleep -Seconds $wait
                    $attempt++
                    continue
                }

                throw (Get-FabricErrorText -ErrorRecord $_)
            }
        }

        if (-not $CollectionProperty) { return $response }

        if ($response -and ($response.PSObject.Properties.Name -contains $CollectionProperty)) {
            $collected += $response.$CollectionProperty
        }

        $continuationToken = $null
        if ($response -and ($response.PSObject.Properties.Name -contains 'continuationToken')) {
            $continuationToken = $response.continuationToken
        }
        if (-not $continuationToken) { return $collected }
    }
}

function Get-FabricPolicyRuleInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$WorkspaceId,
        [Parameter(Mandatory)][guid]$PolicySetId,
        [Parameter(Mandatory)][guid]$PolicyRuleId
    )

    Invoke-FabricApi -Method Get -Path "workspaces/$WorkspaceId/policySets/$PolicySetId/policyRules/$PolicyRuleId"
}
