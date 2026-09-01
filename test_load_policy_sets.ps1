#Requires -Version 5.1
<#
.SYNOPSIS
    Load test: creates many policy sets on a single capacity to measure how the rollout scales.
.DESCRIPTION
    Mimics migrate_policy_sets.ps1 against one capacity you administer, so the shape and volume of the
    real migration can be measured without needing admin rights on every capacity.

    For each of -Count simulated capacities it creates a policy set named "<NamePrefix><nnn>" in
    -WorkspaceId, scoped to -CapacityId, then writes the same rule shape the migration produces:

        Rule 1        - deny all (Allow rule pointing at a sentinel workspace, so it never matches)
        Rule 2..n     - item.type AnyOf [<item type CSV>] AND workspace.id AnyOf [<workspace batch>]

    The workspace count per policy set follows a realistic distribution rather than an even ramp:
    -ZeroWorkspacePercent of the sets get no workspaces at all (deny-all only, no rule 2),
    -SmallWorkspacePercent get 1-2 workspaces, and the remainder are spread up to -MaxWorkspaces with
    the batching boundaries (49, 50, -MaxWorkspaces) always included. Workspace IDs are synthetic
    unless -WorkspaceIdCsvPath supplies real ones.

    Policy sets are never activated - only one policy set can be active on a capacity, and activation is
    not what this test measures.

    Per-operation timings, rule counts and HTTP 429 counts are written to -OutputCsvPath and summarised
    on screen.

    Run with -Cleanup afterwards to delete everything matching -NamePrefix in the workspace.
.EXAMPLE
    # Dry run - shows what would be created, calls nothing
    .\test_load_policy_sets.ps1 -WorkspaceId <ws> -CapacityId <cap> `
                                -ItemTypeCsvPath .\fabric_item_types.csv -WhatIf
.EXAMPLE
    # 200 policy sets with the default distribution
    .\test_load_policy_sets.ps1 -WorkspaceId <ws> -CapacityId <cap> `
                                -ItemTypeCsvPath .\fabric_item_types.csv -Confirm:$false
.EXAMPLE
    # Smaller smoke test first
    .\test_load_policy_sets.ps1 -WorkspaceId <ws> -CapacityId <cap> `
                                -ItemTypeCsvPath .\fabric_item_types.csv -Count 5 -Confirm:$false
.EXAMPLE
    # Tear the test data down
    .\test_load_policy_sets.ps1 -WorkspaceId <ws> -CapacityId <cap> `
                                -ItemTypeCsvPath .\fabric_item_types.csv -Cleanup -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$CapacityId,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ItemTypeCsvPath,

    [ValidateRange(1, 10000)]
    [int]$Count = 200,

    [ValidateRange(0, 10000)]
    [int]$MaxWorkspaces = 60,

    # Share of policy sets with no whitelisted workspaces, so no rule 2 at all.
    [ValidateRange(0, 100)]
    [int]$ZeroWorkspacePercent = 60,

    # Share of policy sets with just 1-2 whitelisted workspaces.
    [ValidateRange(0, 100)]
    [int]$SmallWorkspacePercent = 30,

    # Fixes the distribution so repeated runs are comparable.
    [int]$Seed = 42,

    [string]$NamePrefix = 'loadtest_',

    # Real workspace GUIDs to draw from (single column 'workspace_id'). Synthetic IDs are used when omitted.
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$WorkspaceIdCsvPath,

    [ValidateSet('ExternalDataSharing', 'ItemCreation')]
    [string]$Policy = 'ItemCreation',

    [guid]$DenyAllSentinelWorkspaceId = '00000000-0000-0000-0000-000000000000',

    [ValidateRange(1, 49)]
    [int]$MaxWorkspacesPerRule = 49,

    [ValidateRange(1, 50)]
    [int]$MaxRulesPerPolicy = 50,

    # Pause between policy sets, to model a gentler rollout.
    [int]$DelayBetweenSetsMs = 0,

    [string]$OutputCsvPath = './load_test_results.csv',

    # Delete every policy set whose name starts with -NamePrefix, then exit.
    [switch]$Cleanup,

    [int]$MaxRetries = 5,

    [int]$RetryAfterSeconds = 30,

    [string]$TenantId,
    [string]$ClientId,
    [securestring]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FabricPolicies.Common.ps1')
Initialize-FabricAuth -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

if ($ZeroWorkspacePercent + $SmallWorkspacePercent -gt 100) {
    throw '-ZeroWorkspacePercent plus -SmallWorkspacePercent cannot exceed 100.'
}

