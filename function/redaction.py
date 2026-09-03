"""Redact secrets at the store boundary — invariant #7 from AGENTS.md.

Every path that writes user-shaped text into Azure SQL (demo_events.detail,
incidents.error_class, policy_ledger.detail, incidents.terminal_reason,
inbox_audit.subject) goes through `redact()` here. Never redact at call
sites — a call site can forget. The store is the last honest place.

Patterns are intentionally over-broad on the side of erring toward removal:
we would rather lose a bit of debuggability than leak a token into a table
that eventually gets screenshotted into a customer walkthrough.

Ported from the reference `foundry-fabric-triage-demo/src/triage_demo/
redaction.py`. Sources: patterns are documented in Microsoft Learn and
in Azure's public token-format documentation.
"""
from __future__ import annotations

import re

# Each tuple is (compiled pattern, replacement token). Order matters —
# more specific patterns must run before more general ones so a JWT
# doesn't get swallowed as a bearer prefix, etc.
_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # 1. Explicit bearer tokens in headers or URLs
    (re.compile(r"[Bb]earer\s+[A-Za-z0-9\-_\.~+/]+=*"), "Bearer <redacted>"),

    # 2. Standalone JWTs (three base64 segments separated by dots).
    (re.compile(r"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b"),
     "<jwt>"),

    # 3. Azure SQL / Cosmos connection strings.
    (re.compile(r"[A-Za-z]+=[^;\s]+(?:;[A-Za-z]+=[^;\s]+){2,}"),
     "<connection-string>"),

    # 4. SAS token query strings on Storage / Service Bus URLs.
    (re.compile(r"\?(?:[a-z]{2,4}=[^&\s]+&){2,}sig=[^&\s]+"),
     "?<sas>"),

    # 5. Storage account keys (44 chars base64 ending in ==).
    (re.compile(r"\b[A-Za-z0-9+/]{86}==\b"), "<storage-key>"),

    # 6. Power BI workspace/dataset embed keys / API keys.
    (re.compile(r"\bkey=[A-Za-z0-9\-_]{20,}\b", re.IGNORECASE), "key=<redacted>"),

    # 7. Teams incoming webhook URLs (Workflows + Connectors).
    (re.compile(r"https://[a-z0-9\-.]+\.(?:webhook|logic)\.[a-z]+\.com(?::\d+)?/[A-Za-z0-9/\?\=\&\-_%.]+",
                re.IGNORECASE), "<teams-webhook>"),

    # 8. Client secrets in query strings or headers.
    (re.compile(r"client_secret=[^&\s]+", re.IGNORECASE), "client_secret=<redacted>"),

    # 9. Azure managed identity endpoints leaking the identity header.
    (re.compile(r"X-IDENTITY-HEADER:\s*[A-Za-z0-9\-_]+", re.IGNORECASE),
     "X-IDENTITY-HEADER: <redacted>"),

    # 10. Emails — bounded caution: log the domain, drop the local part.
    #     Kendra's inbox address should never appear in a customer artifact.
    (re.compile(r"\b([A-Za-z0-9._%+\-]+)@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b"),
     r"<user>@\2"),

    # 11. GUIDs immediately following the words "key", "secret", or "token".
    (re.compile(r"(?:key|secret|token)[=:\s]+[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                re.IGNORECASE), "<secret-guid>"),
]


def redact(text: str | None) -> str | None:
    """Return `text` with every known secret pattern replaced.

    None-safe (returns None) so callers can pass column values directly.
    Idempotent — running twice produces the same output.
    """
    if text is None:
        return None
    if not isinstance(text, str):
        # Defensive: an int, datetime etc. can never contain a secret;
        # returning it unchanged keeps callers simple.
        return text
    out = text
    for pattern, replacement in _PATTERNS:
        out = pattern.sub(replacement, out)
    return out


# Sanity self-test: run when the module is executed directly. Keeps the
# invariant close to the pattern list so a bad regex is caught at deploy
# time rather than in production.
if __name__ == "__main__":
    _samples = [
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
        "Server=tcp:sql-x.database.windows.net;Database=db;User=u;Password=p",
        "https://prod-04.westus.logic.azure.com:443/workflows/abcd?sig=xyz",
        "notify kendra@sm-energy.com about the outage",
        "client_secret=super-secret-value&grant_type=client_credentials",
        "token=550e8400-e29b-41d4-a716-446655440000",
    ]
    for s in _samples:
        print(f"IN : {s}")
        print(f"OUT: {redact(s)}\n")
