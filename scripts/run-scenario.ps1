# scripts/run-scenario.ps1 — one-shot runner for scenarios/*.yaml
#
# Waits for YOU to manually send a demo email that matches a scenario's
# payload, then observes the run through the Function App poller and
# agents, optionally auto-approves any outstanding approval, and asserts
# the YAML's `expect` block against the SQL state.
#
# Why manual send? Graph's /me/sendMail from an MSIT identity into the
# demo tenant's mailbox returns MailboxNotEnabledForRESTAPI. Rather than
# fight the tenant plumbing here, the runner treats the trigger as an
# external event — send the email however you normally send it (Outlook,
# Copilot cockpit, `send-demo-email.ps1`, or a manual Graph call from
# a demo-tenant user) and this script picks it up from `demo_events`.
#
# Prereqs:
#   * az login (any user that can hit api://func-sme)
#   * $env:FUNCTION_APP_BASE_URL   e.g. https://func-sme.azurewebsites.net
#   * $env:FUNCTION_APP_AUDIENCE   e.g. api://func-sme
#
# Usage (typical):
#   1. .\scripts\run-scenario.ps1 -Name scenario1-transient
#      → the runner prints the payload the email body must contain, then
#        polls demo_events waiting for it.
#   2. In another window, send the email (or click Send in Outlook).
#   3. Runner observes email_received → assertions run.
#
#   .\scripts\run-scenario.ps1 -All        # runs all 7 in sequence
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Name,
    [switch]$All,
    [int]$TimeoutSec = 300,
    [switch]$SkipReset,
    [switch]$VerboseAssert
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------
# Prereqs + helpers
# -----------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force -AcceptLicense | Out-Null
}
Import-Module powershell-yaml -Force

$repoRoot     = Split-Path -Parent $PSScriptRoot
$scenariosDir = Join-Path $repoRoot 'scenarios'

$funcBase = $env:FUNCTION_APP_BASE_URL
$funcAud  = $env:FUNCTION_APP_AUDIENCE
if (-not $funcBase -or -not $funcAud) {
    throw "FUNCTION_APP_BASE_URL and FUNCTION_APP_AUDIENCE env vars are required."
}

function Get-FuncToken {
    $t = az account get-access-token --resource $funcAud --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Failed to acquire token for $funcAud. Run az login." }
    return $t
}

