# Idempotently grant Microsoft Graph app roles to the func-sme managed
# identity so `poll_inbox` can list AND mark-as-read mail in the demo
# mailbox, and the `demo_teams` tile can read Teams channel messages.
#
# Why this isn't in bicep: Graph app-role assignments live under
# `/servicePrincipals/{id}/appRoleAssignments` — Microsoft.Graph resources,
# not ARM. Bicep + Terraform both treat them as out-of-band. This script
# is the mirror of `bootstrap-func-app-reg.ps1`, which manages the Entra
# App Registration for the same reason.
#
# Roles granted (Graph -> Application permissions):
#   Mail.Read           — required by poll_inbox to list unread mail
#   Mail.ReadWrite      — required by poll_inbox to PATCH isRead=true so
#                         each mail is processed EXACTLY ONCE. Without
#                         this the mark-as-read call 403s, the mail
#                         stays unread, and every subsequent 30s tick
#                         re-processes the same mail, incrementing the
#                         incident occurrence_count. That failure mode
#                         is exactly what the signature-dedup guard was
#                         designed to catch, but the operator sees a
#                         runaway counter and thinks the demo is broken.
#   Mail.Send           — required by notification paths (already present
#                         in every environment we've checked, but
#                         included here for idempotence).
#
# NOTE ON TEAMS: reading Teams channel messages for the /api/demo/teams
# cockpit tile requires the `ChannelMessage.Read.All` app permission,
# but that permission is protected by Microsoft's Resource-Specific
# Consent (RSC) model — you have to grant it via a Teams App manifest,
# NOT via a plain Graph app-role assignment. It cannot be added to a
# Function App MI through this script. If the Teams tile ever needs
# to be re-wired, use the Teams admin portal or a Microsoft 365 Apps
# manifest with the RSC permission declared.
#
# Run this once per environment, after `azd up` has created the Function
# App and its system-assigned MI. Re-running is safe.
#
# Prereqs: az login as a user with `AppRoleAssignment.ReadWrite.All` on
# the tenant (typically Global Administrator or Privileged Role
# Administrator).

[CmdletBinding()]
param(
    [string] $FunctionAppName = 'func-sme',
    [string] $ResourceGroup   = 'rg-sme'
)

$ErrorActionPreference = 'Stop'

# --- Well-known Graph app-role ids (stable, documented on learn.microsoft.com) ---
$GRAPH_APP_ID = '00000003-0000-0000-c000-000000000000'
$ROLES = @{
    'Mail.Read'      = '810c84a8-4a9e-49e6-bf7d-12d183f40d01'
    'Mail.ReadWrite' = '6918b873-d17a-4dc1-b314-35f528134491'
    'Mail.Send'      = 'e2a3a72e-5f79-4c64-b1b1-878b674786c9'
}

# --- Resolve principals ------------------------------------------------

$funcMi = az functionapp identity show `
    -n $FunctionAppName -g $ResourceGroup `
    --query principalId -o tsv 2>$null
if (-not $funcMi) {
    throw "Could not read managed identity for $FunctionAppName in $ResourceGroup. Is the Function App deployed and does it have a system-assigned identity?"
}
Write-Host "Function App MI principal id : $funcMi"

$graphSp = az ad sp list --filter "appId eq '$GRAPH_APP_ID'" --query "[0].id" -o tsv
if (-not $graphSp) {
    throw 'Microsoft Graph service principal not found in this tenant.'
}
Write-Host "Microsoft Graph SP object id : $graphSp"
Write-Host ''

# --- Read existing assignments so we can be idempotent -----------------

$existing = az rest --method GET `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$funcMi/appRoleAssignments" `
    --query 'value[].appRoleId' -o tsv 2>$null
$existingSet = @{}
foreach ($id in ($existing -split "`n")) { if ($id) { $existingSet[$id.Trim()] = $true } }

# --- Grant each role, skipping ones already present --------------------

foreach ($roleName in $ROLES.Keys) {
    $roleId = $ROLES[$roleName]
    if ($existingSet.ContainsKey($roleId)) {
        Write-Host "  [skip] $roleName ($roleId) already granted"
        continue
    }
    Write-Host "  [grant] $roleName ($roleId)"

    # az rest --body only accepts @file syntax reliably on Windows —
    # inline JSON gets mangled by the shell escape.
    $body = "{`"principalId`":`"$funcMi`",`"resourceId`":`"$graphSp`",`"appRoleId`":`"$roleId`"}"
    $tmp  = New-TemporaryFile
    try {
        [System.IO.File]::WriteAllText($tmp.FullName, $body, [System.Text.UTF8Encoding]::new($false))
        az rest --method POST `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$funcMi/appRoleAssignments" `
            --body "@$($tmp.FullName)" `
            --query 'id' -o tsv | Out-Null
    } finally {
        Remove-Item -Force -LiteralPath $tmp.FullName -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'Verifying final assignment state...'
$after = az rest --method GET `
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$funcMi/appRoleAssignments" `
    --query 'value[].appRoleId' -o tsv
$afterSet = @{}
foreach ($id in ($after -split "`n")) { if ($id) { $afterSet[$id.Trim()] = $true } }

$missing = @()
foreach ($roleName in $ROLES.Keys) {
    if (-not $afterSet.ContainsKey($ROLES[$roleName])) { $missing += $roleName }
}
if ($missing.Count -gt 0) {
    throw "Missing after grant: $($missing -join ', '). Re-run this script as a user with AppRoleAssignment.ReadWrite.All."
}

Write-Host 'All required Graph app roles are assigned.'
Write-Host 'Propagation to Function App runtime typically completes within ~2 minutes.'
