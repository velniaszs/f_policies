#Requires -Version 5.1
<#
.SYNOPSIS
    Rolls out one capacity-scoped policy set per capacity, with the standard item-creation rules.
.DESCRIPTION
    For every Fabric (F SKU) capacity the caller administers:

      1. Ensure a policy set named "<NamePrefix><capacityDisplayName>" exists in -WorkspaceId,
         scoped to that capacity (created when missing, reused when already there).
      2. Replace the ItemCreation rules of that policy set with:
           Rule 1 - deny all. The API has no Deny effect, so this is an Allow rule whose condition
                    can never match (workspace.id AnyOf the -DenyAllSentinelWorkspaceId sentinel).
                    It grants nothing; its job is to keep the policy present so that anything not
                    explicitly allowed by rule 2 is refused. Item types the policy does not govern
                    (Report, SemanticModel, ...) are unaffected and stay creatable.
           Rule 2 - item.type AnyOf [<item type CSV>] AND workspace.id AnyOf [<workspace CSV>]
                    only added when the workspace CSV lists workspaces for the capacity. A condition
                    holds at most -MaxWorkspacesPerRule workspaces, so longer whitelists are split
                    over several identical rules ("... (1/3)", "... (2/3)", ...).
           Rule 3 - workspace.id AnyOf [<exception CSV>], with no item.type condition, so the listed
                    workspaces may create any governed item type. Only added when -ExceptionCsvPath
                    is supplied and lists workspaces for the capacity. Split the same way as rule 2.
      3. Activate the policy set on the capacity.

    Rules are written with POST .../policyRules/replaceByPolicy, which overwrites all rules of the
    given policy. That makes re-runs idempotent: the script can be used both to create and to update.

    Two CSVs drive the whitelist.

    -CsvPath maps capacities to the workspaces allowed to create the listed item types:

        capacity_id,workspace_id

    One row per capacity/workspace pair; capacities absent from the file get rule 1 only, which denies
    creation of every governed item type across the whole capacity.
    See fabric_workspaces.sample.csv for the expected shape.

    -ItemTypeCsvPath lists the item types those workspaces may create. item_name is documentation only;
    item_type must be a Fabric ItemType enum value and duplicates are collapsed:

        item_name,item_type

    See fabric_item_types.csv for the expected shape.

    -ExceptionCsvPath is optional and uses the same columns as -CsvPath:

        capacity_id,workspace_id

    Workspaces listed there are exempt from the item type whitelist and may create anything the
    policy governs. See fabric_workspaces_exceptions.sample.csv for the expected shape.

    HTTP 429 responses are retried up to -MaxRetries times, honouring the Retry-After header and
    falling back to -RetryAfterSeconds when the service does not send one.
.EXAMPLE
    .\migrate_policy_sets.ps1 -WorkspaceId <ws> -CsvPath .\fabric_workspaces.csv `
                              -ItemTypeCsvPath .\fabric_item_types.csv -WhatIf
.EXAMPLE
    # Include the workspaces that are allowed to create anything
    .\migrate_policy_sets.ps1 -WorkspaceId <ws> -CsvPath .\fabric_workspaces.csv `
                              -ItemTypeCsvPath .\fabric_item_types.csv `
                              -ExceptionCsvPath .\fabric_workspaces_exceptions.csv -Confirm:$false
.EXAMPLE
    .\migrate_policy_sets.ps1 -WorkspaceId <ws> -CsvPath .\fabric_workspaces.csv `
                              -ItemTypeCsvPath .\fabric_item_types.csv -AllowReplace -Confirm:$false
