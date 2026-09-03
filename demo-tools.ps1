<#
.SYNOPSIS
    Demo helper — inspect + reset SQL state via the Function App.

.DESCRIPTION
    sql-db-sme sits behind a private endpoint, so all SQL access from a
    demo operator's laptop happens through the Function App (which lives
    in the VNet, has MI on the DB, and is fronted by Easy Auth). This
    replaces the previous ACI-jumpbox flow.

    Auth: acquires a delegated user token for the Function App's audience
    (`api://<functionAppName>`), so the operator's user identity must be
    on the Easy Auth allowedPrincipals list, OR the Function App exposes
    the endpoints anonymously and relies on a network/proxy gate (default
    posture: allowedPrincipals restricts to the Foundry MI only, so add
    yourself explicitly with `az functionapp auth ...` if you want to run
    this from your laptop).

.PARAMETER Mode
    reset   - POST /admin/reset  (bootstrap + reseed source_orders + clear dq_flags)
    seed    - POST /admin/seed   (first-time schema + duplicates seed)
    flags   - POST /admin/flags  (dump dbo.dq_flags) (default)
    rows    - POST /admin/rows   (dump dbo.source_orders)
    cleanup - POST /admin/cleanup (TRUNCATE dbo.dq_flags)

.EXAMPLE
    .\demo-tools.ps1                # show current flags
    .\demo-tools.ps1 reset          # full reset before a demo
    .\demo-tools.ps1 cleanup        # clear flags between S2 runs
#>
[CmdletBinding()]
param(
    [ValidateSet('reset','seed','flags','rows','cleanup')]
    [string]$Mode = 'flags',

    [string]$FunctionHost = 'func-sme.azurewebsites.net',
    [string]$FunctionAudience = 'api://func-sme'
)

$ErrorActionPreference = 'Stop'

# --- Acquire an Entra token for the Function App audience ---------------
$token = az account get-access-token --resource $FunctionAudience `
    --query accessToken -o tsv 2>$null
if (-not $token) {
    throw "Failed to acquire token for $FunctionAudience. Run 'az login' and confirm your user is on the Function App Easy Auth allowedPrincipals list."
}

$url = "https://$FunctionHost/api/admin/$Mode"

Write-Host "-> POST $url"
$resp = curl.exe --silent --show-error --fail-with-body `
    -X POST $url `
    -H "Authorization: Bearer $token" `
    -H 'Content-Type: application/json' `
    --data '{}'

# Try to pretty-print; fall back to raw
try {
    $obj = $resp | ConvertFrom-Json
    $obj | ConvertTo-Json -Depth 10
}
catch {
    Write-Output $resp
}
