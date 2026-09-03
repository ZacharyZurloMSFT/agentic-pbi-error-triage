# Foundry agents — SME BI Triage demo

Two **prompt agents** for the SM Energy BI Triage demo (see `../PRD.md`).
Declarative definitions live in `definitions/`; all runtime SQL + Graph work
happens in the sibling Function App (`../function/`). No containers, no ACR.

## Layout

```
agents/
  definitions/
    dq-agent.yaml         # DQ Agent (prompt) — calls /dq/check via OpenAPI tool
    triage-agent.yaml     # Triage Agent (prompt) — A2A→DQ, /dq/flag, PBI REST, Teams webhook
    openapi/
      pbi-refresh.yaml    # minimal Power BI REST slice: Datasets - Refresh Dataset
      teams-webhook.yaml  # Power Automate Workflows webhook — posts Adaptive Card to Teams channel
  deploy-agents.ps1       # PATCHes both agents into the Foundry project
  README.md               # (this file)
  AGENTS.md               # coding-agent instructions (below)
```

## Deploy

```powershell
# 0. Preconditions
#    - foundry.bicep deployed (proj-sme + gpt-4o + MI)
#    - `../bootstrap-func-app-reg.ps1` run once — creates the Entra app
#      registration `func-sme` (api://func-sme, v2 tokens) that Easy Auth
#      validates tokens against. Function App has no callers until this
#      exists in the tenant.
#    - function.bicep deployed (func-sme with Easy Auth allowing proj-sme MI)
#    - grant-function-mi.sql run (Function MI has SQL access)
#    - Teams-tenant SP exists with ChannelMessage.Send app permission,
#      registered in Foundry as project connection 'teams-graph-sp':
#        azd ai connection create --type api_key --name teams-graph-sp `
#             --api-key <secret> --endpoint https://graph.microsoft.com
#    - Foundry project MI added to the target Power BI workspace as Contributor

# 1. Env
$env:AZURE_AI_PROJECT_ENDPOINT = 'https://ai-foundry-sme.services.ai.azure.com/api/projects/proj-sme'
$env:FUNCTION_APP_AUDIENCE     = 'api://func-sme'    # matches function.bicep output
$env:TEAMS_TEAM_ID             = '<team-guid>'
$env:TEAMS_CHANNEL_ID          = '<channel-id>'

# 2. Deploy DQ first (Triage binds it via A2A)
./deploy-agents.ps1 -Only dq
# The script prints the DQ Responses endpoint. Save it:
$env:DQ_AGENT_ENDPOINT         = '<responses endpoint printed above>'
azd env set DQ_AGENT_ENDPOINT $env:DQ_AGENT_ENDPOINT

# 3. Deploy Triage
./deploy-agents.ps1 -Only triage
```

Re-running the script is idempotent — it PATCHes the existing agent to the
new definition. Edit instructions, tools, or the OpenAPI specs in-place and
re-run whichever agent needs updating.

## Invoke

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'

# Scenario 2 (duplicates → flag path)
$s2 = '{"report":"Daily Orders","workspace_id":"...","dataset_id":"...","error":"Refresh failed","source_table":"dbo.source_orders","key_column":"order_id"}'
$s2 | Set-Content -NoNewline $env:TEMP\s2.json
azd ai agent invoke triage-agent --input-file $env:TEMP\s2.json --new-session

# Scenario 1 (clean → refresh path)
$s1 = '{"report":"Daily Orders","workspace_id":"...","dataset_id":"...","error":"Refresh failed","source_table":"dbo.source_orders","key_column":"customer_id"}'
$s1 | Set-Content -NoNewline $env:TEMP\s1.json
azd ai agent invoke triage-agent --input-file $env:TEMP\s1.json --new-session
```

## Auth model in one picture

| Caller                 | Callee                    | Mechanism                                                             |
|------------------------|---------------------------|-----------------------------------------------------------------------|
| Foundry project MI     | Function App              | Entra token, aud=`api://func-sme`. Easy Auth v2 allowedPrincipals gate |
| Function App MI        | Azure SQL                 | AAD access token (`database.windows.net/.default`) via python-tds     |
| Function App MI        | Microsoft Graph (mail)    | Application permission `Mail.ReadWrite` (poller only)                 |
| Function App MI        | Foundry Responses (Triage)| `ai.azure.com/.default` (poller only)                                 |
| Foundry project MI     | Power BI REST             | Managed-identity OpenAPI tool, audience `analysis.windows.net/powerbi/api` |
| Foundry project MI     | Microsoft Graph (Teams)   | OpenAPI tool w/ project connection `teams-graph-sp` (cross-tenant SP) |
| Foundry Triage agent   | Foundry DQ agent          | `a2a_preview` tool, anonymous auth (same project)                     |
| Foundry Function MI    | (nothing)                 | Storage RBAC handled in function.bicep                                |

## Share-out deliverables (PRD §9)

Everything in this directory is portable and safe to send to sponsors:

- `definitions/dq-agent.yaml`, `definitions/triage-agent.yaml` — full agent bodies
- `definitions/openapi/*.yaml` — external tool specs (PBI, Graph)
- `../function/openapi-check.yaml`, `../function/openapi-flag.yaml` — DQ Function tool specs
- `../function/function_app.py` — DQ Function implementation
- `deploy-agents.ps1` — the deploy script itself

No secrets are stored in these files. The Teams SP secret lives in the Foundry
project connection; the Function's Storage/App Insights credentials come from
MI. Redaction pass before external share: none required.

## References

- [Prompt agents (concept)](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/prompt-agents)
- [OpenAPI tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/openapi)
- [Agent-to-Agent tool (preview)](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/agent-to-agent)