.EXAMPLE
    # Only two capacities, leave everything inactive
    .\migrate_policy_sets.ps1 -WorkspaceId <ws> -CsvPath .\fabric_workspaces.csv `
                              -ItemTypeCsvPath .\fabric_item_types.csv `
                              -CapacityId <cap1>,<cap2> -SkipActivate -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Workspace that holds the policy set items.
    [Parameter(Mandatory)][guid]$WorkspaceId,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ItemTypeCsvPath,

    # Optional. Workspaces allowed to create any governed item type, ignoring -ItemTypeCsvPath.
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExceptionCsvPath,

    [guid[]]$CapacityId,

    [string]$NamePrefix = 'pol_',

    # Workspace the deny-all rule points at so that it never matches. Must not be a real workspace.
    [guid]$DenyAllSentinelWorkspaceId = '00000000-0000-0000-0000-000000000000',

    # Values allowed in one workspace.id condition; longer whitelists are split over several rules.
    [ValidateRange(1, 49)]
    [int]$MaxWorkspacesPerRule = 49,

    [ValidateRange(1, 50)]
    [int]$MaxRulesPerPolicy = 50,

    [ValidateSet('ExternalDataSharing', 'ItemCreation')]
    [string]$Policy = 'ItemCreation',

    # Enumerate every capacity in the tenant (Power BI admin API) instead of just the caller's own.
    [switch]$AsAdmin,

    [switch]$IncludeInactiveCapacities,

    # Only Fabric capacities can host a policy set. Set to '' to disable the SKU filter.
    [string]$CapacitySkuPattern = 'F*',

    [switch]$SkipActivate,

    # Take the capacity over from whichever policy set is currently active on it.
    [switch]$AllowReplace,

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

function Get-ErrorBodyCode {
    param($ErrorRecord)

    $text = $null
    try { $text = $ErrorRecord.ErrorDetails.Message } catch { }
    if (-not $text) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $stream.Position = 0
            $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        }
        catch { }
    }
    if (-not $text) { return $null }

    try { return ($text | ConvertFrom-Json).errorCode } catch { return $null }
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
    <#
        Runs $Action, retrying only on HTTP 429 so genuine failures still surface immediately.
    #>
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

function Get-RuleDisplayName {
    # Policy rule display names are capped at 60 characters by the service.
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [string]$Suffix = '',
        [int]$MaxLength = 60
    )

    if (($BaseName.Length + $Suffix.Length) -le $MaxLength) { return "$BaseName$Suffix" }
    $BaseName.Substring(0, $MaxLength - $Suffix.Length).TrimEnd() + $Suffix
}

function ConvertTo-ItemDisplayName {
    <#
        Capacity display names are far more permissive than Fabric item display names, so strip the
        characters items reject and cap the length. Fabric silently rejects trailing dots/spaces too.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [int]$MaxLength = 256
    )

    $clean = $Name -replace '[\\/:*?"<>|]', '_'
    $clean = $clean -replace '[\x00-\x1F\x7F]', ''
    $clean = $clean.Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength) }
    $clean = $clean -replace '[\s.]+$', ''
    $clean
}

function Get-WorkspacesByCapacity {
    <#
        Reads a capacity_id,workspace_id CSV into a capacity -> workspace list map.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { throw "CSV '$Path' is empty." }

    $columns = $rows[0].PSObject.Properties.Name
    foreach ($required in 'capacity_id', 'workspace_id') {
        if ($columns -notcontains $required) {
            throw "CSV '$Path' is missing the '$required' column. Found: $($columns -join ', ')."
        }
    }

    $map = @{}   # PowerShell hashtables are case-insensitive, so GUID casing does not matter.
    $rowNumber = 1
    foreach ($row in $rows) {
        $rowNumber++
        $capacityKey = "$($row.capacity_id)".Trim()
        $workspaceKey = "$($row.workspace_id)".Trim()
        if (-not $capacityKey -and -not $workspaceKey) { continue }

        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($capacityKey, [ref]$parsed) -or -not [guid]::TryParse($workspaceKey, [ref]$parsed)) {
            Write-Warning "Row $rowNumber of $Path skipped: '$capacityKey' / '$workspaceKey' is not a GUID pair."
            continue
        }

        if (-not $map.ContainsKey($capacityKey)) {
            $map[$capacityKey] = New-Object System.Collections.Generic.List[string]
        }
        if (-not $map[$capacityKey].Contains($workspaceKey)) {
            $map[$capacityKey].Add($workspaceKey)
        }
    }

    $map
}

