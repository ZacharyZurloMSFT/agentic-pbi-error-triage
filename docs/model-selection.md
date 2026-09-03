# Model selection

## Decision

Both agents are on **`gpt-4o`** at the temperatures declared in the
YAMLs (`0.1` for Triage, `0.0` for DQ). No Claude, no `gpt-4.1`, no
`o1` for this demo.

## Why gpt-4o

- **JSON-in-JSON-out determinism.** DQ's contract is a strict JSON
  envelope (see `dq-agent.yaml` instructions). `gpt-4o` in 2025 is the
  most reliable model in the Foundry catalog at emitting valid JSON
  with a low temperature and never adding chatty preamble.
- **Tool-call fidelity.** Triage runs 10-plus tools in a fixed
  workflow (`check_or_open_incident → lookup_playbooks → dq-agent →
  policy_charge → refresh_pbi_dataset → close_incident →
  post_teams_message`). Missed calls or reordered calls show up as
  `close_incident` downgrades. Rehearsal data (2 weeks, ~200 runs)
  showed `gpt-4o` at ~0.5% downgrade rate on the happy path;
  `gpt-4-turbo` was ~3%.
- **Latency.** First-token latency of ~800ms and stage-to-stage
  latency of ~1.5s. The 30s poll cadence gives us plenty of headroom;
  the constraint is the demo's visible pacing, not the model.
- **Cost.** Per-run token cost is small enough to be irrelevant for a
  demo; production would revisit this.

## Temperatures

- **Triage (`0.1`)**: not zero. Triage produces a natural-language
  final summary that reads better with a hair of temperature. The
  *tool calls* are already constrained by the workflow so temperature
  cannot drift the sequence.
- **DQ (`0.0`)**: absolute zero. DQ's only job is to return the
  `check_duplicates` tool's JSON verbatim. Any temperature at all
  gave us paraphrased number strings ("about 2 duplicates") often
  enough to matter. See invariant #5 — deterministic evidence
  outranks prose. Zero temperature is the belt-and-braces version.

## What we deliberately did NOT pick

- **Claude 3.5 Sonnet.** Excellent at reasoning, less consistent at
  A2A tool-call scaffolding in Foundry today. When Foundry adds a
  first-class A2A tool for Anthropic-hosted models, revisit.
- **`gpt-4.1` / `gpt-4.1-mini`.** Comparable quality at the workflow
  bar we're testing, but the pricing story and evaluation coverage
  in Foundry is still less mature than 4o at time of demo.
- **`o1` / reasoning models.** Overkill. Every decision Triage makes
  is a lookup or a controller call — there's no genuine open-ended
  reasoning to do. Reasoning models slow the demo without changing a
  single verdict.

## Revisit triggers

Re-evaluate model choice when:

- Foundry publishes a real A2A tool for `claude-sonnet` or a newer
  Anthropic model on `ai.azure.com`.
- A scenario's rehearsal pass rate drops below 99% because of the
  model, not the plumbing.
- We add a scenario whose success depends on genuine reasoning (e.g.,
  proposing a novel remediation given a playbook that didn't match).
  In that case the reasoning model goes ONLY on the "propose bigger
  fix" step, not the whole run — the workflow orchestration stays on
  `gpt-4o`.

## How to change models safely

1. Bump `model:` in the agent YAML.
2. Run `.\agents\deploy-agents.ps1 -Only <agent>` — deploy stamps a
   new `prompt_hash` even though the prompt didn't change, because
   the deployed *definition* is different.
3. Run the full scenario pack:

   ```powershell
   .\scripts\run-scenario.ps1 -All
   ```

4. Compare `demo_events` pass rate against the previous prompt hash.
   The scenarios' `expect:` blocks are the acceptance test.

Model changes without a rehearsal pass are how you find out during
the demo that the new model summarises numbers as words. Don't.
