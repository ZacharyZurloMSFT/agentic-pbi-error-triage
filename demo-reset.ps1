<#
.SYNOPSIS
    Reset the demo state directly — bypasses the cockpit.

.DESCRIPTION
    Hits /api/demo/cleanup on func-triage with a timing check. This is the
    presenter's escape hatch when the cockpit's Reset button gets wedged
    on uvicorn worker state, browser fetch queues, or MI token loops.

    What it truncates (mirror of demo/cleanup):
      * dbo.dq_flags        — DQ flag rows
      * dbo.demo_events     — event feed (except poll_tick heartbeat)
      * dbo.incidents       — signature-dedup ledger
      * dbo.policy_ledger   — remediation budget + allowlist decisions
      * dbo.inbox_audit     — rejected-mail audit
      * dbo.approvals       — human-in-the-loop gates

    What it does NOT touch:
      * dbo.source_orders   — seeded mock data (rerun demo-tools.ps1 seed if needed)
      * dbo.prompt_versions — deploy-time history, not per-run state

    Also (optional): -MarkRead scans the demo mailbox for unread [BI-DEMO]
    mails and marks them read. Necessary when the poller has been re-
    processing the same mail every 30 s (usually a symptom of missing
    Mail.ReadWrite on the Function App MI — see grant-func-graph-roles.ps1).

.PARAMETER MarkRead
    Also mark every unread [BI-DEMO] mail in the demo inbox as read,
    breaking any "poller in a loop" incident-counter runaway.

.PARAMETER Verbose
    Show timing breakdown per hop.

.EXAMPLE
    .\demo-reset.ps1
    .\demo-reset.ps1 -MarkRead        # also nukes stuck emails
#>
[CmdletBinding()]
param(
    [switch]$MarkRead,
    [string]$FunctionHost     = $(if ($env:FUNCTION_APP_NAME) { "$($env:FUNCTION_APP_NAME).azurewebsites.net" } else { 'func-triage.azurewebsites.net' }),
    [string]$FunctionAudience = $(if ($env:FUNCTION_APP_AUDIENCE) { $env:FUNCTION_APP_AUDIENCE } else { 'api://func-triage' }),
    [string]$MailboxUpn       = $(if ($env:MAILBOX_UPN) { $env:MAILBOX_UPN } else { '' })
)

$ErrorActionPreference = 'Stop'

function Get-Token([string]$resource) {
    $t = az account get-access-token --resource $resource --query accessToken -o tsv 2>$null
    if (-not $t) {
        $tenantHint = if ($env:AZURE_TENANT_ID) { " --tenant $($env:AZURE_TENANT_ID)" } else { '' }
        throw "Failed to acquire token for $resource. Run 'az login$tenantHint' first."
    }
    return $t
}

# ---------------- 1. reset SQL state ------------------------------------

$funcToken = Get-Token $FunctionAudience
$url = "https://$FunctionHost/api/demo/cleanup"

Write-Host "==> POST $url" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $resp = curl.exe --silent --show-error --fail-with-body --max-time 60 `
        -X POST $url `
        -H "Authorization: Bearer $funcToken" `
        -H 'Content-Type: application/json' `
        --data '{}'
} catch {
    $sw.Stop()
    Write-Error "cleanup FAILED after $([math]::Round($sw.Elapsed.TotalSeconds,2))s: $($_.Exception.Message)"
    exit 1
}
$sw.Stop()

try {
    $obj = $resp | ConvertFrom-Json
    Write-Host ("    ok in {0:N2}s — {1}" -f $sw.Elapsed.TotalSeconds, $obj.action) -ForegroundColor Green
} catch {
    Write-Host "    ok in $([math]::Round($sw.Elapsed.TotalSeconds,2))s — $resp" -ForegroundColor Green
}

# ---------------- 2. optional: mark stuck mail as read ------------------

if ($MarkRead) {
    Write-Host ""
    Write-Host "==> GET Graph unread [BI-DEMO] mail" -ForegroundColor Cyan
    $graphToken = Get-Token 'https://graph.microsoft.com'
    $listUrl = "https://graph.microsoft.com/v1.0/users/$MailboxUpn/mailFolders/Inbox/messages?" +
               '$filter=isRead eq false&$select=id,subject&$top=25'
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    $listResp = curl.exe --silent --show-error --max-time 30 `
        -H "Authorization: Bearer $graphToken" $listUrl
    $sw2.Stop()

    try { $listObj = $listResp | ConvertFrom-Json }
    catch {
        Write-Warning "could not parse Graph response: $listResp"
        return
    }

    $matches = @($listObj.value | Where-Object { $_.subject -match '^\[BI-DEMO\]' })
    Write-Host ("    found {0} unread [BI-DEMO] mails in {1:N2}s" -f $matches.Count, $sw2.Elapsed.TotalSeconds)

    foreach ($m in $matches) {
        $patchUrl = "https://graph.microsoft.com/v1.0/users/$MailboxUpn/messages/$($m.id)"
        curl.exe --silent --show-error --max-time 15 `
            -X PATCH $patchUrl `
            -H "Authorization: Bearer $graphToken" `
            -H 'Content-Type: application/json' `
            --data '{"isRead":true}' | Out-Null
        Write-Host ("    marked read: {0}" -f $m.subject) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "reset complete." -ForegroundColor Green