function Split-IntoBatches {
    <#
        Splits a workspace list into chunks of at most $Size, one chunk per rule.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Values,
        [Parameter(Mandatory)][int]$Size
    )

    $batches = @()
    for ($start = 0; $start -lt $Values.Count; $start += $Size) {
        $end = [Math]::Min($start + $Size, $Values.Count) - 1
        $batches += , @($Values[$start..$end])
    }
    , $batches
}

# ---------------------------------------------------------------------------
# CSV - capacity_id -> workspace_id[]
# ---------------------------------------------------------------------------

$workspacesByCapacity = Get-WorkspacesByCapacity -Path $CsvPath
Write-Verbose "CSV mapped $($workspacesByCapacity.Count) capacity(ies) to workspaces."

$exceptionsByCapacity = @{}
if ($ExceptionCsvPath) {
    $exceptionsByCapacity = Get-WorkspacesByCapacity -Path $ExceptionCsvPath
    Write-Verbose "Exception CSV mapped $($exceptionsByCapacity.Count) capacity(ies) to unrestricted workspaces."
}

# ---------------------------------------------------------------------------
# CSV - allowed item types
# ---------------------------------------------------------------------------

$itemTypeRows = @(Import-Csv -LiteralPath $ItemTypeCsvPath)
if ($itemTypeRows.Count -eq 0) { throw "CSV '$ItemTypeCsvPath' is empty." }

if ($itemTypeRows[0].PSObject.Properties.Name -notcontains 'item_type') {
    throw "CSV '$ItemTypeCsvPath' is missing the 'item_type' column. Found: $($itemTypeRows[0].PSObject.Properties.Name -join ', ')."
}

