# Architecture — SM Energy BI Triage Demo

> Full walkthrough (identity graph, SQL schema, end-to-end data flow,
> approval path) has moved to [`docs/hosted-architecture.md`](./docs/hosted-architecture.md).

End-to-end architecture for the Foundry agent-to-agent BI triage demo: email
trigger → Function App controller → Foundry agents (Triage + DQ) → Azure SQL
+ Power BI + Teams, with the Cockpit UI, Entra identity, and observability.

```mermaid
flowchart LR
    MBX[("📧 Monitored mailbox<br/>M365")]

    subgraph Foundry["🧠 Azure AI Foundry"]
        TRI(["🟠 Triage Agent<br/>orchestrator"])
        DQ(["🟢 DQ Agent<br/>A2A callable"])
        TRI -->|a2a_preview| DQ
        DQ  -->|verdict| TRI
    end

    FUNC["⚡ Function App<br/>poller · DQ · safety-rail controller"]

    subgraph Data["🗄 Azure SQL"]
        SRC[("source_orders")]
        FLAG[("dq_flags")]
        SAFE[("incidents<br/>policy_ledger")]
    end

    subgraph PBI["📊 Power BI"]
        SEM[("Semantic model")]
        RPT["Report"]
    end

    TEAMS["💬 Teams<br/>Ops channel"]

    MBX -->|Graph poll 30s| FUNC
    FUNC -->|Responses API| TRI
    TRI -->|DQ + safety-rail calls| FUNC
    DQ  -->|check_duplicates| FUNC
    FUNC --> SRC
    FUNC --> FLAG
    FUNC --> SAFE
    SRC -->|feeds| SEM --> RPT
    TRI -->|PBI REST refresh| SEM
    TRI -->|ChannelMessage.Send| TEAMS

    OBS["🔎 App Insights<br/>Foundry traces + Function logs"]
    Foundry -.-> OBS
    FUNC -.-> OBS
    TEAMS -.->|deep link| OBS

    classDef triage fill:#fff4e0,stroke:#c47f17,color:#000
    classDef agent  fill:#e6f4ea,stroke:#137333,color:#000
    class TRI triage
    class DQ agent
```

## Key flows

- **Trigger:** `demo-fire.ps1` → mailbox → Function App 30s poller → Triage
  Agent (Responses API).
- **Agent-to-agent:** Triage calls DQ via `a2a_preview`; both runs appear
  linked in Foundry traces.
- **Controller safety rails:** every Triage decision routes through
  `/incidents/check_or_open`, `/policy/charge`, and `/policy/propose_action`
  — each backed by a durable SQL row (`dbo.incidents`, `dbo.policy_ledger`).
- **Actions:** Power BI REST refresh (MI-auth OpenAPI tool) or `dq/flag`
  write; Teams post via cross-tenant SP.
- **Cockpit:** read-only FastAPI proxy over `/api/demo/*` using the same
  `api://func-sme` audience, acquired via the presenter's `az login`.
- **Identity:** Foundry MI → Function App + PBI; Function MI → SQL + Graph
  mail; Teams SP for cross-tenant Graph.
