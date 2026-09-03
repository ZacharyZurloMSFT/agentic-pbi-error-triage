<#
.SYNOPSIS
    Deploy the DQ and Triage prompt agents into the SME Foundry project.

.DESCRIPTION
    Reads the two declarative agent definitions in ./definitions/, inlines
    referenced OpenAPI specs into `tools[].openapi.spec`, resolves managed-
    identity audiences and connection ids from environment variables, and
    PATCHes each agent via the Foundry Agents REST API (equivalent to the
    MCP `agent_update` call).

    Idempotent. Safe to re-run after edits to instructions, tools, or specs.

    Deploy order matters: DQ first (so we know its responses endpoint), then
    Triage (which binds DQ via a2a_preview).

.PARAMETER ProjectEndpoint
    Foundry project endpoint, e.g.
    https://ai-foundry-sme.services.ai.azure.com/api/projects/proj-sme
    Falls back to $env:AZURE_AI_PROJECT_ENDPOINT.

.PARAMETER Only
    Optional. Deploy only 'dq' or 'triage'.

.EXAMPLE
    # First run — set env vars, then deploy both agents
    $env:AZURE_AI_PROJECT_ENDPOINT = 'https://ai-foundry-sme.services.ai.azure.com/api/projects/proj-sme'
    $env:FUNCTION_APP_AUDIENCE     = 'api://func-sme'
    $env:TEAMS_TEAM_ID             = '<team-guid>'
    $env:TEAMS_CHANNEL_ID          = '<channel-id>'
    .\deploy-agents.ps1

.EXAMPLE
    # Re-deploy just Triage after an instructions tweak
    .\deploy-agents.ps1 -Only triage
#>
[CmdletBinding()]
param(
    [string]$ProjectEndpoint = $env:AZURE_AI_PROJECT_ENDPOINT,
    [ValidateSet('dq','triage','both')]
    [string]$Only = 'both'
)

$ErrorActionPreference = 'Stop'

$AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'

if (-not $ProjectEndpoint) {
    throw 'AZURE_AI_PROJECT_ENDPOINT env var or -ProjectEndpoint is required.'
}
if ($ProjectEndpoint -notmatch '^https://[^/]+/api/projects/[^/]+$') {
    throw "ProjectEndpoint must be https://<acct>.services.ai.azure.com/api/projects/<name>; got: $ProjectEndpoint"
}

$scriptDir      = $PSScriptRoot
$definitionsDir = Join-Path $scriptDir 'definitions'

# ARM identifiers needed when a2a_preview tools reference project connections
# by name (deploy-agents.ps1 builds the full resource id from these).
$AZURE_SUBSCRIPTION_ID  = $env:AZURE_SUBSCRIPTION_ID
$AZURE_RESOURCE_GROUP   = $env:AZURE_RESOURCE_GROUP
$AZURE_AI_ACCOUNT_NAME  = $env:AZURE_AI_ACCOUNT_NAME
$AZURE_AI_PROJECT_NAME  = $env:AZURE_AI_PROJECT_NAME

# ----------------------------------------------------------------------
# YAML helpers — install powershell-yaml lazily if missing
# ----------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host '-> Installing powershell-yaml (CurrentUser scope)...'
    Install-Module powershell-yaml -Scope CurrentUser -Force -AcceptLicense
}
Import-Module powershell-yaml -Force

function Resolve-Spec {
    param(
        [Parameter(Mandatory=$true)][string]$SpecPath,
        [Parameter(Mandatory=$true)][string]$RelativeTo
    )
    $abs = if ([System.IO.Path]::IsPathRooted($SpecPath)) {
        $SpecPath
    } else {
        Join-Path $RelativeTo $SpecPath
    }
    if (-not (Test-Path -LiteralPath $abs)) {
        throw "OpenAPI spec not found: $SpecPath (resolved to $abs)"
    }
    $raw = Get-Content -Raw -LiteralPath $abs
    # Template placeholders BEFORE YAML parse so the resulting spec doesn't
    # carry secrets from source. See teams-webhook.yaml for the
    # {{TEAMS_WEBHOOK_ORIGIN}} / {{TEAMS_WEBHOOK_PATH}} pair.
    if ($raw -match '\{\{TEAMS_WEBHOOK_ORIGIN\}\}' -or $raw -match '\{\{TEAMS_WEBHOOK_PATH\}\}') {
        $webhook = $env:TEAMS_WEBHOOK_URL
        if (-not $webhook) {
            throw "TEAMS_WEBHOOK_URL is required to template $SpecPath. Set it in .env (see .env.example)."
        }
        try {
            $uri = [System.Uri]$webhook
        } catch {
            throw "TEAMS_WEBHOOK_URL is not a valid absolute URL: $webhook"
        }
        $origin = "$($uri.Scheme)://$($uri.Authority)"
        $pathAndQuery = $uri.PathAndQuery
        $raw = $raw.Replace('{{TEAMS_WEBHOOK_ORIGIN}}', $origin)
        $raw = $raw.Replace('{{TEAMS_WEBHOOK_PATH}}',   $pathAndQuery)
    }
    $raw | ConvertFrom-Yaml
}

