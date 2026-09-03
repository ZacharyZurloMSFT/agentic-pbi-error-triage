# Walkthrough

Two self-contained HTML pages describing the SME BI Triage demo, plus their shared stylesheet
and a `shots/` folder for screenshots.

| File | For |
|---|---|
| [`WALKTHROUGH.html`](WALKTHROUGH.html) | **Technical** — architecture, auth model, six scenarios, deploy + recovery notes. Written for engineers evaluating the design. |
| [`PERSONAS.html`](PERSONAS.html) | **Persona** — the same runs described from Priya (analyst), Sam (on-call), and Rae (data steward)'s side. Written for stakeholders who don't care about ARM roles. |
| `walkthrough.css` | Shared dark-theme styles. |
| `shots/` | Screenshots — see below. |

## Viewing

Open either file locally:

```powershell
Invoke-Item walkthrough\WALKTHROUGH.html
Invoke-Item walkthrough\PERSONAS.html
```

Both pages currently show diagonal-stripe placeholders where the screenshots go. The layout,
numbered callouts, and text carry the message without them — screenshots make it credible.

## Capturing shots

Naming convention (referenced from the HTML):

| Filename | Source |
|---|---|
| `scenario-1-clean.png` | Foundry run trace + Teams card side-by-side after the Scenario 1 email |
| `scenario-2-duplicates.png` | Foundry trace showing DQ writing to `dq_flags` before returning verdict |
| `scenario-2b-signature.png` | SSMS / Azure Data Studio: `SELECT * FROM dbo.incidents` after two identical emails, `occurrence_count >= 2` |
| `scenario-3-policy-block.png` | `SELECT * FROM dbo.policy_ledger WHERE run_id = ...` — allow + deny for the same run |
| `scenario-4-unknown-action.png` | `SELECT * FROM dbo.policy_ledger` row for `delete_bad_rows` refused |
| `failure-path.png` | Foundry trace with failed DQ span in red |
| `persona-scenario-1-teams.png` | Teams Adaptive Card for the resolved run |
| `persona-scenario-2-teams.png` | Teams card with the "N duplicates on key" phrase |
| `persona-scenario-2b-teams.png` | Teams suppression card |
| `persona-scenario-3-teams.png` | Teams policy-refusal card |
| `persona-scenario-4-teams.png` | Teams allowlist-refusal card |

Suggested workflow:

1. Compose and send the `[BI-DEMO]` email to `bi-triage-demo@…`.
2. Wait ~30s for the poller to pick it up.
3. Open Foundry portal → agents → triage-agent → runs. Screenshot the trace.
4. Switch to Teams; screenshot the Adaptive Card.
5. For SQL-state shots, run the relevant `SELECT` in your SQL client and screenshot.

Once real shots are in place, replace the `<div class="shot placeholder">…</div>` blocks in the
HTML with `<div class="shot"><img src="shots/&lt;name&gt;.png" alt="…"></div>` and add numbered
`<span class="mk cN" style="left:X%;top:Y%">N</span>` markers where the callouts should land.

## Adding a new scenario

1. Add a `<section id="scenario-X">…</section>` in `WALKTHROUGH.html`.
2. Reuse the `.figure > .cap-top + .shot + ol.callouts` pattern from an existing section.
3. Add the placeholder filename to the table above.
4. If it's audience-visible, add a corresponding section in `PERSONAS.html`.

## Publishing / sharing

Both files are single-file HTML. Embed the CSS inline before sharing outside the repo:

```powershell
$css = Get-Content walkthrough\walkthrough.css -Raw
foreach ($f in 'WALKTHROUGH.html','PERSONAS.html') {
    (Get-Content walkthrough\$f -Raw) -replace '<link rel="stylesheet" href="walkthrough.css">', "<style>`n$css`n</style>" |
        Set-Content "walkthrough\_share_$f"
}
```

That produces `_share_WALKTHROUGH.html` and `_share_PERSONAS.html` that render standalone (useful
for SharePoint / Teams preview, which drop external stylesheets).
