# foundry-sme — Multi-agent BI Triage on Azure AI Foundry

A reference implementation of a **safety-railed, multi-agent BI triage loop**
built on Azure AI Foundry.

Two Foundry **prompt agents** — Triage and DQ — cooperate over `a2a_preview`
to diagnose Power BI refresh failures. Every guardrail (signature dedup,
remediation budget, action allowlist, human-in-the-loop approvals, outcome
reconciliation) lives in a Python **Function App controller**, not in the
prompts. The demo ships six scenarios covering the happy path, data-quality
flagging, duplicate suppression, budget refusal, off-allowlist rejection, and
approval-gated bigger fixes.

For narrative context, start with:

- [`PRD.md`](./PRD.md) — product requirements + scenario definitions
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — end-to-end diagram
- [`docs/run-sheet.md`](./docs/run-sheet.md) — presenter-facing run-book
- [`walkthrough/WALKTHROUGH.html`](./walkthrough/WALKTHROUGH.html) — technical walkthrough with screenshots
- [`walkthrough/PERSONAS.html`](./walkthrough/PERSONAS.html) — user-side story

---

## What deploys

| Component | Kind | Notes |
|-----------|------|-------|
| Azure SQL logical server + DB | `foundry.bicep` (via `main.bicep`) | Entra-only auth, private endpoint |
| VNet + private DNS zones | `network.bicep` | SQL PE, Function integration subnet, Foundry agent subnet |
| AI Foundry account + project + `gpt-4o` deployment | `foundry.bicep` | MI-authenticated, VNet-injected agent runtime |
| Function App (Flex Consumption, Python 3.11) | `function.bicep` | VNet-integrated, Easy Auth v2, MI on SQL + Graph |
| Two prompt agents (Triage, DQ) | `agents/deploy-agents.ps1` | Declarative YAML in `agents/definitions/` |
| Demo Cockpit (FastAPI) | `cockpit/` | Local dashboard — proxies func-triage via presenter's `az login` |

---

## Prerequisites

- **Azure**: an empty resource group in a subscription you own, plus
  permissions to create Cognitive Services accounts, Function Apps, SQL,
  networking, and role assignments in it.
- **Entra ID (tenant admin one-off)**:
  - `Application.ReadWrite.All` — used by `bootstrap-func-app-reg.ps1` to
    create the App Registration that gates the Function App.
  - `AppRoleAssignment.ReadWrite.All` — used by `grant-func-graph-roles.ps1`
    to grant Graph `Mail.Read` / `Mail.ReadWrite` / `Mail.Send` to the
    Function App's system-assigned managed identity.
- **Microsoft 365**: a shared mailbox in the same tenant to act as the demo
  inbox (the Function App poller reads unread `[BI-DEMO]` mail every 30 s).
- **Power BI**: a workspace with a semantic model you want the Triage agent
  to refresh. The Foundry project MI must be added to the workspace as
  Contributor.
- **Microsoft Teams**: a channel wired to a Power Automate Workflows webhook
  (template: *Post to a channel when a webhook request is received*).
- **Local tools**: `az` CLI, Azure Functions Core Tools v4, PowerShell 7+,
  Python 3.11+, Bicep, `curl`.

---

## Deploy — end-to-end

Every script and bicepparam file reads from a single `.env` at the repo
root. There are **no** hard-coded tenant / subscription / workspace / mailbox
values anywhere in source — the deploy is fully data-driven.

### 1 · Configure

```powershell
git clone https://github.com/<your-org>/foundry-sme.git
cd foundry-sme
Copy-Item .env.example .env
# Edit .env — every variable is required. See comments in .env.example.
```

Load the values into your shell session (every subsequent script depends on
this being in scope):

```powershell
. .\scripts\load-env.ps1
```

### 2 · Sign in

```powershell
az login --tenant $env:AZURE_TENANT_ID
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
```

### 3 · Bootstrap the Entra App Registration (one-off per tenant)

```powershell
.\bootstrap-func-app-reg.ps1
```

### 4 · Provision Azure resources

```powershell
az group create -n $env:AZURE_RESOURCE_GROUP -l $env:AZURE_LOCATION

# 4a. Network (VNet, subnets, private DNS, SQL PE)
az deployment group create -g $env:AZURE_RESOURCE_GROUP -f network.bicep -p network.bicepparam

# 4b. SQL server + database
az deployment group create -g $env:AZURE_RESOURCE_GROUP -f foundry.bicep  -p foundry.bicepparam
# (this template also creates the AI Foundry account, project, and model deployment)

# 4c. Function App
az deployment group create -g $env:AZURE_RESOURCE_GROUP -f function.bicep -p function.bicepparam
```

