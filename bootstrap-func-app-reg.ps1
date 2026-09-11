# Idempotently create the Entra App Registration that gates func-triage via
# Easy Auth v2. Foundry project MI (and any other allowedPrincipal) requests
# a token with `aud=api://func-triage`; Easy Auth validates the token and then
# checks the caller's oid against the allowedPrincipals list configured in
# function.bicep.
#
# Why this isn't in bicep: App Registrations are Microsoft Graph resources
# (Microsoft.Graph/applications), not ARM. Terraform + Bicep both treat
# them as out-of-band. The tenant policy 'InvalidUniqueTenantIdentifierAsPerAppPolicy'
# also blocks the short `api://func-triage` URI unless `requestedAccessTokenVersion=2`
# is set FIRST — bicep's ordering guarantees aren't sufficient there.
#
# Run this once per environment, before `azd up` or the first Foundry agent
# deploy. Re-running is safe.
#
# Prereqs: az login as a user with Application.ReadWrite.All on the tenant.

[CmdletBinding()]
param(
    [string] $DisplayName        = 'func-triage',
    [string] $IdentifierUri      = 'api://func-triage',
    [ValidateSet('AzureADMyOrg','AzureADMultipleOrgs')]
    [string] $SignInAudience     = 'AzureADMyOrg'
)

$ErrorActionPreference = 'Stop'

# 1. Ensure the app exists (idempotent lookup by displayName).
$existing = az ad app list --display-name $DisplayName --query "[?displayName=='$DisplayName']" -o json | ConvertFrom-Json
if ($existing.Count -gt 1) {
    throw "Multiple applications named '$DisplayName' exist. Resolve manually before running this script."
}

if ($existing.Count -eq 0) {
    Write-Host "Creating application '$DisplayName'..."
    $app = az ad app create --display-name $DisplayName --sign-in-audience $SignInAudience -o json | ConvertFrom-Json
} else {
    $app = $existing[0]
    Write-Host "Application '$DisplayName' already exists (appId=$($app.appId))."
}

$appObjectId = $app.id

# 2. Force v2 tokens BEFORE setting identifierUri — the tenant policy
#    'InvalidUniqueTenantIdentifierAsPerAppPolicy' rejects `api://func-triage`
#    unless requestedAccessTokenVersion=2 is already true.
$patchV2 = @{ api = @{ requestedAccessTokenVersion = 2 } } | ConvertTo-Json -Compress
$patchV2 | Set-Content -NoNewline "$env:TEMP\app-v2.json"
az rest --method patch `
    --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
    --headers "Content-Type=application/json" `
    --body "@$env:TEMP\app-v2.json" | Out-Null
Write-Host "  requestedAccessTokenVersion = 2"

# 3. Set identifierUri (idempotent — Graph deduplicates).
$patchUri = @{ identifierUris = @($IdentifierUri) } | ConvertTo-Json -Compress
$patchUri | Set-Content -NoNewline "$env:TEMP\app-uri.json"
az rest --method patch `
    --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
    --headers "Content-Type=application/json" `
    --body "@$env:TEMP\app-uri.json" | Out-Null
Write-Host "  identifierUris  = [$IdentifierUri]"

# 4. Ensure a service principal exists for the app in this tenant. Without an
#    SP the identifierUri resolves to nothing during token acquisition and
#    Entra returns AADSTS500011 to callers.
$sp = az ad sp list --filter "appId eq '$($app.appId)'" -o json | ConvertFrom-Json
if ($sp.Count -eq 0) {
    Write-Host "Creating service principal for appId $($app.appId)..."
    az ad sp create --id $app.appId | Out-Null
} else {
    Write-Host "Service principal already exists (spObjectId=$($sp[0].id))."
}