$auth = @{}
if ($TenantId)     { $auth.TenantId = $TenantId }
if ($ClientId)     { $auth.ClientId = $ClientId }
if ($ClientSecret) { $auth.ClientSecret = $ClientSecret }

$script:ThrottleCount = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-HttpStatusCode {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function Get-RetryAfterSeconds {
    param($ErrorRecord, [int]$Default)

    try {
        $headers = $ErrorRecord.Exception.Response.Headers
        if ($headers -is [System.Net.WebHeaderCollection]) {
            $value = $headers['Retry-After']
        }
        else {
            $value = $headers.GetValues('Retry-After') | Select-Object -First 1
        }
        if ($value) { return [int]$value }
    }
    catch { }

    $Default
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Description
    )

    $attempt = 0
    while ($true) {
        try {
            return & $Action
        }
        catch {
            if ((Get-HttpStatusCode -ErrorRecord $_) -ne 429 -or $attempt -ge $MaxRetries) { throw }

            $attempt++
            $script:ThrottleCount++
            $wait = Get-RetryAfterSeconds -ErrorRecord $_ -Default $RetryAfterSeconds
            Write-Warning "429 Too Many Requests on $Description. Waiting $wait s (retry $attempt/$MaxRetries)."
            Start-Sleep -Seconds $wait
        }
    }
}

