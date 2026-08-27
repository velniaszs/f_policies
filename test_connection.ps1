#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnostics: PowerShell version, network reachability, token contents and a live Fabric API call.
.DESCRIPTION
    Run this first in a new environment to find out where things break. It never prints the
    access token or the client secret - only the token's claims (audience, roles, tenant, expiry).
.EXAMPLE
    .\test_connection.ps1
.EXAMPLE
    .\test_connection.ps1 -TenantId <tenant> -ClientId <app> -ClientSecret (Read-Host -AsSecureString)
#>
[CmdletBinding()]
param(
    [switch]$IncludeAdminApi,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ("--- $Title ").PadRight(70, '-') -ForegroundColor Cyan
}

function ConvertFrom-JwtPayload {
    param([string]$Token)

    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

# --- 1. Environment -----------------------------------------------------------
Write-Section 'PowerShell'
$PSVersionTable | Format-List PSVersion, PSEdition, OS | Out-Host
Write-Host "Invoke-RestMethod supports -Method Patch: $((Get-Command Invoke-RestMethod).Parameters['Method'].ParameterType.GetEnumNames() -contains 'Patch')"

# --- 2. Network ---------------------------------------------------------------
Write-Section 'Network reachability'
foreach ($endpoint in @('login.microsoftonline.com', 'api.fabric.microsoft.com')) {
    try {
        $ok = Test-NetConnection -ComputerName $endpoint -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        Write-Host ("{0,-32} {1}" -f $endpoint, $(if ($ok) { 'reachable on 443' } else { 'BLOCKED' }))
    }
    catch {
        Write-Host ("{0,-32} check failed: {1}" -f $endpoint, $_.Exception.Message)
    }
}

$proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy('https://api.fabric.microsoft.com')
if ($proxy -and $proxy.AbsoluteUri -notlike 'https://api.fabric.microsoft.com*') {
    Write-Host "System proxy in use: $($proxy.AbsoluteUri)"
}

# --- 3. Token -----------------------------------------------------------------
Write-Section 'Token'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')

try {
    Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
}
catch {
    Write-Host "Credential resolution failed: $($_.Exception.Message)" -ForegroundColor Red
    return
}

try {
    $token = Get-FabricToken
}
catch {
    Write-Host "Token request failed: $($_.Exception.Message)" -ForegroundColor Red
    return
}

$claims = ConvertFrom-JwtPayload -Token $token
$roles = if ($claims.PSObject.Properties.Name -contains 'roles') { $claims.roles -join ', ' } else { '(none)' }

[pscustomobject]@{
    Audience  = $claims.aud
    TenantId  = $claims.tid
    AppId     = $claims.appid
    Roles     = $roles
    ExpiresAt = [DateTimeOffset]::FromUnixTimeSeconds($claims.exp).ToLocalTime()
} | Format-List | Out-Host

if ($roles -eq '(none)') {
    Write-Warning 'Token carries no app roles. Grant the app Fabric permissions and admin consent, and enable the "Service principals can use Fabric APIs" tenant setting.'
}

# --- 4. Live call -------------------------------------------------------------
Write-Section 'GET https://api.fabric.microsoft.com/v1/capacities'
try {
    $response = Invoke-RestMethod -Uri 'https://api.fabric.microsoft.com/v1/capacities' -Method Get `
        -Headers @{ Authorization = "Bearer $token" } `
        -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop

    Write-Host "OK - $(@($response.value).Count) capacity/capacities returned." -ForegroundColor Green
    $response.value | Select-Object id, displayName, sku, state | Format-Table -AutoSize | Out-Host
}
catch {
    Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    Write-Host "Raw exception: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
}

if ($IncludeAdminApi) {
    Write-Section 'GET https://api.powerbi.com/v1.0/myorg/admin/capacities'
    try {
        $adminToken = Get-FabricToken -Scope $script:PowerBiApiScope
        $adminResponse = Invoke-RestMethod -Uri 'https://api.powerbi.com/v1.0/myorg/admin/capacities' -Method Get `
            -Headers @{ Authorization = "Bearer $adminToken" } `
            -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop

        Write-Host "OK - $(@($adminResponse.value).Count) capacity/capacities returned." -ForegroundColor Green
    }
    catch {
        Write-Host (Get-FabricErrorText -ErrorRecord $_) -ForegroundColor Red
    }
}
