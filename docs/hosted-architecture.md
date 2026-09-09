# Hosted architecture — how the pieces fit at runtime

Ported and expanded from the original `ARCHITECTURE.md` (retained as a
short pointer to this file). The Mermaid diagram lives in
`ARCHITECTURE.md`; this document is the prose.

## Identity graph

```
                     Foundry project MI
                    ┌───────────────────┐
                    │ audiences:        │
                    │  * api://func-triage │───► Function App (Easy Auth v2, allowedPrincipals=this MI)
                    │  * ai.azure.com   │───► DQ agent Responses endpoint (a2a_preview)
                    │  * .../powerbi/api│───► Power BI REST (Contributor on workspace)
                    └───────────────────┘

                    Function App MI (system-assigned)
                    ┌───────────────────┐
                    │ audiences:        │
                    │  * database.wind..│───► Azure SQL (db_datareader + db_datawriter)
                    │  * graph.micros..│───► Graph mailbox (Mail.Read.All on demo mailbox)
                    │  * ai.azure.com  │───► Triage agent Responses (invoke on mailbox tick)
                    └───────────────────┘
```

Prompt agents themselves hold no permissions (invariant #16). Every
side effect the agents cause flows through a tool whose auth is either
the Foundry project MI or an anonymous signed webhook URL. What an
agent CAN do is auditable via the tools it holds — never via role
inheritance we forgot about.

## Graph app roles on the Function App MI

Graph app-role assignments are out-of-band (Microsoft.Graph resources,
not ARM) and are managed by `grant-func-graph-roles.ps1` in the repo
root. That script is idempotent, safe to re-run, and grants:

- `Mail.Read` — poller lists unread mail
- `Mail.ReadWrite` — poller marks each mail read after processing
  (critical: without this, every 30 s tick re-processes the same
  unread mail and the incident occurrence counter runs away)
- `Mail.Send` — outbound notification paths

Reading Teams channel messages for the `/api/demo/teams` tile requires
`ChannelMessage.Read.All` under Microsoft's Resource-Specific Consent
(RSC) model — that permission is granted via a Teams App manifest, not
by this script. See `docs/faq.md#4` for the full Teams auth story.

## Function App layout

- **Language:** Python 3.11 on Flex Consumption.
- **HTTP endpoints:** all POST, all behind Easy Auth v2 restricted to
  the Foundry project MI. Grouped by concern:
  - **DQ:** `/api/dq/check`, `/api/dq/flag`
  - **Event log:** `/api/log_event`
  - **Incident lifecycle:** `/api/incidents/check_or_open`,
    `/api/incidents/close`
  - **Policy:** `/api/policy/charge`, `/api/policy/propose_action`
  - **Approvals:** `/api/approvals/request`, `/api/approvals/decide`,
    `/api/approvals/status`
  - **Retrieval:** `/api/playbooks/lookup`
  - **Prompt versioning:** `/api/prompts/register`,
    `/api/prompts/current`
  - **Cockpit tiles:** `/api/demo/*`
- **Timer trigger:** `poll_inbox` every 30 seconds. Fail-closed on
  invalid subject pattern. Every rejection lands in `dbo.inbox_audit`.
- **Modules:** `redaction.py` (11 secret patterns, applied at the SQL
  boundary), `playbooks.py` (7-entry failure-mode catalogue, public
  Microsoft Learn sources), `sql.py` (pytds + MI access-token auth).

## SQL schema (excerpt)

| Table              | Purpose                                                             | Populated by                                |
|--------------------|---------------------------------------------------------------------|---------------------------------------------|
| `source_orders`    | Mock BI source with seeded duplicates                               | `seed.sql`                                  |
| `dq_flags`         | One row per DQ Agent flag                                           | DQ agent's `write_dq_flag` tool             |
| `demo_events`      | Every workflow stage; includes `agent` + `prompt_hash`              | Both agents via `log_event`                 |
| `incidents`        | Signature-dedup rows; carries `terminal_outcome` after close        | `check_or_open_incident` + `close_incident` |
| `policy_ledger`    | One row per remediation / off-allowlist check                       | `policy_charge`, `policy_propose_action`    |
| `inbox_audit`      | One row per REJECTED mail (invalid pattern / non-matching subject)  | `poll_inbox` timer                          |
| `prompt_versions`  | SHA-256 prefix of each deployed prompt                              | `deploy-agents.ps1` via `register_prompt_hash` |
| `approvals`        | Human-in-the-loop gates (fail-closed)                               | `request_approval` + `decide` / `status`    |

Schema evolution: `migration_001.sql` is additive and idempotent. New
schema arrives via `/api/demo/migrate` on the deployed Function App;
`reset.sql` bootstraps everything on a fresh DB.

## Data flow — happy path (Scenario 1)

1. **Trigger.** `send-demo-email.ps1` posts a JSON-in-body email to
   the monitored mailbox via Graph as the presenter's user.
2. **Poller.** Within 30s, `poll_inbox` picks it up, extracts the
   JSON payload, POSTs it to Triage's Responses endpoint. Rejected
   mails go to `inbox_audit`.
3. **Triage run.** Fetches prompt_hash → opens incident → looks up
   playbooks → delegates to DQ → gets `verdict=clean` → charges
   policy_charge → refreshes PBI → calls `close_incident` → posts
   Teams card.
4. **DQ run.** Under the covers as a linked child run: `check_duplicates`
   → returns clean verdict. Zero side effects.
5. **Close.** `close_incident` reconciles `claimed_outcome=resolved`
   against `demo_events`: finds `refresh_triggered=ok`, returns
   `final_outcome=resolved`, sets `dbo.incidents.terminal_outcome`.
6. **Teams.** Adaptive Card posted via Workflows webhook.

## Data flow — human approval (Scenario 5)

Diverges at step 3, after DQ returns `duplicates_found` AND the
payload has `request_bigger_fix:true`:

- `request_approval` issues an HMAC-signed fingerprint + Adaptive
  Card.
- Triage posts the intermediate approval card to Teams.
- Triage polls `check_approval` up to 12 times, 5s apart.
- Human clicks Approve (or the runner does it programmatically).
  `/api/approvals/decide` records the decision.
- Triage sees `granted`, charges `policy_charge` for
  `apply_bigger_fix`, dispatches ONCE, and posts the final Teams
  card.

If the human clicks Deny (Scenario 6), the same path ends with
`approval_denied` and no dispatch. If the poll loop times out without
a decision, Triage treats it as denied — silence never reads as
consent.

## Cockpit

`cockpit/app.py` is a FastAPI proxy over `/api/demo/*`. It uses the
presenter's `az login` token to talk to the Function App (audience
`api://func-triage`). The cockpit holds no secrets and can be pointed at
any deployment by changing `FUNCTION_APP_BASE_URL`. Tiles:

- **Agent Flow** — live view of `demo_events` grouped by run.
- **Incidents** — `dbo.incidents` with signature and occurrence
  counts.
- **Policy** — `dbo.policy_ledger` allowed / denied rows.
- **Approvals** — `dbo.approvals` with expiry countdowns.
- **Inbox** — Graph `messages` for the monitored mailbox.
- **Inbox Audit** — `dbo.inbox_audit` rejections (should be empty
  during a clean demo).
- **Teams** — Graph `channels/{id}/messages` for the demo channel.
- **Prompt Versions** — `dbo.prompt_versions` for provenance.
