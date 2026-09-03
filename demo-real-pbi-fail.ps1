<#
.SYNOPSIS
    Trigger a REAL Power BI refresh failure so the PBI service itself emails
    the "Refresh failed" notification to the shared triage inbox.

.DESCRIPTION
    Unlike send-demo-email.ps1 (which fabricates a JSON payload) this script
    calls the Power BI REST API to start an on-demand refresh of a "canary"
    dataset that is intentionally broken (source table / URL does not exist).
    Because we pass notifyOption=MailOnFailure, Power BI service will send the
    standard refresh-failure email to the dataset owner + any contacts
    configured on the dataset's Scheduled Refresh page. Point that contact list
    at your monitored shared inbox and you get an end-to-end real signal.

    Prereqs (one-time):
      1. Publish a canary dataset that will always fail. Easiest: a Power Query
         with Web.Contents("https://invalid.contoso.invalid/canary") or a SQL
         source pointing at dbo.canary_nonexistent.
      2. On that dataset's Settings > Scheduled refresh page, add the shared
         inbox address under "Send refresh failure notifications to these
         contacts". (The owner also gets one automatically.)
      3. Make sure your az-cli identity has at least Member on the workspace.

.PARAMETER WorkspaceId
    Power BI workspace (group) GUID that contains the canary dataset.

.PARAMETER DatasetId
    Dataset GUID for the canary dataset.

.EXAMPLE
    .\demo-real-pbi-fail.ps1 `
        -WorkspaceId $env:PBI_WORKSPACE_ID `
        -DatasetId   00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$DatasetId
)

$ErrorActionPreference = 'Stop'

Write-Host "→ Acquiring Power BI service token via az..." -ForegroundColor Cyan
$token = az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv 2>$null
if (-not $token) { throw "No PBI token. Run 'az login' first." }

$uri = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/datasets/$DatasetId/refreshes"

# notifyOption=MailOnFailure is the key: PBI service will send the standard
# refresh-failure email to the owner + configured failure contacts once the
# refresh finishes and fails.
$body = @{
    notifyOption = 'MailOnFailure'
    type         = 'Full'
} | ConvertTo-Json -Compress

Write-Host "→ POST $uri" -ForegroundColor Cyan
$resp = Invoke-WebRequest -Uri $uri -Method POST `
    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
    -Body $body -SkipHttpErrorCheck

if ($resp.StatusCode -eq 202) {
    $requestId = $resp.Headers['RequestId']
    $location  = $resp.Headers['Location']
    Write-Host ""
    Write-Host "✔ Refresh accepted (202)." -ForegroundColor Green
    Write-Host "  RequestId : $requestId"
    Write-Host "  Location  : $location"
    Write-Host ""
    Write-Host "Power BI service will run the refresh, it will fail against the"
    Write-Host "broken source, and PBI will email the failure notification to"
    Write-Host "the dataset owner and configured contacts. Watch the inbox."
    Write-Host ""
    Write-Host "Tail refresh status:" -ForegroundColor Yellow
    Write-Host "  curl -s -H `"Authorization: Bearer <token>`" `"$uri`" | ConvertFrom-Json"
} else {
    Write-Host "✖ Refresh request failed: HTTP $($resp.StatusCode)" -ForegroundColor Red
    Write-Host $resp.Content
}
