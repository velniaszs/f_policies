# Migration Steps

Create the real policy sets without enforcing anything, verify, then activate.

## 0. Prepare the workspace whitelist

`fabric_item_types.csv` already exists. Create the workspace file:

```powershell
Copy-Item .\fabric_workspaces.sample.csv .\fabric_workspaces.csv
# replace the dummy rows with real capacity_id,workspace_id pairs
```

Optionally create the exception file for workspaces that may create **anything**:

```powershell
Copy-Item .\fabric_workspaces_exceptions.sample.csv .\fabric_workspaces_exceptions.csv
# replace the dummy rows with real capacity_id,workspace_id pairs
```

Leave `-ExceptionCsvPath` off the commands below if there are no exceptions.

## 1. Dry run

Builds every payload, calls nothing.

```powershell
.\migrate_policy_sets.ps1 -WorkspaceId <ws> `
    -CsvPath .\fabric_workspaces.csv `
    -ItemTypeCsvPath .\fabric_item_types.csv `
    -ExceptionCsvPath .\fabric_workspaces_exceptions.csv `
    -SkipActivate -WhatIf
```

## 2. One capacity for real, still inactive

```powershell
.\migrate_policy_sets.ps1 -WorkspaceId <ws> `
    -CsvPath .\fabric_workspaces.csv `
    -ItemTypeCsvPath .\fabric_item_types.csv `
    -ExceptionCsvPath .\fabric_workspaces_exceptions.csv `
    -CapacityId <one-cap> -SkipActivate -Confirm:$false
```

## 3. All capacities, still inactive

```powershell
.\migrate_policy_sets.ps1 -WorkspaceId <ws> `
    -CsvPath .\fabric_workspaces.csv `
    -ItemTypeCsvPath .\fabric_item_types.csv `
    -ExceptionCsvPath .\fabric_workspaces_exceptions.csv `
    -SkipActivate -Confirm:$false
```

## 4. Verify

```powershell
.\list_policy_sets.ps1 -WorkspaceId <ws> | Format-Table displayName, scopeId, status
.\get_policy_rule.ps1 -WorkspaceId <ws> -PolicySetId <ps> -ShowFilters
```

All should show `status = Inactive` with the deny-all rule plus the expected whitelist and exception rules.

## 5. Activate

Same command without `-SkipActivate` — it finds the existing sets and activates them:

```powershell
.\migrate_policy_sets.ps1 -WorkspaceId <ws> `
    -CsvPath .\fabric_workspaces.csv `
    -ItemTypeCsvPath .\fabric_item_types.csv `
    -ExceptionCsvPath .\fabric_workspaces_exceptions.csv `
    -AllowReplace -Confirm:$false
```

Or one at a time:

```powershell
.\activate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps> -AllowReplace
```

## Rollback

Deactivate one policy set:

```powershell
.\deactivate_policy_set.ps1 -WorkspaceId <ws> -PolicySetId <ps>
```

Drop everything the migration created (preview first):

```powershell
$ws = '<workspace-id>'

# preview
.\list_policy_sets.ps1 -WorkspaceId $ws |
    Where-Object { $_.displayName -like 'pol_*' } |
    Format-Table displayName, id, status

# delete (deactivates first where needed)
.\list_policy_sets.ps1 -WorkspaceId $ws |
    Where-Object { $_.displayName -like 'pol_*' } |
    ForEach-Object { .\remove_policy_set.ps1 -WorkspaceId $ws -PolicySetId $_.id -Deactivate -Confirm:$false }
```

## Notes

- Only Fabric (`F*` SKU) capacities are processed. Power BI SKUs (`P`/`A`/`EM`/`PP`) are reported as skipped and ignored.
- `-AllowReplace` is needed if another policy set is already active on a capacity, otherwise you get `PolicySetActivationConflict`.
- A capacity **missing from the CSV** gets the deny-all rule only, blocking all governed item creation once activated. Check the warnings from step 3 before activating.
- Workspaces in the **exception CSV** get a rule with no item type condition, so they can create any governed item type. The deny-all baseline is still written for every capacity; the whitelist and exception rules are only added when the CSVs list rows for that capacity.
- The exception list is not cross-checked against the whitelist — the business owns verifying both files before they are sent.
- Re-runs are safe: existing sets are reused (`action = Updated`) and rules are overwritten, not duplicated.
