# AGENTS.md — agents/

Bootstrap contract for a coding agent editing the two **Foundry prompt
agents** in this folder. Read the root [`AGENTS.md`](../AGENTS.md) first
— its 15 invariants apply here.

## What lives here

- `definitions/triage-agent.yaml` — orchestrator prompt + tools.
- `definitions/dq-agent.yaml` — data-quality worker prompt + tools.
- `definitions/openapi/*.yaml` — Power BI + Teams tool specs.
- `deploy-agents.ps1` — reads a YAML, inlines its OpenAPI specs,
  PATCHes the agent via the Foundry Agents REST API, then stamps a
  prompt hash into `dbo.prompt_versions`.

Function-side tool specs live in `../function/openapi-*.yaml` and are
referenced from the agent YAMLs by relative path.

## Agent-level invariants (in addition to root)

Numbers continue from the root list.

16. **Prompt agents hold no permissions.** No Entra roles, no Azure
    resource access, no secrets. All side effects flow through
    Function App tools that authenticate via the Function App's own
    managed identity. This is what makes "agent identity" honest —
    what an agent CAN do is auditable via the tools it holds, not the
    role assignments it inherits.

17. **A2A calls are declarative.** Triage does not hand-craft HTTP to
    reach DQ. The `dq-agent-a2a` connection encapsulates URL + audience
    + token minting so the a2a_preview tool works via
    `AgenticIdentityToken`. If a run trace shows Triage minting its
    own token, the design is wrong.

18. **Every agent stamps its own identity + prompt_hash on every
    `log_event`.** Not one shared placeholder. This is how a mixed
    trace (Triage → DQ → Triage) stays legible in the cockpit.

19. **Instructions carry the WORKFLOW; tools carry the CAPABILITIES.**
    Do not encode allowlists, budgets, or approval logic in prompt
    wording. Encode the *sequence* and let the tools return the
    verdicts. The controller — not the prompt — decides what happens.

20. **Instructions are versioned by hash, not by comment.** Bump the
    body; deploy; the hash changes; runs stamp the new hash. Never
    add "v3" markers or dated headers to the instructions block.

## Development workflow

```powershell
# Edit definitions/triage-agent.yaml or dq-agent.yaml, then:
cd agents
.\deploy-agents.ps1 -Only triage        # or 'dq', or 'both' (default)

# Deploy also stamps the new prompt hash into dbo.prompt_versions.
```

## References

- [Prompt agents overview](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/prompt-agents)
- [OpenAPI tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/openapi)
- [Agent-to-Agent tool (preview)](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/agent-to-agent)
