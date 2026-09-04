<#
.SYNOPSIS
    Fire one of the three demo scenarios at the Triage agent and print the
    outcome. Intended for live-demo control from the presenter's laptop.

.DESCRIPTION
    Sends a JSON payload (simulated Power BI error email) to the triage-agent
    Responses endpoint using the current az-cli user token. The agent then
    walks its workflow — delegate to DQ, log 5 events, take one of three
    action branches, post to Teams — while the presenter narrates.

    Wire this into a keyboard macro or 3-terminal layout for the demo:
        ./demo-fire.ps1 clean        # Scenario 1 — refresh path
        ./demo-fire.ps1 duplicates   # Scenario 2 — flag + Teams
        ./demo-fire.ps1 fail         # Failure path — bad table → escalate

.PARAMETER Scenario
    clean          Scenario 1. key_column=line_id → verdict=clean → PBI refresh
    duplicates     Scenario 2. key_column=order_id → verdict=duplicates_found → dq_flags row
    fail           Failure. source_table=dbo.nonexistent_widgets → verdict=error → escalate
    known_issue    Scenario 2b. Fires the transient payload twice; the 2nd is
                   suppressed by the incident dedup ledger.
    policy_block   Scenario 3. Transient payload + simulate_retry=true; the
                   agent's second refresh attempt is refused by the policy
                   ledger (one remediation per run).
    unknown_action Scenario 4. Transient payload + try_unlisted_action=true;
                   the agent proposes an off-allowlist action (delete_bad_rows)
                   and the controller refuses before dispatch.

.PARAMETER Report
    Optional report name to embed in the payload. Defaults per scenario.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('clean','duplicates','fail','known_issue','policy_block','unknown_action')]
    [string]$Scenario,

    [string]$Report
)

$ErrorActionPreference = 'Stop'

$WORKSPACE_ID = if ($env:PBI_WORKSPACE_ID) { $env:PBI_WORKSPACE_ID } else { throw 'PBI_WORKSPACE_ID is not set. Dot-source scripts\load-env.ps1 first.' }
$DATASET_ID   = if ($env:PBI_DATASET_ID)   { $env:PBI_DATASET_ID }   else { throw 'PBI_DATASET_ID is not set. Dot-source scripts\load-env.ps1 first.' }
$foundryBase  = if ($env:FOUNDRY_ACCOUNT_NAME) { $env:FOUNDRY_ACCOUNT_NAME } else { 'ai-foundry-sme' }
$foundryProj  = if ($env:FOUNDRY_PROJECT_NAME) { $env:FOUNDRY_PROJECT_NAME } else { 'proj-sme' }
$TRIAGE_URL   = "https://$foundryBase.services.ai.azure.com/api/projects/$foundryProj/agents/triage-agent/endpoint/protocols/openai/responses?api-version=v1"

$payload = switch ($Scenario) {
    'clean' {
        @{
            report        = if ($Report) { $Report } else { 'Daily Orders' }
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Refresh failed (simulated transient error)'
            source_table  = 'dbo.source_orders'
            key_column    = 'line_id'    # unique → clean verdict
        }
    }
    'duplicates' {
        @{
            report        = if ($Report) { $Report } else { 'Daily Orders' }
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Refresh failed with data quality warning'
            source_table  = 'dbo.source_orders'
            key_column    = 'order_id'   # O-1003 x3 → duplicates_found
        }
    }
    'fail' {
        @{
            report        = if ($Report) { $Report } else { 'Weekly Revenue' }
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Dataset refresh failed'
            source_table  = 'dbo.nonexistent_widgets'   # SQL blows up → verdict=error
            key_column    = 'widget_id'
        }
    }
    'known_issue' {
        # Scenario 2b: same alert twice. The 2nd is suppressed by /incidents/check_or_open.
        @{
            report        = if ($Report) { $Report } else { 'Daily Orders' }
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Refresh failed (simulated transient error)'
            source_table  = 'dbo.source_orders'
            key_column    = 'line_id'
        }
    }
    'policy_block' {
        # Scenario 3: after the first refresh succeeds, force a second attempt.
        # policy_charge returns allowed=false on call #2 → agent escalates.
        # Distinct report name so the signature doesn't collide with 'clean'.
        @{
            report               = if ($Report) { $Report } else { 'Sales Ops Overview' }
            workspace_id         = $WORKSPACE_ID
            dataset_id           = $DATASET_ID
            error                = 'Refresh failed after transient timeout during model load'
            source_table         = 'dbo.source_orders'
            key_column           = 'line_id'
            force_second_refresh  = $true
        }
    }
    'unknown_action' {
        # Scenario 4: agent proposes delete_bad_rows via policy_propose_action.
        # Allowlist = [refresh_pbi_dataset, write_dq_flag] → refused → escalate.
        # Distinct report name so the signature doesn't collide with 'duplicates'.
        @{
            report               = if ($Report) { $Report } else { 'Regional Revenue' }
            workspace_id         = $WORKSPACE_ID
            dataset_id           = $DATASET_ID
            error                = 'Refresh failed with data quality warning on shipments feed'
            source_table         = 'dbo.source_orders'
            key_column           = 'order_id'
            try_unlisted_action  = $true
        }
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Firing scenario: $Scenario" -ForegroundColor Cyan
Write-Host "  report      : $($payload.report)"
Write-Host "  source_table: $($payload.source_table)"
Write-Host "  key_column  : $($payload.key_column)"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>$null
if (-not $token) {
    throw "Failed to acquire ai.azure.com token. Run 'az login' first."
}

$body = @{ input = ($payload | ConvertTo-Json -Compress) } | ConvertTo-Json -Compress

# Scenario 2b fires the same payload twice — the second run must land AFTER
# the incident row exists so /incidents/check_or_open returns suppress.
$fireCount = if ($Scenario -eq 'known_issue') { 2 } else { 1 }

for ($i = 1; $i -le $fireCount; $i++) {
    if ($fireCount -gt 1) {
        Write-Host ""
        Write-Host "--- Run $i of $fireCount ---" -ForegroundColor Cyan
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-RestMethod -Uri $TRIAGE_URL -Method Post `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -Body $body -TimeoutSec 300
        $sw.Stop()

        Write-Host "Foundry status  : $($resp.status)" -ForegroundColor Green
        Write-Host "Elapsed         : $([int]$sw.Elapsed.TotalSeconds)s"
        Write-Host ""
        Write-Host "Triage summary:" -ForegroundColor Yellow
        ($resp.output | Where-Object type -eq 'message').content[0].text
        Write-Host ""
        Write-Host "Tools invoked:" -ForegroundColor Yellow
        ($resp.output | Where-Object type -eq 'function_call') | ForEach-Object { "  * $($_.name)" }
    } catch {
        $sw.Stop()
        Write-Host "Foundry status  : FAILED after $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Red
        if ($_.ErrorDetails) {
            Write-Host ($_.ErrorDetails.Message)
        } else {
            Write-Host $_.Exception.Message
        }
    }
    if ($i -lt $fireCount) {
        Start-Sleep -Seconds 3
    }
}
