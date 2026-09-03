# FAQ — the five live-Q&A questions from PRD §2.1

These are the five questions Zach must be able to answer live. Draft
answers below; keep them short. Use the run sheet's pause points as
natural moments to slip these in.

## 1. Agent-to-agent config and what the handoff looks like in logs

Two Foundry **prompt agents** — `triage-agent` and `dq-agent` — each
defined declaratively in a YAML file under `agents/definitions/`.
Triage's YAML declares a `type: a2a_preview` tool whose `connectionName`
resolves to a **RemoteA2A project connection** in Foundry. That
connection encapsulates:

- the target agent's Responses endpoint URL,
- the target audience (Foundry mints an `AgenticIdentityToken` for the
  caller against this audience),
- the target agent's card (Foundry fetches it via the connection so
  Triage sees DQ's schema at run time).

In the run trace it looks like:

1. Triage's run shows a `tools.a2a_preview:dq-agent` invocation with
   the JSON message body Triage constructed.
2. A **separate** DQ run appears in the DQ agent's run list, linked
   from Triage's parent run. Both runs are visible side-by-side.
3. DQ's return value (the `dq_verdict` JSON) appears back on Triage's
   timeline as the tool result.

A single agent with a `check_duplicates` tool would NOT satisfy the
ask — there'd be no second run in DQ's list.

## 2. Observability — run traces and how a failed run surfaces

Two independent sources, joined by `run_id`.

- **Foundry run traces** — every tool call, its arguments, its return
  value, and any thrown exception. Foundry's UI surfaces failed
  runs at the top of the list with a red badge. Trace deep-links are
  written into `demo_events.trace_url` so the cockpit can jump you
  straight to the failed step.
- **`dbo.demo_events`** — every WORKFLOW stage the agents call
  `log_event` for (with `agent`, `prompt_hash`, `stage`, `status`,
  `detail`). Cockpit's Agent Flow tile is a live read of this.

Failure paths:
- Tool exception → Foundry marks the run failed. Triage's `catch`
  logs `status=failed`, then `close_incident` downgrades the outcome
  to `needs_human`.
- Agent gets a `verdict:error` back from DQ → Triage still runs
  `close_incident` and Teams reports the escalation.
- Poller can't reach mailbox → `poll_inbox` heartbeat still writes
  `poll_tick`, but with `status=failed`. Cockpit shows the countdown
  going red.

## 3. Email trigger mechanics and latency to first agent action

**Polling, not event-driven.** A timer-triggered Function (`poll_inbox`
in `function_app.py`) runs every 30 seconds:

1. Acquires a Graph token via managed identity (Mail.Read app
   permission on the monitored mailbox).
2. Lists unread messages, filters by `DEMO_SUBJECT_PATTERN` (fail-
   closed on invalid pattern — see invariant #11).
3. Extracts the JSON payload from the body (tolerating curly quotes,
   NBSPs, and other Outlook munging).
4. POSTs the payload to Triage's Responses endpoint using a
   `ai.azure.com` token minted from the Function App's MI.
5. On success, marks the mail read.

Latency: worst-case 30s to first agent action. We chose polling over
Graph change notifications because:

- Change notifications require a public HTTPS endpoint with a
  validation handshake. The Function App is behind Easy Auth v2
  restricted to Foundry's MI, which fails that handshake.
- 30s is well within the demo's "feels responsive" window and matches
  the cockpit's heartbeat cadence, giving a natural rhythm.

## 4. Auth model for Power BI REST and Teams

**Power BI REST** — Foundry project managed identity added to the
target workspace as **Contributor**. Triage's `refresh_pbi_dataset`
tool is `type: openapi` with `auth: managed_identity` and
`audience: https://analysis.windows.net/powerbi/api`. Foundry mints a
PBI token from the project MI and calls the REST endpoint with it. No
service principal, no shared secret.

**Microsoft Teams** — a Workflows-template webhook (Power Automate
"Send webhook alerts to a channel"). Triage's `post_teams_message`
tool is `type: openapi` with `auth: anonymous` — the signed URL
itself is the auth. We tried the Graph `ChannelMessage.Send.Group` app
permission first; the cross-tenant SP path returned "Group ID does
not exist" reliably and consumed most of a day, so the Workflows
webhook won on pragmatism. Cost: the sender in Teams shows as a
Power Automate workflow, not the agent's own identity.

## 5. Effort for this demo vs. a production equivalent

Demo: ~3 weeks of one engineer, including the safety-rails scope
that was added after the initial ask. About 40% of the effort went
into the guardrails, not the happy path.

Production: rough estimates for what would change.

| What                        | Demo                                     | Production                                                                 |
|-----------------------------|------------------------------------------|----------------------------------------------------------------------------|
| Tenant                      | Microsoft demo tenant                    | SM Energy tenant with a proper subscription boundary                       |
| Networking                  | Function App VNet-integrated + Easy Auth | Add Private Endpoints on SQL, PBI, Function App; egress lockdown           |
| Identity                    | Foundry project MI + Function MI         | Same, plus per-agent MIs and per-workspace scoping                         |
| Data plane                  | Azure SQL demo DB                        | Whichever source of truth the BI team owns; add reader roles per agent     |
| Approvals delivery          | Teams Adaptive Card + Function endpoint  | Same, plus a formal on-call rotation and SLA on approval response time     |
| Playbook catalogue          | 7 entries, public Microsoft Learn        | 30-50 entries with internal TSGs feeding public phrasing (sourcing rule)   |
| Testing                     | scenarios/*.yaml + run-scenario.ps1      | Same shape + a CI job that reruns the pack against a mock provider nightly |
| Observability               | Foundry run traces + demo_events         | Add Application Insights alerts on `terminal_outcome=needs_human` spikes   |
| Rollout                     | Manual `deploy-agents.ps1`               | GitHub Actions with prompt-hash diffing and staged deploys per tenant      |

Order of magnitude: **~4x** the demo effort to get to a production
pilot in one BU. **~10x** to get to the "put it on-call" bar. The
safety story ports 1:1; the tenant integration is the long tail.
