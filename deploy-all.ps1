<#
.SYNOPSIS
    End-to-end provision of the rg-triage stack from scratch.

.DESCRIPTION
    Idempotent-ish sequential deploy of every Azure resource + code +
    agent needed to run the BI Triage demo. Assumes:
      * .env is populated and dot-sourced
      * signed in via `az login` with rights to create Cog Svc + Function
        + SQL + networking in $env:AZURE_SUBSCRIPTION_ID
      * Application.ReadWrite.All on the tenant (for the App Reg bootstrap)

    Deploy order — each step captures outputs and feeds the next:
      1  bootstrap Entra App Registration (func-triage)
      2  main.bicep         → SQL server + DB (public access + client IP
                              enabled temporarily so we can grant later)
      3  network.bicep      → VNet, subnets, private DNS, SQL PE
      4  foundry.bicep      → AI Foundry account + project + gpt-4o
      5  function.bicep     → Function App + plan + storage + App Insights
      6  grant-function-mi  → SQL user + roles for func-triage MI
      7  func publish       → deploy Python code
      8  deploy-agents      → DQ + Triage prompt agents

    Emits deployment output resource ids / MI object ids into .env as it
    goes, so a re-run picks up where the last run stopped.
#>
[CmdletBinding()]
param(
    [ValidateSet('all','app-reg','sql','network','foundry','function','grant','code','agents')]
    [string] $From = 'all'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
. .\scripts\load-env.ps1

function Write-Step($msg) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " $msg" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Set-EnvVarInFile {
    param([string] $Key, [string] $Value)
    $path = Join-Path $PSScriptRoot '.env'
    $lines = Get-Content -LiteralPath $path
    $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match "^\s*$Key\s*=") {
            "$Key=$Value"
            $found = $true
        } else {
            $line
        }
    }
    if (-not $found) { $out += "$Key=$Value" }
    Set-Content -LiteralPath $path -Value $out -NoNewline:$false
    Set-Item -Path "Env:$Key" -Value $Value
}

$steps = @('app-reg','sql','network','foundry','function','grant','code','agents')
$startIdx = if ($From -eq 'all') { 0 } else { $steps.IndexOf($From) }

# -----------------------------------------------------------------------
# 1. Entra App Registration (func-triage)
# -----------------------------------------------------------------------
if ($startIdx -le 0) {
    Write-Step "Step 1/8 — Entra App Registration (func-triage)"
    # Best-effort cleanup of the old func-sme reg
    $stale = az ad app list --display-name "func-sme" --query "[?displayName=='func-sme'].id" -o tsv 2>$null
    if ($stale) {
        Write-Host "-> Deleting stale App Registration 'func-sme' ($stale)"
        az ad app delete --id $stale 2>&1 | Out-Null
    }
    .\bootstrap-func-app-reg.ps1
}

