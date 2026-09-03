# AGENTS.md — root

Bootstrap contract for any coding agent (Copilot CLI, Claude Code, etc.)
working in this repo.

## What this is

A live demo of a multi-agent BI triage loop on Azure AI Foundry, running
against a real Microsoft demo tenant (not offline). Two Foundry **prompt
agents** — Triage and DQ — talk to each other via `a2a_preview`. All
guardrails and side-effecting work live in a Python **Function App**
controller. The demo is a customer-facing artifact for SM Energy;
optimise for legibility and for being able to explain any line of it
out loud.

## Commands

```powershell
# Deploy the Function App (Python)
cd function
func azure functionapp publish func-sme --python

# One-time per environment: grant Graph app roles to the Function App MI
# (Mail.Read + Mail.ReadWrite + Mail.Send). Idempotent.
cd ..
.\grant-func-graph-roles.ps1

# Deploy the two prompt agents
cd agents
.\deploy-agents.ps1

# Kick off a demo email → mailbox poller → agents
.\demo-fire.ps1        # sends a Scenario 2 payload
.\send-demo-email.ps1 -Scenario 1

# Run any scenario end-to-end and assert against SQL
.\scripts\run-scenario.ps1 -Name scenario1-transient
.\scripts\run-scenario.ps1 -All

# Reset demo state
.\demo-tools.ps1 -Reset
```

## Invariants — do not break these

Each rule is tied to a real design choice, a production failure the
reference repo ported over, or something this build has already paid for
once. If you find yourself weakening one, change the scenario instead.

1.  **Every guardrail lives in the Function App controller, not the
    prompt.** Signature dedup, remediation budget, allowlist, approval
    gate, playbook retrieval, outcome validation — all enforced by
    `function/function_app.py` against `dbo.*` rows. A limit that
    exists only as prompt wording is not a limit.

2.  **Every new tool goes through `policy_propose_action` OR is added
    to `_REMEDIATION_ACTIONS`.** Anything off-allowlist is refused
    before dispatch. That is the property the whole demo rests on.

3.  **An approval is only a "yes" if it is explicit, fingerprint-
    matched, unexpired, and unused.** Timeout, error, malformed reply,
    missing gate — all "no". Silence never reads as consent. See
    `dbo.approvals` and `/api/approvals/status`.

4.  **A denial must not consume the remediation budget.** Otherwise a
    single "no" silently disarms the agent for the rest of the incident.
    Enforced by `_REMEDIATION_ACTIONS` gating in `policy_charge`.

5.  **Deterministic evidence outranks model prose.** If a model claim
    and a SQL scan disagree, the scan wins, the prose is discarded, and
    the disagreement is logged as `stage="model_contradicted"`. Both
    agent YAMLs restate this.

6.  **Redaction stays inside the store boundary.** Every user-shaped
    text field going into SQL — `demo_events.detail`,
    `incidents.error_class`, `incidents.terminal_reason`,
    `policy_ledger.detail`, `inbox_audit.subject` — routes through
    `redaction.redact()`. Do NOT redact at call sites; a call site can
    forget. See `function/redaction.py`.

7.  **Every terminal outcome is persisted**, including crashes,
    timeouts, policy refusals, and approval denials. `close_incident`
    is called on every path; `incidents.terminal_outcome` records what
    actually happened. The reference repo ported this from a real
    production system that recorded only successes and consequently
    missed 10 agent crashes over two weeks.

8.  **Outcome reconciliation is authoritative.** Triage passes its
    `claimed_outcome` to `/api/incidents/close`; the controller
    reconciles against `demo_events` + `dq_flags` + `policy_ledger`
    and returns the `final_outcome`. Teams cards MUST use the returned
    value, never the agent's own claim. Silent-failure guard.

9.  **Repeats are suppressed by signature.** A 16-char SHA-256 prefix
    over an error string normalized of GUIDs, timestamps, and long
    numeric IDs. Second alert increments `occurrence_count` instead of
    triggering a second remediation. See `_incident_signature`.

10. **An incident is announced once, not once per occurrence.**
    Deduplication that stops the remediation but not the notification
    produces exactly the alert fatigue this demo exists to remove.
    Duplicate_suppressed goes to Teams, but the count comes with it.

11. **The inbox filter is a security control, not housekeeping.** An
    agent that acts on every message is steerable by anyone who can
    email it. `poll_inbox` fails closed — including when
    `DEMO_SUBJECT_PATTERN` is invalid — and every rejection is logged
    to `dbo.inbox_audit` with a reason. Never widen the filter to
    "make the demo find something"; send a matching message.

12. **Prompt changes are traceable.** `deploy-agents.ps1` stamps a
    SHA-256 hash of every deployed prompt into `dbo.prompt_versions`;
    agents fetch it via `/api/prompts/current` at the start
    of every run and stamp it on every `demo_events` row. A run whose
    behavior looks off can be pinned to the exact prompt version.

13. **Grant permissions to the component that acts, not the one that
    reasons.** Prompt agents hold NO Azure permissions of their own.
    Only the Function App (via its managed identity) does — for SQL,
    Graph mail, Power BI REST. Adding a permission on a reasoning
    agent means the design is wrong.

14. **A tool must fail loudly rather than return something
    interpretable.** Empty ids, missing table names, malformed JSON —
    validate at the boundary. A plausible answer built on a failed
    call is the worst outcome available. Watch `dq_check` and
    `check_or_open_incident` — both return structured `verdict:error`
    payloads rather than 200s with garbage.

15. **Scenarios are reproducible.** Same input, same tool sequence,
    same terminal outcome. `scenarios/*.yaml` `expect` blocks are the
    test. A demo you cannot rehearse is a demo you should not give.

## Adding things

- **A remediation tool.** Add it to `_REMEDIATION_ACTIONS`, wire an
  OpenAPI spec, add it to Triage's YAML `tools:`, add a scenario, add
  a case to `_OUTCOME_EVIDENCE`.
- **A safety limit.** New column on `dbo.policy_ledger` or a new
  reason value in the deny path. Add a scenario that expects the
  refusal. Never weaken a limit to make a scenario pass — change the
  scenario.
- **A playbook.** Append a `Playbook` to `function/playbooks.py` with
  `triggers`, `retry_useful`, and a **public Microsoft Learn** URL.
  Sourcing rule: use internal TSGs to decide *what matters*, but
  write the entry from public docs. This repo ships to customers.
- **A scenario.** YAML in `scenarios/` with an `expect:` block, plus
  the payload the mailbox will deliver. The `expect` block IS the
  test.
- **A prompt change.** Re-run `deploy-agents.ps1`. The prompt hash
  will change; every subsequent run stamps the new hash and it shows
  up in `dbo.prompt_versions`.

## Never

- Commit a filled `.env`, a webhook URL, or any token.
- Put a customer identifier in a committed file (SM Energy is fine;
  personal emails, TPIDs, or real workspace GUIDs are not).
- Add a network call to the deploy pipeline that requires a laptop to
  be online at demo time.
- Widen the inbox filter to "make the demo find something."
- Have Triage refresh a dataset when DQ verdict was `duplicates_found`.
- Have Triage write a DQ flag when verdict was `clean`.