# 4a. Expose a `user_impersonation` delegated scope so the Demo Cockpit
#     (running on the presenter's laptop) can request a user-token for
#     `api://func-triage` via `az account get-access-token`. Without this the
#     App Reg only accepts application (MI-to-MI) tokens.
#     Pre-authorize the Azure CLI client (well-known appId
#     04b07795-8ddb-461a-bbee-02f9e1bf7b46) so no interactive consent prompt
#     is required — az CLI just gets the token silently.
$azureCliAppId  = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
$scopeGuid      = 'a5f80c48-8dbf-4ff8-bfae-cad55c69f9c1'  # stable, arbitrary
$currentApp     = az rest --method get `
    --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
    --headers "Content-Type=application/json" | ConvertFrom-Json
$currentScopes  = @()
if ($currentApp.api -and $currentApp.api.oauth2PermissionScopes) {
    $currentScopes = @($currentApp.api.oauth2PermissionScopes)
}
$hasUserImpersonation = $currentScopes | Where-Object { $_.value -eq 'user_impersonation' }
if (-not $hasUserImpersonation) {
    $currentScopes += [ordered]@{
        id                      = $scopeGuid
        adminConsentDescription = 'Allow the application to call func-triage as the signed-in user (Demo Cockpit).'
        adminConsentDisplayName = 'Access func-triage as user'
        userConsentDescription  = 'Allow the app to access func-triage on your behalf.'
        userConsentDisplayName  = 'Access func-triage'
        value                   = 'user_impersonation'
        type                    = 'User'
        isEnabled               = $true
    }
}

$currentPreAuth = @()
if ($currentApp.api -and $currentApp.api.preAuthorizedApplications) {
    $currentPreAuth = @($currentApp.api.preAuthorizedApplications)
}
$hasAzCli = $currentPreAuth | Where-Object { $_.appId -eq $azureCliAppId }
if ($hasAzCli) {
    # Ensure our scope is in the delegatedPermissionIds list for the existing entry.
    $hasAzCli.delegatedPermissionIds = @(($hasAzCli.delegatedPermissionIds + $scopeGuid) | Select-Object -Unique)
} else {
    $currentPreAuth += [ordered]@{
        appId                  = $azureCliAppId
        delegatedPermissionIds = @($scopeGuid)
    }
}

$apiPatch1 = @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = $currentScopes
    }
} | ConvertTo-Json -Depth 10 -Compress
$apiPatch1 | Set-Content -NoNewline "$env:TEMP\app-api-1.json"
az rest --method patch `
    --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
    --headers "Content-Type=application/json" `
    --body "@$env:TEMP\app-api-1.json" | Out-Null
Write-Host "  oauth2PermissionScopes  += user_impersonation ($scopeGuid)"

# Second PATCH: preAuthorizedApplications must reference existing scope ids, so
# it can only be sent after the scope PATCH above lands.
$apiPatch2 = @{
    api = @{
        preAuthorizedApplications = $currentPreAuth
    }
} | ConvertTo-Json -Depth 10 -Compress
$apiPatch2 | Set-Content -NoNewline "$env:TEMP\app-api-2.json"
az rest --method patch `
    --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
    --headers "Content-Type=application/json" `
    --body "@$env:TEMP\app-api-2.json" | Out-Null
Write-Host "  preAuthorizedApplications += Azure CLI ($azureCliAppId)"

# 5. Print the values downstream config needs.
Write-Host ""
Write-Host "Wire these into function.bicep / function.bicepparam:"
Write-Host "  clientId (Easy Auth registration.clientId): $DisplayName"
Write-Host "  aud      (Easy Auth allowedAudiences[0])  : $IdentifierUri"
Write-Host ""
Write-Host "Foundry OpenAPI tools should set:"
Write-Host "  auth.type      = managed_identity"
Write-Host "  auth.audience  = $IdentifierUri"
Write-Host ""

# Cleanup temp files.
Remove-Item -Force "$env:TEMP\app-v2.json","$env:TEMP\app-uri.json","$env:TEMP\app-api-1.json","$env:TEMP\app-api-2.json" -ErrorAction SilentlyContinue