Capture the Function App and Foundry project MI object ids from the
deployment outputs and write them back into `.env` (used by later steps):

```powershell
azd env set FOUNDRY_PROJECT_MI_OBJECT_ID <foundryProjectPrincipalId from foundry.bicep outputs>
```

### 5 · Grant Graph app roles to the Function App MI

```powershell
.\grant-func-graph-roles.ps1
```

### 6 · Grant SQL rights to the Function App MI

Follow the instructions in [`grant-function-mi.sql`](./grant-function-mi.sql)
— the byte-swap the AAD-token-to-SID conversion needs is described in the
header. Run the file as the SQL AAD admin.

### 7 · Deploy the Function App code

```powershell
Push-Location function
func azure functionapp publish $env:FUNCTION_APP_NAME --python
Pop-Location
```

### 8 · Deploy the two prompt agents

```powershell
Push-Location agents
.\deploy-agents.ps1
Pop-Location
```

The script inlines the OpenAPI specs, templates the Teams webhook URL from
`$env:TEAMS_WEBHOOK_URL`, and stamps a SHA-256 prompt hash into
`dbo.prompt_versions` so every subsequent run is traceable to an exact
prompt version.

### 9 · Run a scenario

```powershell
# Full end-to-end (email → poller → Triage → DQ → PBI / Teams)
.\send-demo-email.ps1 clean

# Or direct-to-Triage (skips the mailbox)
.\demo-fire.ps1 clean
```

Watch it live in the Demo Cockpit:

```powershell
Push-Location cockpit
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app:app --port 8000
# Then open http://localhost:8000
Pop-Location
```

Run every scenario head-to-head:

```powershell
.\scripts\run-scenario.ps1 -All
```

---

## What lives where

```
foundry-sme/
├── README.md                     ← you are here
├── PRD.md, ARCHITECTURE.md       ← narrative / design
├── .env.example                  ← every environment variable, commented
├── main.bicep + main.bicepparam  ← SQL + Entra admin
├── network.bicep(param)          ← VNet, subnets, private DNS, SQL PE
├── foundry.bicep(param)          ← Foundry account + project + gpt-4o
├── function.bicep(param)         ← Flex Consumption Function App + Easy Auth v2
├── bootstrap-func-app-reg.ps1    ← Entra App Registration (one-off)
├── grant-func-graph-roles.ps1    ← Graph app-roles for Function App MI
├── grant-function-mi.sql         ← SQL user + db_datareader/writer/ddladmin
├── function/                     ← Python Function App code
│   ├── function_app.py           ← controller: DQ, safety rails, poller
│   ├── redaction.py, sql.py, playbooks.py
│   └── openapi-*.yaml            ← per-endpoint OpenAPI specs (agent-facing)
├── agents/
│   ├── definitions/              ← declarative agent YAML (portable)
│   │   ├── dq-agent.yaml, triage-agent.yaml
│   │   └── openapi/              ← PBI refresh + Teams webhook specs
│   └── deploy-agents.ps1
├── cockpit/                      ← FastAPI dashboard for live runs
├── scenarios/                    ← YAML expect-blocks (integration tests)
├── scripts/                      ← run-scenario / use-pbi-dataset / load-env
├── docs/                         ← run-sheet, faq, hosted-architecture, model-selection
└── walkthrough/                  ← HTML tour of a live run with screenshots
```

---

## Safety-rail invariants

The Function App enforces every guardrail on server-side SQL rows — never on
prompt wording. See [`AGENTS.md`](./AGENTS.md) §Invariants for the full list.
A summary:

1. Signature-based incident dedup (`dbo.incidents`)
2. Remediation budget (one action per incident, `dbo.policy_ledger`)
3. Action allowlist (off-allowlist requests refused before dispatch)
4. Approval gate — explicit, fingerprint-matched, unexpired, unused
5. Outcome reconciliation (controller decides `final_outcome`; agent's claim is discarded on mismatch)
6. Redaction at the store boundary (`function/redaction.py`)
7. Fail-closed inbox filter (`dbo.inbox_audit`)
8. Prompt hash stamped on every event row (`dbo.prompt_versions`)

---

## Contributing / issues

Bug reports and PRs welcome. Please open an issue before starting anything
non-trivial so we can align on scope and safety-rail impact.

## License

[MIT](./LICENSE)
