# scripts/use-pbi-dataset.ps1
#
# After you publish a new Power BI semantic model to the demo workspace,
# run this to swap the dataset id everywhere the demo references it.
#
# Two ways to invoke:
#
#   .\scripts\use-pbi-dataset.ps1 -Name demo-orders-import
#     Look up the dataset id by display name in the workspace.
#
#   .\scripts\use-pbi-dataset.ps1 -DatasetId <guid>
#     Use the given id directly (skip the lookup).
#
#   .\scripts\use-pbi-dataset.ps1 -List
#     List every dataset in the workspace with its id + whether it's
#     refreshable + whether it has a refresh history. Useful for finding
#     the right one when you're not sure which just got published.
#
# Files updated:
#   demo-fire.ps1                          — $DATASET_ID for every scenario
#   cockpit/static/cockpit.js              — dataset_id in EMAIL_TEMPLATES
#   scenarios/*.yaml                       — payload.dataset_id in every scenario
#   docs/run-sheet.md, docs/faq.md         — any hardcoded references
#
# Safe to re-run. Idempotent. Prints a diff summary of what changed.

[CmdletBinding()]
param(
    [string]$Name,
    [string]$DatasetId,
    [switch]$List,
    [string]$WorkspaceId = $(if ($env:PBI_WORKSPACE_ID) { $env:PBI_WORKSPACE_ID } else { throw 'PBI_WORKSPACE_ID is not set. Dot-source scripts\load-env.ps1 first, or pass -WorkspaceId.' }),
    [string]$RepoRoot    = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Get-PbiToken {
    $t = az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv 2>$null
    if (-not $t) { throw 'Failed to acquire PBI token. Run az login.' }
    return $t
}

$token = Get-PbiToken

# ---- helper: fetch every dataset in the workspace ----------------------

function Get-Datasets {
    $r = curl.exe --silent -H "Authorization: Bearer $token" `
        "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets"
    return ($r | ConvertFrom-Json).value
}

function Get-RefreshHistoryCount([string]$id) {
    $r = curl.exe --silent -H "Authorization: Bearer $token" `
        "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$id/refreshes?`$top=1"
    try { return @(($r | ConvertFrom-Json).value).Count } catch { return 0 }
}

# ---- -List mode -------------------------------------------------------

if ($List) {
    Write-Host "Datasets in workspace ${WorkspaceId}:" -ForegroundColor Cyan
    Write-Host ''
    $ds = Get-Datasets
    $rows = foreach ($d in $ds) {
        $count = Get-RefreshHistoryCount $d.id
        [PSCustomObject]@{
            Name         = $d.name
            Id           = $d.id
            Refreshable  = $d.isRefreshable
            StorageMode  = $d.targetStorageMode
            RefreshCount = $count
            Recommended  = ($d.isRefreshable -and $d.targetStorageMode -eq 'Abf' -and $count -gt 0)
        }
    }
    $rows | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'Pick one where Recommended=True and re-run with:' -ForegroundColor DarkGray
    Write-Host '  .\scripts\use-pbi-dataset.ps1 -DatasetId <the-id>' -ForegroundColor DarkGray
    exit 0
}

# ---- resolve DatasetId --------------------------------------------------

if (-not $DatasetId) {
    if (-not $Name) {
        throw 'Pass -Name <displayName>, -DatasetId <guid>, or -List.'
    }
    Write-Host "Looking up dataset by name: $Name" -ForegroundColor Cyan
    $match = Get-Datasets | Where-Object { $_.name -eq $Name }
    if (-not $match) {
        throw "No dataset named '$Name' in workspace $WorkspaceId. Try -List to see what's there."
    }
    if (@($match).Count -gt 1) {
        throw "Multiple datasets named '$Name'. Pass -DatasetId explicitly."
    }
    $DatasetId = $match.id
    Write-Host "  -> $DatasetId"
}

# Validate the id resolves + is refreshable
$dsInfo = curl.exe --silent -H "Authorization: Bearer $token" `
    "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId" | ConvertFrom-Json
if (-not $dsInfo.id) {
    throw "Dataset $DatasetId not found in workspace $WorkspaceId."
}
Write-Host ("Dataset:      {0} ({1})" -f $dsInfo.name, $dsInfo.id)
Write-Host ("Refreshable:  {0}" -f $dsInfo.isRefreshable)
Write-Host ("StorageMode:  {0}" -f $dsInfo.targetStorageMode)
if (-not $dsInfo.isRefreshable) {
    Write-Warning "This dataset reports isRefreshable=false — the refresh call will still succeed but Kendra will see empty history."
}

# ---- swap in every relevant file ---------------------------------------

$targets = @(
    Join-Path $RepoRoot 'demo-fire.ps1'
    Join-Path $RepoRoot 'cockpit\static\cockpit.js'
) + (Get-ChildItem (Join-Path $RepoRoot 'scenarios') -Filter '*.yaml' -ErrorAction SilentlyContinue |
       ForEach-Object { $_.FullName })

# Load previous dataset id from demo-fire.ps1 so we know what to swap OUT.
$oldId = $null
$demoFire = Get-Content (Join-Path $RepoRoot 'demo-fire.ps1') -Raw
if ($demoFire -match "DATASET_ID\s*=\s*'([0-9a-f-]{36})'") {
    $oldId = $matches[1]
}
if (-not $oldId) {
    Write-Warning "Couldn't detect the current DATASET_ID in demo-fire.ps1. Aborting so I don't clobber the wrong string."
    exit 1
}
if ($oldId -eq $DatasetId) {
    Write-Host ""
    Write-Host "All files already reference $DatasetId. No changes needed." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Swapping $oldId -> $DatasetId" -ForegroundColor Cyan
Write-Host ""

$totalHits = 0
foreach ($f in $targets) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $text = Get-Content -LiteralPath $f -Raw
    $hits = ([regex]::Matches($text, [regex]::Escape($oldId))).Count
    if ($hits -eq 0) { continue }
    $new = $text.Replace($oldId, $DatasetId)
    Set-Content -LiteralPath $f -Value $new -NoNewline -Encoding utf8
    Write-Host ("  {0} — {1} hit{2}" -f (Resolve-Path -Relative $f), $hits, $(if ($hits -eq 1) {''} else {'s'}))
    $totalHits += $hits
}

Write-Host ""
Write-Host "Done. $totalHits total references updated." -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. If uvicorn is running, hard-reload the cockpit browser tab (Ctrl+F5)"
Write-Host "  2. Rehearse S1 once: .\demo-fire.ps1 clean"
Write-Host "  3. Confirm Monitor tab in PBI shows a fresh refresh row"
