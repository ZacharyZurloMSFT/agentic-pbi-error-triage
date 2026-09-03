# Run sheet — SM Energy BI Triage live demo

A pausable, ~60–90 minute script for the live demo. Every step lists
what to say, what to click, and what to watch on screen. Two projectors
recommended: **cockpit** on one, **Foundry run trace** on the other.

## Pre-flight (do this 30 minutes before showtime)

- [ ] `az login` in the demo tenant; verify `az account show` is right.
- [ ] `.\demo-tools.ps1 -Reset` — resets `dq_flags`, `demo_events`,
      `incidents`, `policy_ledger`, `inbox_audit`, `approvals`.
- [ ] `.\agents\deploy-agents.ps1` — ensures the current prompt hashes
      are in `dbo.prompt_versions`.
- [ ] Load cockpit at `https://cockpit-sme.azurewebsites.net`; confirm:
      poll heartbeat < 30s old, all tiles green, Teams tile empty.
- [ ] Foundry run trace tab open on the DQ agent (empty runs list).
- [ ] SharePoint tab open on `walkthrough/WALKTHROUGH.html` as a
      fallback if projector switching gets awkward.

## Opening (5 min)

Say: **"The interesting question is not can an LLM click refresh. It's
what stops it clicking refresh forty times during an outage, and what
stops it deleting the wrong table because a prompt was worded
ambiguously. That's what this demo is about."**

Show the cockpit's **Agent Flow** tile (empty). Point at the four
tables in the SQL tile: `dq_flags`, `incidents`, `policy_ledger`,
`approvals`. Say: **"These four tables are the demo's safety story.
Every guardrail is a row in one of them. Nothing is enforced by
prompt wording."**

## Scenario 1 — Transient (10 min)

Say: **"Happy path. Ordinary transient network hiccup. Refresh
succeeds. Nothing dramatic. But watch what happens BEFORE the
refresh."**

Run:

```powershell
.\scripts\run-scenario.ps1 -Name scenario1-transient
```

Wait for `email_received` → `incident_opened` → `playbook_retrieved`.

**Pause point A.** Point at `playbook_retrieved` in the cockpit's
Agent Flow tile. Open the Foundry run trace and show the
`lookup_playbooks` tool call with `retry_useful: true` for the
`pbi-transient-network` hit. Say: **"The agent didn't decide to
retry because the error had the word 'transient' in it. It decided
to retry because the retrieved playbook said retries are useful for
this class of failure. The knowledge is data in a file, not baked
into a prompt."**

Continue. `tier1_classified` → `policy_charge` (allowed) →
`refresh_pbi_dataset` → `close_incident` → `teams_posted`.

## Scenario 2 — Data quality (10 min)

Say: **"Same trigger shape. Different verdict."**

```powershell
.\scripts\run-scenario.ps1 -Name scenario2-data-quality -SkipReset
```

**Pause point B.** When `dq_delegated` appears, flip to the Foundry
run trace. Show the Triage run and, side-by-side, the DQ run linked
from it — that is the agent-to-agent handoff Alice's email
demanded. Say: **"This is `a2a_preview`. Triage does not hand-craft
HTTP to reach DQ. Foundry mints an `AgenticIdentityToken` on
Triage's behalf against the RemoteA2A connection. If we ever see
Triage minting its own token, the design is wrong."**

Show `dbo.dq_flags` before → after. One row per duplicate. No
refresh happened, and no refresh will happen — the guardrail is
`_REMEDIATION_ACTIONS` in the controller.

Teams card: **"Table dbo.source_orders contains 2 duplicates on key
order_id"** — the exact PRD §2.1 phrasing.

## Scenario 2b — Known issue (5 min)

Say: **"Same alert, second time. Watch what does NOT happen."**

```powershell
.\scripts\run-scenario.ps1 -Name scenario2b-known-issue -SkipReset
```

Watch: `email_received` → `duplicate_suppressed` → `teams_posted`.
No DQ, no policy_charge, no refresh, no flag. The `dbo.incidents`
row for scenario 1's signature has `occurrence_count = 2`. Teams
card: **"Duplicate alert suppressed — occurrence 2 (first seen
…)"**.

**Pause point C.** Say: **"The signature is a 16-char SHA-256 of
the error normalised of GUIDs, timestamps, and long numeric IDs.
Two occurrences of the same failure collide. The reference
implementation this is ported from suppressed 40+ retries during a
real Fabric outage; this is what that looks like on Day One."**

## Scenario 3 — Policy block (10 min)

