<#
.SYNOPSIS
    Send a fake [BI-DEMO] email to the monitored inbox to kick off Triage.

.DESCRIPTION
    Uses your currently-signed-in az CLI identity to send an email via
    Microsoft Graph to the monitored mailbox (`$env:MAILBOX_UPN`). The
    Function App poller ticks every 30 s, extracts the JSON body, and
    invokes Triage.

.PARAMETER Scenario
    clean          S1  Transient refresh error → PBI refresh succeeds
    duplicates     S2  DQ finds duplicates → flag written
    known_issue    S2b Duplicate alert suppressed (send twice; 2nd is suppressed)
    policy_block   S3  Second refresh in policy window is denied
    unknown_action S4  Agent proposes non-allowlisted action → refused
    approval_granted  S5  request_bigger_fix → HITL approval → click ✓ in cockpit
    approval_denied   S6  request_bigger_fix → HITL approval → click ✗ in cockpit
    bad_table      F   Payload references non-existent table → verdict=error

.EXAMPLE
    .\send-demo-email.ps1 clean
    .\send-demo-email.ps1 duplicates
    .\send-demo-email.ps1 approval_granted
    .\send-demo-email.ps1 known_issue    # sends the same mail twice with a delay
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('clean','duplicates','known_issue','policy_block','unknown_action','approval_granted','approval_denied','bad_table')]
    [string]$Scenario = 'duplicates'
)

$ErrorActionPreference = 'Stop'

$Recipient    = if ($env:MAILBOX_UPN)      { $env:MAILBOX_UPN }      else { throw 'MAILBOX_UPN is not set. Dot-source scripts\load-env.ps1 first.' }
$WORKSPACE_ID = if ($env:PBI_WORKSPACE_ID) { $env:PBI_WORKSPACE_ID } else { throw 'PBI_WORKSPACE_ID is not set.' }
$DATASET_ID   = if ($env:PBI_DATASET_ID)   { $env:PBI_DATASET_ID }   else { throw 'PBI_DATASET_ID is not set.' }

# Payloads mirror demo-fire.ps1 + cockpit S5/S6 templates so the mail path and
# direct-to-triage path produce identical behavior.
$scenarios = @{
    'clean' = @{
        subject = '[BI-DEMO] Daily Orders refresh failed (transient)'
        payload = @{
            report        = 'Daily Orders'
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Refresh failed (simulated transient error)'
            source_table  = 'dbo.source_orders'
            key_column    = 'line_id'
        }
    }
    'duplicates' = @{
        subject = '[BI-DEMO] Daily Orders refresh failed (DQ warning)'
        payload = @{
            report        = 'Daily Orders'
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Refresh failed with data quality warning'
            source_table  = 'dbo.source_orders'
            key_column    = 'order_id'
        }
    }
    'known_issue' = @{
        subject = '[BI-DEMO] Daily Orders refresh failed (transient)'
        payload = @{
            report        = 'Daily Orders'
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'Refresh failed (simulated transient error)'
            source_table  = 'dbo.source_orders'
            key_column    = 'line_id'
        }
    }
    'policy_block' = @{
        subject = '[BI-DEMO] Sales Ops Overview refresh failed'
        payload = @{
            report          = 'Sales Ops Overview'
            workspace_id    = $WORKSPACE_ID
            dataset_id      = $DATASET_ID
            error           = 'Refresh failed after transient timeout during model load'
            source_table    = 'dbo.source_orders'
            key_column      = 'line_id'
            force_second_refresh  = $true
        }
    }
    'unknown_action' = @{
        subject = '[BI-DEMO] Regional Revenue refresh failed'
        payload = @{
            report              = 'Regional Revenue'
            workspace_id        = $WORKSPACE_ID
            dataset_id          = $DATASET_ID
            error               = 'Refresh failed with data quality warning on shipments feed'
            source_table        = 'dbo.source_orders'
            key_column          = 'order_id'
            try_unlisted_action = $true
        }
    }
    'approval_granted' = @{
        subject = '[BI-DEMO] Orders Fact repeat duplicates'
        payload = @{
            report             = 'Orders Fact'
            workspace_id       = $WORKSPACE_ID
            dataset_id         = $DATASET_ID
            error              = 'Recurring duplicates in dbo.source_orders'
            source_table       = 'dbo.source_orders'
            key_column         = 'order_id'
            request_bigger_fix = $true
        }
    }
    'approval_denied' = @{
        subject = '[BI-DEMO] Orders Fact repeat duplicates'
        payload = @{
            report             = 'Orders Fact'
            workspace_id       = $WORKSPACE_ID
            dataset_id         = $DATASET_ID
            error              = 'Recurring duplicates in dbo.source_orders'
            source_table       = 'dbo.source_orders'
            key_column         = 'order_id'
            request_bigger_fix = $true
        }
    }
    'bad_table' = @{
        subject = '[BI-DEMO] Failure path — bad table'
        payload = @{
            report        = 'Daily Orders Report'
            workspace_id  = $WORKSPACE_ID
            dataset_id    = $DATASET_ID
            error         = 'PBI refresh: table not found'
            source_table  = 'dbo.does_not_exist'
            key_column    = 'order_id'
        }
    }
}

$sel     = $scenarios[$Scenario]
$subject = $sel.subject
$body    = $sel.payload | ConvertTo-Json -Compress

Write-Host "→ Getting Graph token from your az session..."
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
if (-not $token) { throw "no Graph token; run 'az login' first" }

# S2b (known_issue) requires TWO sends — the second one is the "already seen"
# signature that /incidents/check_or_open suppresses.
$fireCount = if ($Scenario -eq 'known_issue') { 2 } else { 1 }

for ($i = 1; $i -le $fireCount; $i++) {
    $html = "<p>Automated demo trigger. JSON payload follows:</p><pre>$body</pre>"

    $payload = @{
        message = @{
            subject      = $subject
            body         = @{ contentType = 'HTML'; content = $html }
            toRecipients = @( @{ emailAddress = @{ address = $Recipient } } )
        }
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 10

    Write-Host ""
    Write-Host "→ Sending mail $i of $fireCount to $Recipient..."
    Write-Host "  Scenario: $Scenario"
    Write-Host "  Subject:  $subject"

    $r = Invoke-WebRequest -Uri 'https://graph.microsoft.com/v1.0/me/sendMail' `
        -Method POST `
        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
        -Body $payload `
        -SkipHttpErrorCheck

    if ($r.StatusCode -eq 202) {
        Write-Host "✔ Sent (202 Accepted)." -ForegroundColor Green
    } else {
        Write-Host "✖ Send failed: HTTP $($r.StatusCode)" -ForegroundColor Red
        Write-Host $r.Content
        exit 1
    }

    # For known_issue we need the first run to fully complete before the
    # second mail arrives, or /incidents/check_or_open won't have a row
    # to dedup against. Poller ticks every 30s so 75s is a safe cushion.
    if ($fireCount -gt 1 -and $i -lt $fireCount) {
        Write-Host "  Waiting 75s for run #$i to complete before sending run #$($i + 1)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 75
    }
}

Write-Host ""
Write-Host "Next: within ~30s the func-sme poll_inbox timer will pick it up and invoke Triage."
if ($Scenario -in @('approval_granted','approval_denied')) {
    Write-Host "→ HITL scenario: watch the Approvals tile in the cockpit." -ForegroundColor Cyan
    Write-Host "   For $Scenario, click $(if ($Scenario -eq 'approval_granted') { '✓ Approve' } else { '✗ Deny' }) when the row appears."
}
