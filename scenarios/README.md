# scenarios/ — YAML manifests for every demo scenario

Each YAML declares:

- `payload` — the JSON payload you (the presenter) put in the email body
- `expect` — assertions the scenario runner checks after the run
- `auto_approve` — (scenarios 5/6 only) tells the runner to POST a
  decision to `/api/approvals/decide` once an approval request appears
- `depends_on` — (scenario 2b only) name of a scenario that MUST have run
  first in the same reset cycle

## How the runner works

**You send the email manually** (Outlook, Copilot, `send-demo-email.ps1`,
or any Graph client) with subject prefix `[BI-DEMO]` and the payload
as the body. The runner watches `dbo.demo_events` for the matching
`email_received` row, then follows the run through to `teams_posted`
and asserts the `expect` block against SQL. Graph `sendMail` from an
MSIT identity into the demo mailbox failed for us
(`MailboxNotEnabledForRESTAPI`), so we punted the send step out of the
script.

## Run one

```powershell
.\scripts\run-scenario.ps1 -Name scenario1-transient
# then in another window: send the email; runner picks it up
```

## Run the full pack (respects `depends_on`)

```powershell
.\scripts\run-scenario.ps1 -All
# runner prompts one scenario at a time; you send each email as it asks
```

## `expect` grammar

| Key                            | Type    | Meaning                                                                |
|--------------------------------|---------|------------------------------------------------------------------------|
| `final_action`                 | string  | claimed outcome after `close_incident`                                 |
| `tool_sequence`                | list    | ordered tool names expected in the run (matched against `demo_events`) |
| `teams_body_contains`          | list    | literal substrings that must appear in the Teams Adaptive Card body    |
| `demo_events_stages`           | list    | subset of stages that must appear in `dbo.demo_events` (unordered)     |
| `dq_flags_rows_min`            | int     | minimum rows in `dq_flags` for this run                                |
| `incidents_min_occurrence`     | int     | minimum `occurrence_count` for the signature                           |
| `policy_ledger_min_denied`     | int     | minimum `policy_ledger` rows with `allowed=0`                          |
| `policy_ledger_action_present` | string  | expected action name present in ledger                                 |
| `approvals_final_decision`     | string  | `granted` \| `denied` \| `expired`                                     |

## Coverage matrix

| Scenario   | DQ verdict          | Terminal outcome     | Highlights              |
|------------|---------------------|----------------------|-------------------------|
| 1          | clean               | resolved             | happy path + refresh    |
| 2          | duplicates_found    | flagged_data_quality | DQ writes flags         |
| 2b         | (skipped)           | duplicate_suppressed | signature dedup         |
| 3          | clean               | policy_denied        | budget refusal          |
| 4          | (skipped)           | action_refused       | allowlist refusal       |
| 5          | duplicates_found    | resolved             | human approves          |
| 6          | duplicates_found    | approval_denied      | human declines          |