Say: **"This scenario is where budget gets tested."**

```powershell
.\scripts\run-scenario.ps1 -Name scenario3-policy-block
```

Watch: `tier1_classified` → `refresh_triggered` (first refresh
succeeds) → **`policy_denied`** on the second `policy_charge`.
Show `dbo.policy_ledger` — two rows, first `allowed=1`, second
`allowed=0` with `deny_reason=budget_exhausted`. Teams card:
**"Policy refused: budget_exhausted. Escalating to human."**.

**Pause point D.** Say: **"A refusal is data, not a crash. If we
killed the run at that moment, the operator would get silence. A
denial we can *return to the agent* lets it escalate cleanly."**

## Scenario 4 — Unknown action (10 min)

Say: **"This is the one that matters if you're worried about an
agent doing something creative."**

```powershell
.\scripts\run-scenario.ps1 -Name scenario4-unknown-action
```

Show `policy_ledger`: one row, `action=delete_bad_rows`,
`allowed=0`, `deny_reason=not_on_allowlist`. The action never
dispatched — there is no `delete_bad_rows` tool wired to Triage.
The controller refused before Triage could reach the tool binding.

**Pause point E.** Say: **"The allowlist lives in the controller
alongside the tool registration. Anything not on the allowlist is
refused before dispatch. You can't add a new action by editing a
prompt. That's the whole property the demo rests on."**

## Scenarios 5 + 6 — Human approval (15 min)

Say: **"This is the branch that makes it generalise."**

```powershell
.\scripts\run-scenario.ps1 -Name scenario5-approval-granted
```

Watch:  `dq_flagged` → `approval_requested`. In Teams, an
Adaptive Card appears with **Approve** and **Deny** buttons. The
scenario runner auto-approves within a few seconds (in a real
live demo, the presenter clicks Approve).

Watch: `approval_granted` → `close_incident` → `teams_posted`.

**Pause point F.** Say: **"An approval is only a *yes* if it is
explicit, fingerprint-matched, unexpired, and unused. Timeout,
error, malformed reply, missing gate — all *no*. Silence never
reads as consent. Now the harder version."**

```powershell
.\scripts\run-scenario.ps1 -Name scenario6-approval-denied
```

Same setup, but the human declines. Watch: `approval_denied` →
`teams_posted` with **"Human declined the proposed bigger fix — no
action taken."** Nothing dispatched. That is the correct ending.

Say: **"An agent that respects a *no* is one you can put on-call.
This scenario is Kendra's answer to *'what happens when it's
wrong?'*"**

## Wrap-up and live Q&A (10 min)

Cover the five PRD §2.1 questions in order. Answers in `docs/faq.md`.

Show `dbo.prompt_versions` — every deployed prompt has a hash. Every
`demo_events` row has that hash stamped. If the answer to *"why did
it behave differently today?"* is *"we changed the prompt"*, the
diff is trivial to find.

Show `dbo.inbox_audit`. Say: **"Everything the poller REJECTED gets
a row here. If it doesn't rehearse-answer to itself, the inbox
becomes a steering vector. Right now this table is empty except for
your own noise; that's the state we want."**

## If something fails during the demo

- **Poller stops picking up mail.** Check `dbo.inbox_audit`. The
  subject probably drifted from `DEMO_SUBJECT_PATTERN`. Send a
  matching one — never widen the filter.
- **DQ agent never returns.** Foundry run trace on DQ will show the
  hang. `check_duplicates` timeout → controller returns
  `verdict:error` → Triage still runs `close_incident` and reports
  `needs_human` in Teams. That IS the correct behavior.
- **`close_incident` downgrades to `needs_human`.** Something the
  agent claimed didn't happen. Cockpit shows the reason. This is
  the silent-failure guard doing its job.
- **Teams card doesn't show.** Fall back to the cockpit's Teams tile
  (which reads Graph directly).

## Timings

| Segment              | Target | Actual (rehearsal 1) | Actual (rehearsal 2) |
|----------------------|--------|----------------------|----------------------|
| Opening              | 5      |                      |                      |
| Scenario 1           | 10     |                      |                      |
| Scenario 2           | 10     |                      |                      |
| Scenario 2b          | 5      |                      |                      |
| Scenario 3           | 10     |                      |                      |
| Scenario 4           | 10     |                      |                      |
| Scenarios 5 + 6      | 15     |                      |                      |
| Wrap + Q&A           | 10     |                      |                      |
| **Total**            | **75** |                      |                      |