function Resolve-EnvVar {
    param([string]$Name, [switch]$Required)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($Required -and -not $v) {
        throw "Environment variable $Name is required but not set."
    }
    $v
}

# ----------------------------------------------------------------------
# Build agent body from declarative YAML
# ----------------------------------------------------------------------

function Build-AgentBody {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Def,
        [Parameter(Mandatory=$true)][string]$DefFileDir
    )

    $tools = @()
    foreach ($t in @($Def.tools)) {
        switch ($t.type) {
            'openapi' {
                $spec = Resolve-Spec -SpecPath $t.specPath -RelativeTo $DefFileDir
                # Prompt agents require a security_scheme block. For MI + PBI
                # audiences the audience field lives INSIDE security_scheme.
                $securityScheme = @{ type = 'http'; scheme = 'bearer' }
                $auth = @{ type = $t.auth.type }
                switch ($t.auth.type) {
                    'managed_identity' {
                        if ($t.auth.audience) {
                            $securityScheme.audience = [string]$t.auth.audience
                        } elseif ($t.auth.audienceEnv) {
                            $securityScheme.audience = Resolve-EnvVar -Name $t.auth.audienceEnv -Required
                        } else {
                            throw "openapi/managed_identity tool needs audience or audienceEnv."
                        }
                    }
                    'connection' {
                        $connName = $t.auth.connectionName
                        if (-not $connName) {
                            throw "openapi/connection tool needs connectionName."
                        }
                        $conn = & azd ai connection show $connName --output json 2>$null | ConvertFrom-Json
                        if (-not $conn -or -not $conn.id) {
                            throw "Foundry connection '$connName' not found. Create it with 'azd ai connection create' first."
                        }
                        $auth.project_connection_id = $conn.id
                    }
                    'anonymous' { }
                    default {
                        throw "Unknown openapi auth.type: $($t.auth.type)"
                    }
                }
                $auth.security_scheme = $securityScheme
                # Prompt agents require a per-tool `name`. Prefer the explicit
                # YAML value; fall back to the first operationId in the spec.
                $toolName = $t.name
                if (-not $toolName) {
                    $firstOp = $null
                    foreach ($p in $spec.paths.Values) {
                        foreach ($m in @('get','post','put','patch','delete')) {
                            if ($p.$m -and $p.$m.operationId) { $firstOp = $p.$m.operationId; break }
                        }
                        if ($firstOp) { break }
                    }
                    if (-not $firstOp) { throw "OpenAPI tool needs a `name` field in the YAML (or an operationId in the spec)." }
                    $toolName = $firstOp
                }
                $tools += @{
                    type    = 'openapi'
                    openapi = @{ name = [string]$toolName; spec = $spec; auth = $auth }
                }
            }
            'a2a_preview' {
                $entry = @{
                    type        = 'a2a_preview'
                    name        = [string]$t.name
                    description = [string]$t.description
                }
                if ($t.connectionName) {
                    # RemoteA2A connection carries target URL + audience;
                    # Foundry resolves the agent card + auth from it.
                    $connId = "$ProjectEndpoint" -replace '/api/projects/', '/'
                    $connId = $connId -replace 'https://[^/]+', ''
                    # Build resource id via ARM: /subscriptions/<sub>/…/projects/<p>/connections/<name>
                    $sub = $AZURE_SUBSCRIPTION_ID
                    $rg  = $AZURE_RESOURCE_GROUP
                    $acct = $AZURE_AI_ACCOUNT_NAME
                    $proj = $AZURE_AI_PROJECT_NAME
                    if (-not ($sub -and $rg -and $acct -and $proj)) {
                        throw "a2a_preview with connectionName needs AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_AI_ACCOUNT_NAME, AZURE_AI_PROJECT_NAME env vars set."
                    }
                    $entry.project_connection_id = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$acct/projects/$proj/connections/$($t.connectionName)"
                } elseif ($t.baseUrl -or $t.baseUrlEnv) {
                    $baseUrl = if ($t.baseUrl) { [string]$t.baseUrl }
                               else { Resolve-EnvVar -Name $t.baseUrlEnv -Required }
                    $entry.base_url = $baseUrl
                } else {
                    throw 'a2a_preview tool needs connectionName, baseUrl, or baseUrlEnv.'
                }
                $tools += $entry
            }
            default {
                throw "Unsupported tool type in definition: $($t.type)"
            }
        }
    }

    @{
        name         = [string]$Def.name
        description  = [string]$Def.description
        definition   = @{
            kind         = [string]$Def.kind
            model        = [string]$Def.model
            temperature  = [double]$Def.temperature
            instructions = [string]$Def.instructions
            tools        = @($tools)
        }
    }
}

