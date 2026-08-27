#Requires -Version 5.1
<#
.SYNOPSIS
    Authentication helpers for the Fabric Policies (PolicySet) private-preview REST APIs.
.DESCRIPTION
    Dot-source this file from the operation scripts:
        . (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')

    Provides only a token and an error formatter - each script issues its own
    Invoke-RestMethod call so the exact HTTP request stays visible.

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

$script:FabricApiScope    = 'https://api.fabric.microsoft.com/.default'
$script:PowerBiApiScope   = 'https://analysis.windows.net/powerbi/api/.default'
$script:FabricAuthority   = 'https://login.microsoftonline.com'

$script:FabricTenantId     = $null
$script:FabricClientId     = $null
$script:FabricClientSecret = $null   # SecureString
$script:FabricTokenCache   = @{}     # scope -> @{ Token; Expiry }

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
    $script:FabricTokenCache   = @{}
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
    <#
    .SYNOPSIS
        Acquires a client-credentials access token, cached per scope.
    .PARAMETER Scope
        Defaults to the Fabric API. Pass $script:PowerBiApiScope for the Power BI admin APIs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Scope = $script:FabricApiScope
    )

    $cached = $script:FabricTokenCache[$Scope]
    if ($cached -and (Get-Date) -lt $cached.Expiry) {
        return $cached.Token
    }

    if (-not $script:FabricTenantId) { Initialize-FabricAuth }

    $secret = [System.Net.NetworkCredential]::new('', $script:FabricClientSecret).Password

    $body = @{
        client_id     = $script:FabricClientId
        client_secret = $secret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }

    $tokenUri = '{0}/{1}/oauth2/v2.0/token' -f $script:FabricAuthority, $script:FabricTenantId

    try {
        $response = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Token request failed for client $($script:FabricClientId) and scope $($Scope): $(Get-FabricErrorText -ErrorRecord $_)"
    }
    finally {
        $secret = $null
        $body   = $null
    }

    # Renew a minute early to avoid using a token that expires mid-request.
    $script:FabricTokenCache[$Scope] = @{
        Token  = $response.access_token
        Expiry = (Get-Date).AddSeconds([int]$response.expires_in - 60)
    }

    $script:FabricTokenCache[$Scope].Token
}

function Get-FabricErrorText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $status = ''
    $body   = $null

    # PS 7 exposes HttpResponseMessage, PS 5.1 exposes HttpWebResponse; both have StatusCode.
    try {
        $code = $ErrorRecord.Exception.Response.StatusCode
        if ($null -ne $code) { $status = '{0} {1}' -f [int]$code, $code }
    }
    catch { }

    # PS 7 puts the response body here; PS 5.1 usually needs the stream below.
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $body = $ErrorRecord.ErrorDetails.Message
        }
    }
    catch { }

    if (-not $body) {
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

    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    if (-not $status) { $status = 'no HTTP status' }

    "Fabric API request failed [$status]. $detail"
}