# -----------------------------------------------------------------------
# 2. SQL server + database (main.bicep) — public access with client IP
# -----------------------------------------------------------------------
if ($startIdx -le 1) {
    Write-Step "Step 2/8 — SQL server + database (main.bicep)"
    # Ensure the resource group exists (idempotent).
    az group create -n $env:AZURE_RESOURCE_GROUP -l $env:AZURE_LOCATION -o none
    # Ensure the resource group exists (idempotent).
    az group create -n $env:AZURE_RESOURCE_GROUP -l $env:AZURE_LOCATION -o none
    # SQL deploys with default publicNetworkAccess=Disabled; grant path goes
    # through an ACI in the jump subnet (see step 6).
    $paramsFull = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            location                 = @{ value = $env:AZURE_LOCATION }
            sqlServerName            = @{ value = $env:SQL_SERVER_NAME }
            sqlDatabaseName          = @{ value = $env:SQL_DATABASE_NAME }
            aadAdminObjectId         = @{ value = $env:AAD_ADMIN_OBJECT_ID }
            aadAdminLogin            = @{ value = $env:AAD_ADMIN_LOGIN }
            aadAdminTenantId         = @{ value = $env:AZURE_TENANT_ID }
            aadAdminPrincipalType    = @{ value = $env:AAD_ADMIN_PRINCIPAL_TYPE }
        }
    } | ConvertTo-Json -Depth 6
    $paramsPath = Join-Path $env:TEMP 'sql.parameters.json'
    Set-Content -LiteralPath $paramsPath -Value $paramsFull
    az deployment group create `
        -g $env:AZURE_RESOURCE_GROUP `
        -n sql-deploy `
        -f main.bicep `
        -p "@$paramsPath" `
        -o json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "main.bicep deployment failed" }
    $sqlFqdn = az deployment group show -g $env:AZURE_RESOURCE_GROUP -n sql-deploy --query "properties.outputs.sqlServerFqdn.value" -o tsv
    Set-EnvVarInFile -Key 'SQL_SERVER_FQDN' -Value $sqlFqdn
    Write-Host "-> SQL FQDN: $sqlFqdn"
}

# -----------------------------------------------------------------------
# 3. VNet + subnets + private DNS + SQL PE (network.bicep)
# -----------------------------------------------------------------------
if ($startIdx -le 2) {
    Write-Step "Step 3/8 — Network (network.bicep)"
    az deployment group create `
        -g $env:AZURE_RESOURCE_GROUP `
        -n network-deploy `
        -f network.bicep `
        -p network.bicepparam `
        -o json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "network.bicep deployment failed" }
    $foundrySubnetId  = az deployment group show -g $env:AZURE_RESOURCE_GROUP -n network-deploy --query "properties.outputs.foundrySubnetId.value" -o tsv
    $functionSubnetId = az deployment group show -g $env:AZURE_RESOURCE_GROUP -n network-deploy --query "properties.outputs.functionSubnetId.value" -o tsv
    $peSubnetId       = az deployment group show -g $env:AZURE_RESOURCE_GROUP -n network-deploy --query "properties.outputs.peSubnetId.value" -o tsv
    Set-EnvVarInFile -Key 'FOUNDRY_SUBNET_ID'  -Value $foundrySubnetId
    Set-EnvVarInFile -Key 'FUNCTION_SUBNET_ID' -Value $functionSubnetId
    Set-EnvVarInFile -Key 'PE_SUBNET_ID'       -Value $peSubnetId
    Write-Host "-> Foundry subnet:  $foundrySubnetId"
    Write-Host "-> Function subnet: $functionSubnetId"
    Write-Host "-> PE subnet:       $peSubnetId"
}

# -----------------------------------------------------------------------
# 4. AI Foundry account + project + model deployment (foundry.bicep)
# -----------------------------------------------------------------------
if ($startIdx -le 3) {
    Write-Step "Step 4/8 — AI Foundry (foundry.bicep)"
    az deployment group create `
        -g $env:AZURE_RESOURCE_GROUP `
        -n foundry-deploy `
        -f foundry.bicep `
        -p foundry.bicepparam `
        -o json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "foundry.bicep deployment failed" }
    # Capture the project MI object id — needed by function.bicep allowedPrincipals.
    $projMi = az cognitiveservices account project show `
        --resource-group $env:AZURE_RESOURCE_GROUP `
        --account-name $env:FOUNDRY_ACCOUNT_NAME `
        --name $env:FOUNDRY_PROJECT_NAME `
        --query "identity.principalId" -o tsv
    Set-EnvVarInFile -Key 'FOUNDRY_PROJECT_MI_OBJECT_ID' -Value $projMi
    Write-Host "-> Foundry project MI: $projMi"
}

# -----------------------------------------------------------------------
# 5. Function App + plan + storage + App Insights (function.bicep)
# -----------------------------------------------------------------------
if ($startIdx -le 4) {
    Write-Step "Step 5/8 — Function App (function.bicep)"
    az deployment group create `
        -g $env:AZURE_RESOURCE_GROUP `
        -n function-deploy `
        -f function.bicep `
        -p function.bicepparam `
        -o json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "function.bicep deployment failed" }
    $funcMi = az functionapp identity show -g $env:AZURE_RESOURCE_GROUP -n $env:FUNCTION_APP_NAME --query principalId -o tsv
    $funcApp = az ad sp show --id $funcMi --query appId -o tsv
    Set-EnvVarInFile -Key 'FUNCTION_MI_OBJECT_ID' -Value $funcMi
    Set-EnvVarInFile -Key 'FUNCTION_MI_APP_ID'   -Value $funcApp
    Write-Host "-> Function App MI object id: $funcMi"
    Write-Host "-> Function App MI appId:    $funcApp"
}