function New-DynamicCondition {
    param(
        [Parameter(Mandatory)][string]$TargetProperty,
        [Parameter(Mandatory)][string]$Operator,
        [Parameter(Mandatory)][string[]]$Values
    )

    @{
        type           = 'Dynamic'
        targetProperty = $TargetProperty
        predicate      = @{ operator = $Operator; values = @($Values) }
    }
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)

    if ($Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $index = [int][Math]::Ceiling($Percentile / 100 * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    $sorted[$index]
}

# ---------------------------------------------------------------------------
# Cleanup mode
# ---------------------------------------------------------------------------

if ($Cleanup) {
    $sets = @(@(Invoke-WithRetry -Description 'list policy sets' -Action {
        & (Join-Path $PSScriptRoot 'list_policy_sets.ps1') @auth -WorkspaceId $WorkspaceId
    }) | Where-Object { $_.displayName -like "$NamePrefix*" })

    if ($sets.Count -eq 0) {
        Write-Host "Nothing to clean up: no policy set in $WorkspaceId starts with '$NamePrefix'." -ForegroundColor Yellow
        return
    }

    Write-Host "Deleting $($sets.Count) policy set(s) named '$NamePrefix*' from workspace $WorkspaceId." -ForegroundColor Cyan

    $deleted = 0
    $index = 0
    $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($set in $sets) {
        $index++
        $deleteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-WithRetry -Description "delete $($set.id)" -Action {
                & (Join-Path $PSScriptRoot 'remove_policy_set.ps1') @auth `
                    -WorkspaceId $WorkspaceId -PolicySetId $set.id -Deactivate -Confirm:$false
            }
            $deleteStopwatch.Stop()
            $deleted++

            Write-Host ("[{0}/{1}] {2,-20} {3}  deleted in {4,6} ms" -f `
                $index, $sets.Count, $set.displayName, $set.id, $deleteStopwatch.ElapsedMilliseconds) -ForegroundColor DarkGray
        }
        catch {
            $deleteStopwatch.Stop()
            Write-Host ("[{0}/{1}] {2,-20} {3}  FAILED: {4}" -f `
                $index, $sets.Count, $set.displayName, $set.id, (Get-FabricErrorText -ErrorRecord $_)) -ForegroundColor Red
        }
    }

    $cleanupStopwatch.Stop()
    Write-Host ''
    Write-Host ("Deleted {0} of {1} in {2:n1} s ({3} HTTP 429 retries)." -f `
        $deleted, $sets.Count, $cleanupStopwatch.Elapsed.TotalSeconds, $script:ThrottleCount) -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

$itemTypeRows = @(Import-Csv -LiteralPath $ItemTypeCsvPath)
if ($itemTypeRows[0].PSObject.Properties.Name -notcontains 'item_type') {
    throw "CSV '$ItemTypeCsvPath' is missing the 'item_type' column."
}

$allowedItemTypes = @(
    $itemTypeRows |
        ForEach-Object { "$($_.item_type)".Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
)
if ($allowedItemTypes.Count -eq 0) { throw "CSV '$ItemTypeCsvPath' contains no item types." }

$realWorkspaces = @()
if ($WorkspaceIdCsvPath) {
    $realWorkspaces = @(
        Import-Csv -LiteralPath $WorkspaceIdCsvPath |
            ForEach-Object { "$($_.workspace_id)".Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    Write-Host "Drawing workspace IDs from $WorkspaceIdCsvPath ($($realWorkspaces.Count) available)." -ForegroundColor DarkGray
}

Write-Host "Load test: $Count policy set(s) on capacity $CapacityId in workspace $WorkspaceId." -ForegroundColor Cyan

# Workspace count per policy set, mostly none or a handful, with the batching boundaries forced in.
$zeroCount  = [int][Math]::Round($Count * $ZeroWorkspacePercent / 100)
$smallCount = [int][Math]::Round($Count * $SmallWorkspacePercent / 100)
$largeCount = $Count - $zeroCount - $smallCount
if ($largeCount -lt 0) { $largeCount = 0; $smallCount = $Count - $zeroCount }

$workspaceCounts = New-Object System.Collections.Generic.List[int]
for ($n = 0; $n -lt $zeroCount; $n++)  { $workspaceCounts.Add(0) }
for ($n = 0; $n -lt $smallCount; $n++) { $workspaceCounts.Add(1 + ($n % 2)) }

if ($largeCount -gt 0) {
    # Always exercise the 49/50 batch split and the ceiling, then fill the rest evenly.
    $forced = @(49, 50, $MaxWorkspaces) | Where-Object { $_ -le $MaxWorkspaces -and $_ -ge 3 } | Select-Object -Unique
    foreach ($value in $forced) {
        if ($workspaceCounts.Count -lt $zeroCount + $smallCount + $largeCount) { $workspaceCounts.Add($value) }
    }

    $remaining = $largeCount - @($forced).Count
    for ($n = 0; $n -lt $remaining; $n++) {
        $workspaceCounts.Add([int][Math]::Round(3 + ($MaxWorkspaces - 3) * $n / [Math]::Max(1, $remaining - 1)))
    }
}

# Interleave so the big payloads are spread through the run instead of clustered at the end.
$random = New-Object System.Random($Seed)
for ($n = $workspaceCounts.Count - 1; $n -gt 0; $n--) {
    $swap = $random.Next($n + 1)
    $temp = $workspaceCounts[$n]
    $workspaceCounts[$n] = $workspaceCounts[$swap]
    $workspaceCounts[$swap] = $temp
}

Write-Host ("Workspaces per set: {0} with none, {1} with 1-2, {2} larger (max {3}); {4} item type(s); no activation." -f `
    $zeroCount, $smallCount, $largeCount, $MaxWorkspaces, $allowedItemTypes.Count) -ForegroundColor Cyan

$results = @()
$runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

for ($i = 1; $i -le $Count; $i++) {
    $name = '{0}{1:d3}' -f $NamePrefix, $i

    $workspaceCount = $workspaceCounts[$i - 1]

    $workspaces = @(
        for ($w = 0; $w -lt $workspaceCount; $w++) {
            if ($realWorkspaces.Count -gt 0) { $realWorkspaces[$w % $realWorkspaces.Count] }
            else { '{0:x8}-0000-4000-8000-{1:x12}' -f $i, $w }
        }
    )
    $workspaces = @($workspaces | Select-Object -Unique)

    $result = [pscustomobject]@{
        index       = $i
        policySetName = $name
        policySetId = $null
        workspaces  = $workspaces.Count
        rules       = 0
        createMs    = 0
        rulesMs     = 0
        totalMs     = 0
        error       = $null
    }

    try {
        # Build the rules first so a limit breach fails before anything is created.
        $rules = @(
            @{
                displayName = 'Deny all item creation'
                description = 'Baseline - grants nothing'
                conditions  = @(New-DynamicCondition -TargetProperty 'workspace.id' -Operator 'AnyOf' -Values $DenyAllSentinelWorkspaceId.ToString())
                effects     = @(@{ type = 'Allow' })
            }
        )

        if ($workspaces.Count -gt 0) {
            $batches = @()
            for ($start = 0; $start -lt $workspaces.Count; $start += $MaxWorkspacesPerRule) {
                $end = [Math]::Min($start + $MaxWorkspacesPerRule, $workspaces.Count) - 1
                $batches += , @($workspaces[$start..$end])
            }

            $batchNumber = 0
            foreach ($batch in $batches) {
                $batchNumber++
                $suffix = if ($batches.Count -gt 1) { " ($batchNumber/$($batches.Count))" } else { '' }

                $rules += @{
                    displayName = "Approved item types in whitelisted workspaces$suffix"
                    description = "Allow $($allowedItemTypes.Count) item type(s) in $($batch.Count) workspace(s)"
                    conditions  = @(
                        (New-DynamicCondition -TargetProperty 'workspace.id' -Operator 'AnyOf' -Values $batch),
                        (New-DynamicCondition -TargetProperty 'item.type' -Operator 'AnyOf' -Values $allowedItemTypes)
                    )
                    effects     = @(@{ type = 'Allow' })
                }
            }
        }

        if ($rules.Count -gt $MaxRulesPerPolicy) {
            throw "$($rules.Count) rules exceed the $MaxRulesPerPolicy-rule limit for policy '$Policy'."
        }
        $result.rules = $rules.Count

        if (-not $PSCmdlet.ShouldProcess("workspace $WorkspaceId", "Create '$name' with $($rules.Count) rule(s) over $($workspaces.Count) workspace(s)")) {
            $results += $result
            continue
        }

        $createStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $created = Invoke-WithRetry -Description "create '$name'" -Action {
            & (Join-Path $PSScriptRoot 'new_policy_set.ps1') @auth `
                -WorkspaceId $WorkspaceId `
                -CapacityId $CapacityId `
                -DisplayName $name `
                -Description "Load test policy set $i of $Count" `
                -Confirm:$false
        }
        $createStopwatch.Stop()

        $result.policySetId = $created.id
        $result.createMs = [int]$createStopwatch.ElapsedMilliseconds

        $body = @{ policy = $Policy; policyRules = @($rules) } | ConvertTo-Json -Depth 12
        $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$($created.id)/policyRules/replaceByPolicy"

        $rulesStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-WithRetry -Description "rules for '$name'" -Action {
            $headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
        } | Out-Null
        $rulesStopwatch.Stop()

        $result.rulesMs = [int]$rulesStopwatch.ElapsedMilliseconds
        $result.totalMs = $result.createMs + $result.rulesMs
    }
    catch {
        $result.error = (Get-FabricErrorText -ErrorRecord $_)
        Write-Host "[$i/$Count] $name FAILED: $($result.error)" -ForegroundColor Red
    }

    $results += $result

    if (-not $result.error -and $result.policySetId) {
        Write-Host ("[{0}/{1}] {2}  ws={3,-4} rules={4,-3} create={5,6} ms  rules={6,6} ms" -f `
            $i, $Count, $name, $result.workspaces, $result.rules, $result.createMs, $result.rulesMs) -ForegroundColor DarkGray
    }

    if ($DelayBetweenSetsMs -gt 0) { Start-Sleep -Milliseconds $DelayBetweenSetsMs }
}

$runStopwatch.Stop()

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$succeeded = @($results | Where-Object { -not $_.error -and $_.policySetId })
$failed    = @($results | Where-Object { $_.error })

Write-Host ''
Write-Host '=== Load test summary ===' -ForegroundColor Cyan
Write-Host ("Elapsed          : {0:n1} s" -f $runStopwatch.Elapsed.TotalSeconds)
Write-Host ("Policy sets      : {0} created, {1} failed, {2} requested" -f $succeeded.Count, $failed.Count, $Count)
Write-Host ("HTTP 429 retries : {0}" -f $script:ThrottleCount)

if ($succeeded.Count -gt 0) {
    Write-Host ("Workspaces       : min {0}, max {1}, total {2}" -f `
        ($succeeded.workspaces | Measure-Object -Minimum).Minimum,
        ($succeeded.workspaces | Measure-Object -Maximum).Maximum,
        ($succeeded.workspaces | Measure-Object -Sum).Sum)
    Write-Host ("Rules per set    : max {0}" -f ($succeeded.rules | Measure-Object -Maximum).Maximum)

    foreach ($metric in 'createMs', 'rulesMs') {
        $values = [double[]]@($succeeded.$metric)
        Write-Host ("{0,-16} : avg {1,6:n0} ms  p50 {2,6:n0}  p95 {3,6:n0}  max {4,6:n0}" -f `
            $metric,
            ($values | Measure-Object -Average).Average,
            (Get-Percentile -Values $values -Percentile 50),
            (Get-Percentile -Values $values -Percentile 95),
            ($values | Measure-Object -Maximum).Maximum)
    }
}

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    $failed | Group-Object error | Sort-Object Count -Descending |
        ForEach-Object { Write-Host (" {0,4}x {1}" -f $_.Count, $_.Name) -ForegroundColor Red }
}

if (-not $WhatIfPreference) {
    $results | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation
    Write-Host ''
    Write-Host "Results written to $OutputCsvPath" -ForegroundColor Green
    Write-Host "Run again with -Cleanup to delete the '$NamePrefix*' policy sets." -ForegroundColor Yellow
}

$results