$allowedItemTypes = @(
    $itemTypeRows |
        ForEach-Object { "$($_.item_type)".Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
)

if ($allowedItemTypes.Count -eq 0) { throw "CSV '$ItemTypeCsvPath' contains no item types." }
Write-Verbose "Allowing $($allowedItemTypes.Count) item type(s): $($allowedItemTypes -join ', ')"

# ---------------------------------------------------------------------------
# Capacities
# ---------------------------------------------------------------------------

$listArgs = @{}
if ($AsAdmin) { $listArgs.AsAdmin = $true }

$capacities = @(Invoke-WithRetry -Description 'list capacities' -Action {
    & (Join-Path $PSScriptRoot 'list_capacities.ps1') @auth @listArgs
})

# Only the admin route reports the caller's access right; the core route already returns
# just the capacities the principal administers or contributes to.
$capacities = @($capacities | Where-Object {
    -not ($_.PSObject.Properties.Name -contains 'capacityUserAccessRight') -or $_.capacityUserAccessRight -eq 'Admin'
})

if (-not $IncludeInactiveCapacities) {
    $capacities = @($capacities | Where-Object { $_.state -eq 'Active' })
}

# Policy sets can only be scoped to Fabric capacities, so drop Power BI SKUs (P/A/EM/PP).
if ($CapacitySkuPattern) {
    $skipped = @($capacities | Where-Object { $_.sku -notlike $CapacitySkuPattern })
    if ($skipped.Count -gt 0) {
        Write-Host ("Skipping {0} non-Fabric capacity(ies): {1}" -f `
            $skipped.Count, (($skipped | ForEach-Object { "$($_.displayName) [$($_.sku)]" }) -join ', ')) -ForegroundColor Yellow
    }
    $capacities = @($capacities | Where-Object { $_.sku -like $CapacitySkuPattern })
}

if ($CapacityId) {
    $wanted = @($CapacityId | ForEach-Object { $_.ToString() })
    $capacities = @($capacities | Where-Object { $wanted -contains $_.id })
}

if ($capacities.Count -eq 0) { throw 'No matching capacities found for this principal.' }
Write-Host "Processing $($capacities.Count) capacity(ies) into workspace $WorkspaceId." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Policy set names
# ---------------------------------------------------------------------------

# Two capacities can share a display name, which would collide into one policy set name and make the
# name-based lookup below match the wrong capacity, so resolve every name up front.
$policySetNames = @{}
$nameUsage = @{}

foreach ($capacity in $capacities) {
    $raw = "$NamePrefix$($capacity.displayName)"
    $name = ConvertTo-ItemDisplayName -Name $raw

    if (-not $name) { throw "Capacity $($capacity.id) produced an empty policy set name from display name '$($capacity.displayName)'." }
    if ($name -ne $raw) { Write-Warning "Capacity $($capacity.id): name '$raw' sanitised to '$name'." }

    if ($nameUsage.ContainsKey($name)) {
        $suffix = " ($($capacity.id.ToString().Substring(0, 8)))"
        $name = (ConvertTo-ItemDisplayName -Name $name -MaxLength (256 - $suffix.Length)) + $suffix
        Write-Warning "Duplicate capacity display name '$($capacity.displayName)'; using '$name' for capacity $($capacity.id)."
    }

    $nameUsage[$name] = $true
    $policySetNames[$capacity.id] = $name
}

# ---------------------------------------------------------------------------
# Existing policy sets in the target workspace, indexed by display name
# ---------------------------------------------------------------------------

$existing = @{}
foreach ($set in @(Invoke-WithRetry -Description 'list policy sets' -Action {
        & (Join-Path $PSScriptRoot 'list_policy_sets.ps1') @auth -WorkspaceId $WorkspaceId
    })) {
    $existing[$set.displayName] = $set
}

# ---------------------------------------------------------------------------
# Per capacity
# ---------------------------------------------------------------------------

$results = @()
$index = 0
$runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($capacity in $capacities) {
    $index++
    $name = $policySetNames[$capacity.id]
    $result = [pscustomobject]@{
        capacityId   = $capacity.id
        capacityName = $capacity.displayName
        policySetName = $name
        policySetId  = $null
        action       = 'Skipped'
        workspaces   = 0
        exceptions   = 0
        rules        = 0
        activated    = $false
        createMs     = 0
        rulesMs      = 0
        activateMs   = 0
        totalMs      = 0
        error        = $null
    }

    Write-Host ''
    Write-Host ("--- [{0}/{1}] {2} ({3})" -f $index, $capacities.Count, $capacity.displayName, $capacity.id) -ForegroundColor Cyan

    try {
        # 1) Create or reuse the policy set.
        $policySet = $existing[$name]

        if ($policySet) {
            if ($policySet.scopeType -ne 'Capacity') {
                throw "Existing policy set '$name' ($($policySet.id)) is scoped to $($policySet.scopeType), not Capacity; scope cannot be changed. Rename or delete it first."
            }

            # The list response often omits scope.id, so confirm with a direct GET before calling it a mismatch.
            $scopeId = $policySet.scopeId
            if (-not $scopeId) {
                $fetched = Invoke-WithRetry -Description "get policy set $($policySet.id)" -Action {
                    & (Join-Path $PSScriptRoot 'get_policy_set.ps1') @auth `
                        -WorkspaceId $WorkspaceId -PolicySetId $policySet.id
                }
                if ($fetched.properties.scope.PSObject.Properties.Name -contains 'id') {
                    $scopeId = $fetched.properties.scope.id
                }
            }

            if ($scopeId -and $scopeId -ne $capacity.id) {
                throw "Existing policy set '$name' ($($policySet.id)) is scoped to capacity $scopeId, not $($capacity.id); scope cannot be changed. Rename or delete it first."
            }
            if (-not $scopeId) {
                Write-Verbose "Policy set $($policySet.id) reports no capacity id; assuming it targets $($capacity.id)."
            }

            $result.policySetId = $policySet.id
            $result.action = 'Updated'
            Write-Host "Reusing policy set $($policySet.id)." -ForegroundColor DarkGray
        }
        elseif ($PSCmdlet.ShouldProcess("workspace $WorkspaceId", "Create policy set '$name' on capacity $($capacity.id)")) {
            $createStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $created = Invoke-WithRetry -Description "create policy set '$name'" -Action {
                & (Join-Path $PSScriptRoot 'new_policy_set.ps1') @auth `
                    -WorkspaceId $WorkspaceId `
                    -CapacityId $capacity.id `
                    -DisplayName $name `
                    -Description "Item creation policy for capacity $($capacity.displayName)" `
                    -Confirm:$false
            }
            $createStopwatch.Stop()

            $result.policySetId = $created.id
            $result.action = 'Created'
            $result.createMs = [int]$createStopwatch.ElapsedMilliseconds
            Write-Host ("Created policy set {0} in {1} ms." -f $created.id, $result.createMs) -ForegroundColor Green
        }
        else {
            $results += $result
            continue
        }

        # 2) Replace the rules for this policy.
        # There is no Deny effect, so "deny all" is an Allow rule that can never match: it keeps the
        # policy in force without granting anything.
        $rules = @(
            @{
                displayName = Get-RuleDisplayName -BaseName 'Deny all item creation (PBI items not tracked)'
                description = 'Baseline - grants nothing, so only the rules below can allow creation'
                conditions  = @(New-DynamicCondition -TargetProperty 'workspace.id' -Operator 'AnyOf' -Values $DenyAllSentinelWorkspaceId.ToString())
                effects     = @(@{ type = 'Allow' })
            }
        )

        $approved = $workspacesByCapacity[$capacity.id]
        if ($approved -and $approved.Count -gt 0) {
            $result.workspaces = $approved.Count
            # A single workspace.id condition holds at most -MaxWorkspacesPerRule values, so long
            # whitelists are spread over several otherwise identical rules.
            $batches = Split-IntoBatches -Values $approved -Size $MaxWorkspacesPerRule

            $batchNumber = 0
            foreach ($batch in $batches) {
                $batchNumber++
                $suffix = if ($batches.Count -gt 1) { " ($batchNumber/$($batches.Count))" } else { '' }

                $rules += @{
                    displayName = Get-RuleDisplayName -BaseName 'Approved Fabric item types for whitelisted workspaces' -Suffix $suffix
                    description = "Allow $($allowedItemTypes.Count) Fabric item type(s) in $($batch.Count) whitelisted Fabric workspace(s). Power BI items are not governed by this policy."
                    conditions  = @(
                        (New-DynamicCondition -TargetProperty 'workspace.id' -Operator 'AnyOf' -Values $batch),
                        (New-DynamicCondition -TargetProperty 'item.type' -Operator 'AnyOf' -Values $allowedItemTypes)
                    )
                    effects     = @(@{ type = 'Allow' })
                }
            }

            if ($batches.Count -gt 1) {
                Write-Host "$($approved.Count) whitelisted workspace(s) split across $($batches.Count) rules." -ForegroundColor DarkGray
            }
        }
        else {
            Write-Warning "No workspaces in the CSV for capacity $($capacity.id); deny-all only, so no governed item type can be created on it."
        }

        # Exception workspaces get no item.type condition, so every governed item type is allowed.
        $unrestricted = $exceptionsByCapacity[$capacity.id]
        if ($unrestricted -and $unrestricted.Count -gt 0) {
            $result.exceptions = $unrestricted.Count
            $exceptionBatches = Split-IntoBatches -Values $unrestricted -Size $MaxWorkspacesPerRule

            $batchNumber = 0
            foreach ($batch in $exceptionBatches) {
                $batchNumber++
                $suffix = if ($exceptionBatches.Count -gt 1) { " ($batchNumber/$($exceptionBatches.Count))" } else { '' }

                $rules += @{
                    displayName = Get-RuleDisplayName -BaseName 'Unrestricted item creation for exception workspaces' -Suffix $suffix
                    description = "Allow any governed Fabric item type in $($batch.Count) exception workspace(s); the item type whitelist does not apply to them."
                    conditions  = @(New-DynamicCondition -TargetProperty 'workspace.id' -Operator 'AnyOf' -Values $batch)
                    effects     = @(@{ type = 'Allow' })
                }
            }

            Write-Host ("{0} exception workspace(s) allowed to create anything, across {1} rule(s)." -f `
                $unrestricted.Count, $exceptionBatches.Count) -ForegroundColor DarkGray
        }

        if ($rules.Count -gt $MaxRulesPerPolicy) {
            throw "$($rules.Count) rules exceed the $MaxRulesPerPolicy-rule limit for policy '$Policy'. Reduce the whitelist or exception list for capacity $($capacity.id), or raise -MaxWorkspacesPerRule."
        }

        $result.rules = $rules.Count
        $body = @{ policy = $Policy; policyRules = @($rules) } | ConvertTo-Json -Depth 12

        if ($PSCmdlet.ShouldProcess("policy set $($result.policySetId)", "Replace $Policy rules with $($rules.Count) rule(s)")) {
            $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/policySets/$($result.policySetId)/policyRules/replaceByPolicy"
            Write-Verbose "POST $uri"
            Write-Verbose $body

            $rulesStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-WithRetry -Description "replace $Policy rules" -Action {
                $headers = @{ Authorization = "Bearer $(Get-FabricToken)" }
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                    -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
            } | Out-Null
            $rulesStopwatch.Stop()

            $result.rulesMs = [int]$rulesStopwatch.ElapsedMilliseconds
            Write-Host ("Applied {0} {1} rule(s) in {2} ms." -f $rules.Count, $Policy, $result.rulesMs) -ForegroundColor Green
        }

        # 3) Activate on the capacity.
        if (-not $SkipActivate) {
            $activateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-WithRetry -Description "activate policy set $($result.policySetId)" -Action {
                    & (Join-Path $PSScriptRoot 'activate_policy_set.ps1') @auth `
                        -WorkspaceId $WorkspaceId `
                        -PolicySetId $result.policySetId `
                        -AllowReplace:$AllowReplace `
                        -Confirm:$false
                }
                $result.activated = -not $WhatIfPreference
            }
            catch {
                if ((Get-ErrorBodyCode -ErrorRecord $_) -eq 'PolicySetIsAlreadyActive') {
                    Write-Host 'Already active.' -ForegroundColor DarkGray
                    $result.activated = $true
                }
                else { throw }
            }
            finally {
                $activateStopwatch.Stop()
                $result.activateMs = [int]$activateStopwatch.ElapsedMilliseconds
            }
        }

        $result.totalMs = $result.createMs + $result.rulesMs + $result.activateMs
    }
    catch {
        # Only HTTP failures get the API error formatting; local validation errors keep their own text.
        $hasResponse = $false
        try { $hasResponse = $null -ne $_.Exception.Response } catch { }

        $result.error = if ($hasResponse) { Get-FabricErrorText -ErrorRecord $_ } else { $_.Exception.Message }
        Write-Host $result.error -ForegroundColor Red
    }

    if (-not $result.error -and $result.policySetId) {
        Write-Host ("[{0}/{1}] {2,-28} {3,-9} ws={4,-4} exc={5,-4} rules={6,-3} create={7,6} ms  rules={8,6} ms  activate={9,6} ms" -f `
            $index, $capacities.Count, $result.capacityName, $result.action,
            $result.workspaces, $result.exceptions, $result.rules,
            $result.createMs, $result.rulesMs, $result.activateMs) -ForegroundColor DarkGray
    }

    $results += $result
}

$runStopwatch.Stop()

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
$results | Format-Table capacityName, policySetName, action, workspaces, exceptions, rules, activated, totalMs -AutoSize | Out-Host

$succeeded = @($results | Where-Object { -not $_.error -and $_.policySetId })
$failed    = @($results | Where-Object { $_.error })

Write-Host ("Elapsed          : {0:n1} s" -f $runStopwatch.Elapsed.TotalSeconds)
Write-Host ("Capacities       : {0} created, {1} updated, {2} failed, {3} total" -f `
    @($succeeded | Where-Object { $_.action -eq 'Created' }).Count,
    @($succeeded | Where-Object { $_.action -eq 'Updated' }).Count,
    $failed.Count, $capacities.Count)
Write-Host ("HTTP 429 retries : {0}" -f $script:ThrottleCount)

if ($succeeded.Count -gt 0) {
    foreach ($metric in 'createMs', 'rulesMs', 'activateMs', 'totalMs') {
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
    Write-Host "$($failed.Count) capacity(ies) failed:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host " - $($_.capacityName): $($_.error)" -ForegroundColor Red }
}

$results
