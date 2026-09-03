# Demo Cockpit

Single-page live dashboard for the SM Energy BI Triage demo. Replaces the
"5 windows on stage" experience: Inbox, Agent Flow, SQL state, and Teams
posts are all visible on one screen and auto-refresh every 2 seconds.

## Architecture

Thin FastAPI proxy over `func-sme`. All data reads (SQL + Graph) happen
inside the Function App using its managed identity; the cockpit just
forwards requests with an `api://func-sme` bearer token.

```
Browser (localhost:8000)
  | GET /api/{inbox,events,data,teams,config}
  v
FastAPI cockpit (this app)
  | POST /api/admin/{inbox,events,rows+flags,teams,cleanup}
  | Authorization: Bearer <api://func-sme token via az login>
  v
func-sme (Easy Auth v2 gate: presenter OID + Foundry MI in allowedPrincipals)
  |-- Azure SQL (VNet, MI auth)  <- demo_events, source_orders, dq_flags
  \-- Microsoft Graph (MI, app perms)  <- inbox, channel messages
```

## Prerequisites

1. Python 3.11+
2. `az login` as a user in the demo tenant — the cockpit reuses your CLI token.
3. **The presenter's Entra object id must be in `func-sme`'s Easy Auth
   `allowedPrincipals.identities`.** By default only the Foundry project MI
   is allowed. To add yourself:

   ```powershell
   $oid = az ad signed-in-user show --query id -o tsv
   az webapp auth update -g $env:AZURE_RESOURCE_GROUP -n $env:FUNCTION_APP_NAME --set `
     "properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities=['$env:FOUNDRY_PROJECT_MI_OBJECT_ID','$oid']"
   ```
4. `dbo.demo_events` table exists — created automatically by `func-sme`'s
   `/api/admin/seed` on first invocation.

## First-time setup

```powershell
cd cockpit
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
# Adjust FUNCTION_URL / FUNCTION_AUDIENCE if they differ from defaults.
```

## Run

```powershell
cd cockpit
.\.venv\Scripts\Activate.ps1
uvicorn app:app --port 8000
```

Open http://localhost:8000 full-screen.

Fire scenarios from another terminal:

```powershell
.\demo-fire.ps1 clean        # -> PBI Refresh path
.\demo-fire.ps1 duplicates   # -> Flag Written path (dq_flags row + Teams card)
.\demo-fire.ps1 fail         # -> Escalate path
```

The cockpit picks up the run state within one polling tick (~2s).

## Endpoints

| Path                | Purpose                                                  |
|---------------------|----------------------------------------------------------|
| `GET  /`            | serves `static/index.html`                               |
| `GET  /api/config`  | poll interval + display config for JS bootstrap          |
| `GET  /api/inbox`   | last 5 `[BI-DEMO]` messages (via `func-sme`)             |
| `GET  /api/events`  | latest 3 runs from `dbo.demo_events`                     |
| `GET  /api/data`    | top 20 `source_orders` + all `dq_flags`                  |
| `POST /api/reset`   | truncate `dq_flags` + `demo_events` (soft, keeps orders) |

Under the hood these forward to `func-sme`'s `/api/demo/{inbox,events,rows+flags,cleanup}`
routes. The prefix is `demo/` (not `admin/`) because `/api/admin/*` is reserved
by the Azure Functions runtime for its own admin API.

Teams outputs are shown directly in the Teams client (not embedded in the
cockpit) — the Adaptive Card lands in the wired channel via the Workflows
webhook.

## Troubleshooting

- **401 from `/api/*`** - your Entra OID isn't in `func-sme`'s
  `allowedPrincipals`. See prerequisite 3.
- **`Cannot acquire api://func-sme token`** - `az login` hasn't happened, or
  `FUNCTION_AUDIENCE` in `.env` doesn't match the deployed Function App's
  App Registration URI.
- **Empty Agent Flow tile after firing a scenario** - Triage's `log_event`
  calls failed. Tail Function App logs:
  `az functionapp logs tail --resource-group $env:AZURE_RESOURCE_GROUP --name $env:FUNCTION_APP_NAME`
- **Adaptive Card renders as plain text in the Teams tile** - `func-sme`
  fetched the message but couldn't parse the attachment. Check
  `/api/teams`'s response: `messages[0].adaptive_card` should be a JSON object.