function Invoke-FuncPost {
    param([string]$Path, [hashtable]$Body)
    $token = Get-FuncToken
    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        $r = curl.exe --silent --show-error --fail-with-body `
            -X POST "$funcBase$Path" `
            -H "Authorization: Bearer $token" `
            -H 'Content-Type: application/json' `
            --data-binary "@$tmp"
        return ($r | ConvertFrom-Json -AsHashtable)
    } finally { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

# -----------------------------------------------------------------------
# Run one scenario end-to-end (manual send)
# -----------------------------------------------------------------------

function Invoke-Scenario {
    param([string]$Path)

    $spec = (Get-Content -Raw -LiteralPath $Path) | ConvertFrom-Yaml
    $name = $spec.name
    Write-Host ''
    Write-Host "==== $name ====" -ForegroundColor Cyan
    Write-Host $spec.description
    Write-Host ''

    # Print the payload the presenter should embed in the email body.
    $payloadJson = $spec.payload | ConvertTo-Json -Depth 6 -Compress
    Write-Host '  SEND THIS as the email body (subject prefix: [BI-DEMO]):' -ForegroundColor Yellow
    Write-Host "  $payloadJson"
    Write-Host ''
    Write-Host "  Waiting up to $TimeoutSec s for email_received on report='$($spec.payload.report)'..."

    # Watch demo_events for an email_received row that matches the payload's report.
    $started = Get-Date
    $runId = $null
    while (((Get-Date) - $started).TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        $events = (Invoke-FuncPost '/api/demo/events' @{ limit_runs = 10 }).runs
        foreach ($run in $events) {
            $first = $run.stages | Where-Object { $_.stage -eq 'email_received' } | Select-Object -First 1
            if ($first -and $first.detail -like "*$($spec.payload.report)*") {
                # Only pick up runs that started AFTER we did — avoid latching to a stale run.
                $runStarted = [DateTime]::Parse($run.started_at).ToUniversalTime()
                if ($runStarted -gt $started.ToUniversalTime().AddSeconds(-10)) {
                    $runId = $run.run_id
                    break
                }
            }
        }
        if ($runId) { break }
    }
    if (-not $runId) {
        Write-Error "$name — never observed a matching email_received event within ${TimeoutSec}s"
        return $false
    }
    Write-Host "  -> run_id=$runId" -ForegroundColor Green

    # If the scenario declares auto_approve, watch for an approval_requested
    # event and POST /api/approvals/decide with the declared decision.
    if ($spec.auto_approve) {
        $decision = $spec.auto_approve.decision
        $actor    = $spec.auto_approve.actor
        $fp = $null
        $approvalStart = Get-Date
        while (((Get-Date) - $approvalStart).TotalSeconds -lt 90) {
            Start-Sleep -Seconds 3
            $approvals = (Invoke-FuncPost '/api/demo/approvals' @{ top = 10 }).rows
            $match = $approvals | Where-Object { $_.run_id -eq $runId -and $_.decision -eq 'pending' } | Select-Object -First 1
            if ($match) { $fp = $match.fingerprint; break }
        }
        if ($fp) {
            Write-Host "  -> auto-$decision approval fingerprint=$($fp.Substring(0,12))..."
            Invoke-FuncPost '/api/approvals/decide' @{
                fingerprint = $fp
                decision    = $decision
                actor       = $actor
            } | Out-Null
        } else {
            Write-Warning "  $name — auto_approve declared but no pending approval found for run $runId"
        }
    }

    # Wait for teams_posted (terminal stage) or timeout.
    $terminal = $false
    while (((Get-Date) - $started).TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 5
        $events = (Invoke-FuncPost '/api/demo/events' @{ limit_runs = 10 }).runs
        $thisRun = $events | Where-Object { $_.run_id -eq $runId } | Select-Object -First 1
        if ($thisRun -and ($thisRun.stages | Where-Object { $_.stage -eq 'teams_posted' })) {
            $terminal = $true
            break
        }
    }
    if (-not $terminal) {
        Write-Warning "  $name — teams_posted not observed within ${TimeoutSec}s. Asserting on partial state."
    }

    return (Test-Expect -Spec $spec -RunId $runId)
}

function Test-Expect {
    param($Spec, [string]$RunId)
    $ok = $true

    $events = (Invoke-FuncPost '/api/demo/events' @{ limit_runs = 10 }).runs
    $thisRun = $events | Where-Object { $_.run_id -eq $RunId } | Select-Object -First 1
    if (-not $thisRun) {
        Write-Warning "  ! no demo_events for run_id=$RunId — skipping stage assertions"
        return $false
    }
    $stages = $thisRun.stages | ForEach-Object { $_.stage }

    if ($Spec.expect.demo_events_stages) {
        foreach ($s in $Spec.expect.demo_events_stages) {
            if ($stages -notcontains $s) {
                Write-Warning "  ! missing stage: $s"
                $ok = $false
            } elseif ($VerboseAssert) {
                Write-Host "    ok stage: $s" -ForegroundColor DarkGray
            }
        }
    }

    if ($Spec.expect.dq_flags_rows_min) {
        $flags = (Invoke-FuncPost '/api/demo/flags' @{}).rows
        $n = ($flags | Where-Object { $_.source_run_id -eq $RunId }).Count
        if ($n -lt [int]$Spec.expect.dq_flags_rows_min) {
            Write-Warning "  ! dq_flags rows for run: $n < min $($Spec.expect.dq_flags_rows_min)"
            $ok = $false
        }
    }

    if ($Spec.expect.policy_ledger_min_denied) {
        $ledger = (Invoke-FuncPost '/api/demo/policy' @{ top = 100 }).rows
        $denied = ($ledger | Where-Object { $_.run_id -eq $RunId -and $_.allowed -eq $false }).Count
        if ($denied -lt [int]$Spec.expect.policy_ledger_min_denied) {
            Write-Warning "  ! policy_ledger denied for run: $denied < min $($Spec.expect.policy_ledger_min_denied)"
            $ok = $false
        }
    }

    if ($Spec.expect.policy_ledger_action_present) {
        $ledger = (Invoke-FuncPost '/api/demo/policy' @{ top = 100 }).rows
        if (-not ($ledger | Where-Object { $_.run_id -eq $RunId -and $_.action -eq $Spec.expect.policy_ledger_action_present })) {
            Write-Warning "  ! expected policy_ledger action not found: $($Spec.expect.policy_ledger_action_present)"
            $ok = $false
        }
    }

    if ($Spec.expect.incidents_min_occurrence) {
        $incs = (Invoke-FuncPost '/api/demo/incidents' @{ top = 20 }).rows
        $max = ($incs | Measure-Object -Property occurrence_count -Maximum).Maximum
        if ([int]$max -lt [int]$Spec.expect.incidents_min_occurrence) {
            Write-Warning "  ! max incident occurrence_count $max < $($Spec.expect.incidents_min_occurrence)"
            $ok = $false
        }
    }

    if ($Spec.expect.approvals_final_decision) {
        $apps = (Invoke-FuncPost '/api/demo/approvals' @{ top = 20 }).rows
        $mine = $apps | Where-Object { $_.run_id -eq $RunId } | Select-Object -First 1
        if (-not $mine -or $mine.decision -ne $Spec.expect.approvals_final_decision) {
            Write-Warning "  ! approvals decision: got $($mine.decision) want $($Spec.expect.approvals_final_decision)"
            $ok = $false
        }
    }

    if ($Spec.expect.teams_body_contains) {
        $teams = (Invoke-FuncPost '/api/demo/teams' @{ top = 5 }).messages
        $body  = ($teams | ForEach-Object {
            if ($_.body_text) { $_.body_text } elseif ($_.body_html) { $_.body_html } else { $_.adaptive_card | ConvertTo-Json -Depth 8 }
        }) -join "`n"
        foreach ($needle in $Spec.expect.teams_body_contains) {
            if ($body -notmatch [regex]::Escape($needle)) {
                Write-Warning "  ! Teams body missing: $needle"
                $ok = $false
            } elseif ($VerboseAssert) {
                Write-Host "    ok teams: $needle" -ForegroundColor DarkGray
            }
        }
    }

    if ($ok) { Write-Host "  PASS $($Spec.name)" -ForegroundColor Green }
    else     { Write-Host "  FAIL $($Spec.name)" -ForegroundColor Red }
    return $ok
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------

# Optional reset — do NOT reset between chained scenarios (2b needs incidents
# from scenario 1 to be present).
if (-not $SkipReset) {
    Write-Host "-> reset (POST /api/demo/reset + /api/demo/cleanup)"
    Invoke-FuncPost '/api/demo/reset' @{}   | Out-Null
    Invoke-FuncPost '/api/demo/cleanup' @{} | Out-Null
}

$targets = @()
if ($All) {
    # depends_on: chain scenario1 → scenario2b so signature dedup works.
    $targets = @(
        'scenario1-transient','scenario2b-known-issue',
        'scenario2-data-quality',
        'scenario3-policy-block','scenario4-unknown-action',
        'scenario5-approval-granted','scenario6-approval-denied'
    )
} elseif ($Name) {
    $targets = @($Name)
} else {
    throw 'Pass -Name <scenario> or -All'
}

$results = @{}
foreach ($t in $targets) {
    $path = Join-Path $scenariosDir "$t.yaml"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "not found: $path"
        continue
    }
    $results[$t] = Invoke-Scenario -Path $path
}

Write-Host ''
Write-Host '==== summary ====' -ForegroundColor Cyan
foreach ($k in $results.Keys) {
    $color = if ($results[$k]) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-32} {1}" -f $k, $(if ($results[$k]) { 'PASS' } else { 'FAIL' })) -ForegroundColor $color
}
$failed = ($results.Values | Where-Object { -not $_ }).Count
if ($failed -gt 0) { exit 1 }