# -----------------------------------------------------------------------
# 6. Grant SQL access to the Function App MI (via ephemeral ACI in VNet)
# -----------------------------------------------------------------------
if ($startIdx -le 5) {
    Write-Step "Step 6/8 — Grant SQL access via ephemeral ACI in jumpSubnet"

    $uamiName    = 'id-triage-grantor'
    $aciName     = 'aci-grant-triage'
    $jumpSubnet  = az deployment group show -g $env:AZURE_RESOURCE_GROUP -n network-deploy `
        --query "properties.outputs.jumpSubnetId.value" -o tsv

    # 6a. Ensure the user-assigned MI exists.
    $uami = az identity create -g $env:AZURE_RESOURCE_GROUP -n $uamiName -l $env:AZURE_LOCATION -o json | ConvertFrom-Json
    $uamiPrincipalId = $uami.principalId
    $uamiClientId    = $uami.clientId
    $uamiResourceId  = $uami.id
    Write-Host "-> UAMI principalId: $uamiPrincipalId"
    Write-Host "-> UAMI clientId:    $uamiClientId"

    # 6b. Snapshot the current SQL AAD admin so we can restore later.
    $originalAdmin = az sql server ad-admin list `
        --resource-group $env:AZURE_RESOURCE_GROUP `
        --server $env:SQL_SERVER_NAME -o json | ConvertFrom-Json
    $originalAdminSid   = $originalAdmin.sid
    $originalAdminLogin = $originalAdmin.login
    Write-Host "-> Current SQL admin: $originalAdminLogin ($originalAdminSid)"

    # 6c. Swap SQL admin to the UAMI so ACI can authenticate.
    Write-Host "-> Swapping SQL admin to $uamiName..."
    az sql server ad-admin update `
        --resource-group $env:AZURE_RESOURCE_GROUP `
        --server $env:SQL_SERVER_NAME `
        --display-name $uamiName `
        --object-id $uamiPrincipalId -o none

    # 6d. Compute the SID literal (byte-swapped little-endian) for the
    #     Function App's system-assigned MI appId, then build the grant SQL.
    $g = [Guid]$env:FUNCTION_MI_APP_ID
    $sidHex = '0x' + ([BitConverter]::ToString($g.ToByteArray()) -replace '-','')
    Write-Host "-> Function App SID literal: $sidHex"

    $grantSql = @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$($env:FUNCTION_APP_NAME)') DROP USER [$($env:FUNCTION_APP_NAME)];
CREATE USER [$($env:FUNCTION_APP_NAME)] WITH SID = $sidHex, TYPE = E;
ALTER ROLE db_datareader ADD MEMBER [$($env:FUNCTION_APP_NAME)];
ALTER ROLE db_datawriter ADD MEMBER [$($env:FUNCTION_APP_NAME)];
ALTER ROLE db_ddladmin  ADD MEMBER [$($env:FUNCTION_APP_NAME)];
SELECT name FROM sys.database_principals WHERE name = N'$($env:FUNCTION_APP_NAME)';
"@

    # ACI startup: install go-sqlcmd, run the grant using UAMI-based auth.
    # We inline the SQL via base64 to avoid shell-quoting hell.
    $sqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($grantSql))
    $shellCmd = @"
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates gnupg lsb-release
curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
echo 'deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-ubuntu-jammy-prod jammy main' > /etc/apt/sources.list.d/mssql-release.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive ACCEPT_EULA=Y apt-get install -y -qq sqlcmd
echo '$sqlB64' | base64 -d > /tmp/grant.sql
sqlcmd -S $($env:SQL_SERVER_FQDN) -d $($env:SQL_DATABASE_NAME) --authentication-method ActiveDirectoryManagedIdentity --user-name $uamiClientId -i /tmp/grant.sql
echo GRANT_OK
"@
    # Strip CR chars — bash barfs on \r\n line endings.
    $shellCmd  = ($shellCmd -replace "`r","")
    $shellB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($shellCmd))

    # 6e. Build an ACI YAML spec (much cleaner than trying to escape
    #     bash-with-heredoc through `az container create --command-line`).
    $aciYaml = @"
apiVersion: '2021-10-01'
location: $($env:AZURE_LOCATION)
name: $aciName
identity:
  type: UserAssigned
  userAssignedIdentities:
    '$uamiResourceId': {}
properties:
  osType: Linux
  restartPolicy: Never
  subnetIds:
    - id: $jumpSubnet
  containers:
    - name: grantor
      properties:
        image: ubuntu:22.04
        resources:
          requests:
            cpu: 1
            memoryInGB: 1.0
        command:
          - bash
          - -c
          - "echo $shellB64 | base64 -d > /tmp/run.sh && bash /tmp/run.sh"
