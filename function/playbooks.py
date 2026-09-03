"""Retrieved knowledge — documented Power BI / Fabric failure modes.

The Triage Agent calls `/api/playbooks/lookup` with the raw error text and
gets back at most 3 matching entries. Each entry states whether a retry is
`retry_useful` — which is the part that changes the decision. Two error
messages that look identical ("refresh failed") can have opposite verdicts:
capacity throttling retries fine, expired credentials never do.

The reference repo makes the case for this well: "Anyone can wire an LLM
to a refresh button. The interesting question is what stops it refreshing
forty times during an outage." Playbook retrieval is how we answer that
without hard-coding it into a growing prompt.

## Sourcing rule

Every entry MUST have a public Microsoft Learn `source_url`. Internal
engineering TSGs exist and are more detailed but they're written for
on-call engineers and carry incident-management references that must
never end up in a customer-facing walkthrough. If you know something
from an internal TSG, decide **what matters** from it, then write the
entry from the public docs.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Playbook:
    id: str
    title: str
    triggers: tuple[re.Pattern[str], ...]
    retry_useful: bool
    summary: str
    source_url: str
    # Optional preferred action. Triage may (but doesn't have to) use this
    # as a hint for the next step. Never a substitute for policy_charge.
    preferred_action: str | None = None


def _rx(*patterns: str) -> tuple[re.Pattern[str], ...]:
    return tuple(re.compile(p, re.IGNORECASE) for p in patterns)


# Ordered by specificity — first match wins tie-breaks. Cap the return set
# at 3 in the API layer so the Triage prompt never gets ten paragraphs of
# retrieved knowledge to reason through.
CATALOG: tuple[Playbook, ...] = (
    Playbook(
        id="pbi-capacity-throttled",
        title="Power BI capacity throttling (SKU limit hit)",
        triggers=_rx(
            r"capacity.*(throttl|exhaust|paused|overload)",
            r"F\d+ SKU.*(limit|throttl)",
            r"429.*power ?bi",
            r"insufficient capacity",
        ),
        retry_useful=True,
        summary=(
            "Refresh was queued behind a capacity-throttled workload. A "
            "later retry usually succeeds once the throttling window "
            "clears. Do not open a data-quality ticket for this."
        ),
        source_url="https://learn.microsoft.com/power-bi/enterprise/service-premium-capacity-optimize",
        preferred_action="refresh_pbi_dataset",
    ),
    Playbook(
        id="pbi-credentials-expired",
        title="Dataset credentials expired / need re-consent",
        triggers=_rx(
            r"credentials?.*(expire|invalid|revoked|missing)",
            r"unauthorized.*(refresh|dataset|gateway)",
            r"aadsts\d{4,}",
            r"re-?consent",
        ),
        retry_useful=False,
        summary=(
            "The dataset's data-source credentials are no longer valid. "
            "Retrying refreshes will keep failing until a human updates "
            "credentials in the workspace settings. Escalate — do not "
            "retry."
        ),
        source_url="https://learn.microsoft.com/power-bi/connect-data/refresh-troubleshooting-refresh-scenarios",
    ),
    Playbook(
        id="pbi-gateway-unreachable",
        title="On-premises data gateway unreachable",
        triggers=_rx(
            r"gateway.*(offline|unreachable|not responding|timeout)",
            r"data ?source.*gateway",
            r"cannot connect.*gateway",
        ),
        retry_useful=False,
        summary=(
            "The on-premises data gateway is offline or unreachable. "
            "Refreshes will fail deterministically until the gateway "
            "host is restored. Do not retry — page the gateway owner."
        ),
        source_url="https://learn.microsoft.com/data-integration/gateway/service-gateway-onprem-tshoot",
    ),
    Playbook(
        id="pbi-transient-network",
        title="Transient network failure between service and source",
        triggers=_rx(
            r"transient.*(network|error|failure)",
            r"connection.*(reset|timed? ?out)",
            r"underlying connection was closed",
            r"tcp.*(reset|closed)",
        ),
        retry_useful=True,
        summary=(
            "A transient network hiccup between the Power BI service and "
            "the data source. Retrying once is the correct first response."
        ),
        source_url="https://learn.microsoft.com/power-bi/connect-data/refresh-troubleshooting-refresh-scenarios",
        preferred_action="refresh_pbi_dataset",
    ),
    Playbook(
        id="pbi-schema-changed",
        title="Source schema changed since last refresh",
        triggers=_rx(
            r"column.*(missing|not found|renamed)",
            r"schema.*(mismatch|changed|drift)",
            r"expression\.error",
            r"cannot find the column",
        ),
        retry_useful=False,
        summary=(
            "The upstream source's schema has changed (renamed, dropped, "
            "or retyped column). Refreshes will fail deterministically "
            "until the semantic model is updated. Do not retry — this is "
            "a modelling change, not a transient failure."
        ),
        source_url="https://learn.microsoft.com/power-query/dealing-with-errors",
    ),
    Playbook(
        id="dq-duplicate-key",
        title="Duplicate rows on declared primary key",
        triggers=_rx(
            r"duplicate.*(key|primary|order|row)",
            r"unique constraint",
            r"more than one row for the key",
        ),
        retry_useful=False,
        summary=(
            "Duplicates on the declared key column. Refresh does not fix "
            "this. Flag rows for review; a human decides whether to keep "
            "the latest, the earliest, or reconcile manually."
        ),
        source_url="https://learn.microsoft.com/power-bi/transform-model/desktop-common-query-tasks",
    ),
    Playbook(
        id="pbi-timeout-long-running",
        title="Refresh timed out (long-running query)",
        triggers=_rx(
            r"refresh.*(timed? ?out|exceeded.*timeout)",
            r"query.*(timeout|too long)",
            r"operation.*timed? ?out",
        ),
        retry_useful=False,
        summary=(
            "The refresh exceeded the service-side timeout. Retrying "
            "will hit the same timeout. Optimize the query, add an "
            "incremental-refresh policy, or move to a larger SKU."
        ),
        source_url="https://learn.microsoft.com/power-bi/connect-data/refresh-troubleshooting-refresh-scenarios",
    ),
)


def lookup(error_text: str, *, limit: int = 3) -> list[dict]:
    """Return up to `limit` playbook entries whose triggers match `error_text`.

    Deterministic ordering: catalog order breaks ties. `retry_useful` is
    exposed as a top-level field so Triage can branch on it without parsing
    prose.
    """
    if not error_text:
        return []
    hits: list[Playbook] = []
    for pb in CATALOG:
        if any(rx.search(error_text) for rx in pb.triggers):
            hits.append(pb)
        if len(hits) >= limit:
            break
    return [
        {
            "id": pb.id,
            "title": pb.title,
            "retry_useful": pb.retry_useful,
            "summary": pb.summary,
            "source_url": pb.source_url,
            "preferred_action": pb.preferred_action,
        }
        for pb in hits
    ]


if __name__ == "__main__":
    for err in [
        "Refresh failed: capacity throttled (F2 SKU limit).",
        "Refresh failed: credentials expired AADSTS70008.",
        "Refresh failed: on-premises gateway offline.",
        "Duplicate primary key on order_id.",
        "The underlying connection was closed unexpectedly.",
    ]:
        print(err)
        for hit in lookup(err):
            print(f"  -> {hit['id']}  retry_useful={hit['retry_useful']}")
        print()