# ----------------------------------------------------------------------
# Agent PATCH via REST (agent_update equivalent)
# ----------------------------------------------------------------------

function Get-AiToken {
    # az CLI returns a token for the Azure AI Services resource. Works for
    # the projects data plane.
    $t = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>$null
    if (-not $t) {
        throw 'Failed to acquire ai.azure.com token. Run `az login` first.'
    }
    $t
}

function Deploy-Agent {
    param(
        [Parameter(Mandatory=$true)][string]$DefPath
    )
    $env:AZURE_DEV_USER_AGENT = $AZURE_DEV_USER_AGENT
    $def = (Get-Content -Raw -LiteralPath $DefPath) | ConvertFrom-Yaml
    $body = Build-AgentBody -Def $def -DefFileDir (Split-Path -Parent $DefPath)
    $bodyJson = ($body | ConvertTo-Json -Depth 40 -Compress)

    $agentName = $def.name
    $token = Get-AiToken

    # Check whether the agent already exists, and — critically — whether the
    # existing definition.kind matches what we're deploying. Foundry does NOT
    # allow kind changes via PATCH: a hosted→prompt conversion silently no-ops
    # and returns 200 with the old container definition untouched. We work
    # around that by DELETEing the agent when the kind differs, then POSTing
    # fresh. Same-kind updates could PATCH, but POST also works and keeps the
    # code path uniform.
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $bodyJson, [System.Text.UTF8Encoding]::new($false))

        $existing = $null
        $existingUrl = "$ProjectEndpoint/agents/$agentName" + "?api-version=v1"
        try {
            $existingJson = curl.exe --silent --fail `
                -H "Authorization: Bearer $token" `
                $existingUrl
            if ($existingJson) { $existing = $existingJson | ConvertFrom-Json }
        } catch { }

        if ($existing) {
            $existingKind = $existing.versions.latest.definition.kind
            $desiredKind  = [string]$def.kind
            if ($existingKind -and $existingKind -ne $desiredKind) {
                Write-Host "-> Existing '$agentName' is kind=$existingKind; target kind=$desiredKind. Deleting to convert."
                $delUrl = "$ProjectEndpoint/agents/$agentName" + "?api-version=v1"
                curl.exe --silent --show-error --fail-with-body `
                    -X DELETE `
                    -H "Authorization: Bearer $token" `
                    $delUrl | Out-Null
                # Give Foundry a moment before recreating under the same name.
                Start-Sleep -Seconds 5
                $existing = $null
            }
        }

        if ($existing) {
            $url = "$ProjectEndpoint/agents/$agentName" + "?api-version=v1"
            Write-Host "-> PATCH $url"
            $r = curl.exe --silent --show-error --fail-with-body `
                -X PATCH $url `
                -H "Authorization: Bearer $token" `
                -H 'Content-Type: application/json' `
                --data-binary "@$tmp"
        } else {
            $url = "$ProjectEndpoint/agents" + "?api-version=v1"
            Write-Host "-> POST $url  (name=$agentName)"
            $r = curl.exe --silent --show-error --fail-with-body `
                -X POST $url `
                -H "Authorization: Bearer $token" `
                -H 'Content-Type: application/json' `
                --data-binary "@$tmp"
        }

        Write-Host $r
        $parsed = $r | ConvertFrom-Json
        if ($parsed.agent_endpoint -and $parsed.agent_endpoint.protocols) {
            $responsesEndpoint = "$ProjectEndpoint/agents/$agentName/endpoint/protocols/openai/responses?api-version=v1"
            Write-Host ""
            Write-Host "   Responses endpoint: $responsesEndpoint"
            Write-Host "   -> azd env set $($agentName.ToUpper() -replace '-','_')_ENDPOINT $responsesEndpoint"
        }

        # Todo #3: register the prompt hash so every run can stamp it on
        # its demo_events rows. Deploy is the ONLY place this happens; the
        # agents themselves have no way to alter their own registered hash.
        $funcBase = $env:FUNCTION_APP_BASE_URL
        if (-not $funcBase) {
            $audience = $env:FUNCTION_APP_AUDIENCE
            if ($audience -and $audience -match '^api://(?<name>[^/]+)$') {
                $funcBase = "https://$($Matches.name).azurewebsites.net"
            }
        }
        if ($funcBase) {
            try {
                $funcToken = az account get-access-token --resource ($env:FUNCTION_APP_AUDIENCE) --query accessToken -o tsv 2>$null
                if ($funcToken) {
                    $hashBody = @{
                        agent        = $agentName
                        instructions = [string]$def.instructions
                        deployed_by  = (az account show --query user.name -o tsv 2>$null)
                    } | ConvertTo-Json -Depth 3 -Compress
                    $tmpHash = [System.IO.Path]::GetTempFileName()
                    [System.IO.File]::WriteAllText($tmpHash, $hashBody, [System.Text.UTF8Encoding]::new($false))
                    $hashUrl = "$funcBase/api/prompts/register"
                    Write-Host "-> POST $hashUrl"
                    $hashResp = curl.exe --silent --show-error `
                        -X POST $hashUrl `
                        -H "Authorization: Bearer $funcToken" `
                        -H 'Content-Type: application/json' `
                        --data-binary "@$tmpHash"
                    Write-Host "   $hashResp"
                    Remove-Item -Force -LiteralPath $tmpHash -ErrorAction SilentlyContinue
                } else {
                    Write-Warning "Prompt-hash registration skipped: no token for $($env:FUNCTION_APP_AUDIENCE)"
                }
            } catch {
                Write-Warning "Prompt-hash registration failed: $($_.Exception.Message)"
            }
        } else {
            Write-Warning "FUNCTION_APP_BASE_URL/FUNCTION_APP_AUDIENCE not set — skipping prompt-hash registration."
        }
    }
    finally {
        Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

if ($Only -in @('dq','both')) {
    Deploy-Agent -DefPath (Join-Path $definitionsDir 'dq-agent.yaml')
}
if ($Only -in @('triage','both')) {
    # DQ_AGENT_ENDPOINT is only required when triage's a2a tool is defined
    # with baseUrl/baseUrlEnv. Connection-based a2a tools resolve the URL
    # via the RemoteA2A project connection, so the env var isn't needed.
    $triageDef = (Get-Content -Raw (Join-Path $definitionsDir 'triage-agent.yaml')) | ConvertFrom-Yaml
    $needsBaseUrl = $false
    foreach ($t in @($triageDef.tools)) {
        if ($t.type -eq 'a2a_preview' -and -not $t.connectionName) { $needsBaseUrl = $true }
    }
    if ($needsBaseUrl) {
        $dqEnv = Resolve-EnvVar -Name 'DQ_AGENT_ENDPOINT'
        if (-not $dqEnv) {
            Write-Warning 'DQ_AGENT_ENDPOINT is not set. Triage cannot bind the A2A tool without it.'
            Write-Warning 'Deploy DQ first, then run: azd env set DQ_AGENT_ENDPOINT <responses endpoint printed above>'
            if ($Only -eq 'triage') { throw 'Aborting Triage deploy.' } else { return }
        }
    }
    Deploy-Agent -DefPath (Join-Path $definitionsDir 'triage-agent.yaml')
}