type: Microsoft.ContainerInstance/containerGroups
"@
    $aciYamlPath = Join-Path $env:TEMP 'aci-grant.yaml'
    Set-Content -LiteralPath $aciYamlPath -Value $aciYaml -NoNewline:$false

    # 6f. Create the ACI. It runs the base64-encoded script then exits.
    Write-Host "-> Creating ACI '$aciName' in jumpSubnet..."
    # Small delay so the AAD admin swap propagates to SQL's control plane.
    Start-Sleep -Seconds 30
    az container create `
        --resource-group $env:AZURE_RESOURCE_GROUP `
        --file $aciYamlPath `
        -o none
    if ($LASTEXITCODE -ne 0) {
        # Restore SQL admin so we don't leave the server in a swapped state.
        az sql server ad-admin update -g $env:AZURE_RESOURCE_GROUP --server $env:SQL_SERVER_NAME --display-name $originalAdminLogin --object-id $originalAdminSid -o none
        az identity delete -g $env:AZURE_RESOURCE_GROUP -n $uamiName -o none 2>&1 | Out-Null
        throw "az container create failed"
    }

    # 6f. Poll for completion (max 6 min).
    Write-Host "-> Waiting for ACI to finish..."
    $done = $false
    for ($i = 0; $i -lt 36; $i++) {
        Start-Sleep -Seconds 10
        $state = az container show -g $env:AZURE_RESOURCE_GROUP -n $aciName `
            --query "containers[0].instanceView.currentState.state" -o tsv 2>$null
        Write-Host "   [$i] state=$state"
        if ($state -eq 'Terminated' -or $state -eq 'Failed') { $done = $true; break }
    }

    # 6g. Fetch logs.
    Write-Host ""
    Write-Host "-> ACI logs:"
    # Check for actual grant success in ACI logs, not just exit code — the
    # earlier CRLF-broken script "exited 0" while every install failed.
    $logs = az container logs -g $env:AZURE_RESOURCE_GROUP -n $aciName 2>&1 | Out-String
    Write-Host $logs
    $exit = az container show -g $env:AZURE_RESOURCE_GROUP -n $aciName `
        --query "containers[0].instanceView.currentState.exitCode" -o tsv 2>$null

    # 6h. Restore SQL admin regardless of grant success.
    Write-Host ""
    Write-Host "-> Restoring SQL admin to $originalAdminLogin..."
    az sql server ad-admin update `
        --resource-group $env:AZURE_RESOURCE_GROUP `
        --server $env:SQL_SERVER_NAME `
        --display-name $originalAdminLogin `
        --object-id $originalAdminSid -o none

    # 6i. Delete the ACI + UAMI.
    az container delete -g $env:AZURE_RESOURCE_GROUP -n $aciName --yes -o none
    az identity delete -g $env:AZURE_RESOURCE_GROUP -n $uamiName -o none

    if ($exit -ne '0') { throw "SQL grant ACI failed (exit=$exit) — see logs above" }
    if ($logs -notmatch 'sqlcmd' -or $logs -match 'command not found|Unable to locate') {
        throw "SQL grant ACI logged installation failures — the grant did NOT run"
    }
    Write-Host "-> SQL grant applied successfully"
}

# -----------------------------------------------------------------------
# 7. Publish Function App code
# -----------------------------------------------------------------------
if ($startIdx -le 6) {
    Write-Step "Step 7/8 — Publish Function App code"
    Push-Location function
    try {
        func azure functionapp publish $env:FUNCTION_APP_NAME --python
    } finally {
        Pop-Location
    }
}

# -----------------------------------------------------------------------
# 8. Deploy the two prompt agents
# -----------------------------------------------------------------------
if ($startIdx -le 7) {
    Write-Step "Step 8/8 — Deploy DQ + Triage agents"
    $env:AZURE_AI_PROJECT_ENDPOINT = "https://$($env:FOUNDRY_ACCOUNT_NAME).services.ai.azure.com/api/projects/$($env:FOUNDRY_PROJECT_NAME)"
    $env:AZURE_AI_ACCOUNT_NAME     = $env:FOUNDRY_ACCOUNT_NAME
    $env:AZURE_AI_PROJECT_NAME     = $env:FOUNDRY_PROJECT_NAME
    Push-Location agents
    try {
        .\deploy-agents.ps1
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Deploy complete." -ForegroundColor Green
Write-Host " Run:  .\demo-fire.ps1 -Scenario clean" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
