"""Demo Cockpit — thin FastAPI proxy over the func-sme Function App.

All reads (inbox, event log, data, teams) go through func-sme's /api/demo/*
endpoints. The Function App is the VNet-side broker with SQL + Graph app
permissions already granted to its managed identity — the cockpit only needs
a valid api://func-sme bearer token, acquired from the presenter's `az login`
via DefaultAzureCredential.

Run locally:
  uvicorn app:app --port 8000
"""
from __future__ import annotations

import asyncio
import datetime as dt
import logging
import os
import sys
from pathlib import Path
from typing import Any

import httpx
from azure.core.exceptions import ClientAuthenticationError
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("cockpit")

# --- Selective noise reduction --------------------------------------------
# Goal: still show real activity (page loads, unexpected paths, errors), but
# drop the per-tick polling chatter that makes it impossible to spot a real
# event in the terminal. Two sources are filtered:
#
#   1. azure-identity / azure-core / httpcore — token cache noise, always off.
#   2. httpx outbound to /api/demo/* and uvicorn.access on /api/* — those are
#      the repeat-every-2s polls from the browser. Everything else still logs
#      at INFO.

logging.getLogger("azure.identity").setLevel(logging.WARNING)
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

class _DropPollingPaths(logging.Filter):
    """Drop log records whose message references cockpit-poll routes."""
    _NOISE = ("/api/demo/", "/api/heartbeat", "/api/data", "/api/events",
              "/api/approvals", "/api/policy", "/api/flags", "/api/rows",
              "/api/incidents", "/api/inbox_audit", "/api/prompt_versions",
              "/api/config")
    def filter(self, record: logging.LogRecord) -> bool:  # noqa: D401
        msg = record.getMessage()
        return not any(p in msg for p in self._NOISE)

for name in ("httpx", "uvicorn.access"):
    logging.getLogger(name).addFilter(_DropPollingPaths())

# --------------------------- Config -------------------------------------

FUNCTION_URL        = os.environ.get("FUNCTION_URL", "https://func-sme.azurewebsites.net").rstrip("/")
FUNCTION_AUDIENCE   = os.environ.get("FUNCTION_AUDIENCE", "api://func-sme")
MAILBOX_UPN         = os.environ.get("MAILBOX_UPN", "")
FOUNDRY_PROJECT_URL = os.environ.get("FOUNDRY_PROJECT_URL", "https://ai.azure.com/")
POLL_INTERVAL_SEC   = int(os.environ.get("POLL_INTERVAL_SEC", "2"))
PBI_WORKSPACE_ID    = os.environ.get("PBI_WORKSPACE_ID", "")
PBI_DATASET_ID      = os.environ.get("PBI_DATASET_ID", "")

_credential = DefaultAzureCredential(exclude_managed_identity_credential=False)

# In-process token cache. See notes below on why we can't use
# azure-identity's built-in caching — AzureCliCredential in 1.25.3
# shells out to `az.exe` on every get_token which takes ~2s and blocks
# the asyncio event loop.
_token_cache: dict[str, tuple[str, dt.datetime]] = {}

# Serialize refreshes so N concurrent polls don't all race to shell out
# to `az.exe` at once. Whichever call wins acquires the token; the rest
# wait, then read from the cache.
_token_refresh_lock: asyncio.Lock | None = None  # created at startup

# One shared httpx.AsyncClient reused across every proxied call. Creating
# a new client per request works but leaks TCP connections + sockets over
# time; after ~30 minutes of steady polling the pool gets wedged and every
# fetch stalls. A single long-lived client with an explicit connection
# limit is the right answer.
_httpx: httpx.AsyncClient | None = None  # created at startup

# --------------------------- Token helpers ------------------------------


def _get_token_sync() -> None:
    """Synchronous refresh helper — runs in a threadpool so it doesn't
    block the event loop while az.exe shells out."""
    scope = FUNCTION_AUDIENCE.rstrip("/") + "/.default"
    tok = _credential.get_token(scope)
    expires_at = dt.datetime.fromtimestamp(tok.expires_on, tz=dt.timezone.utc)
    _token_cache[scope] = (tok.token, expires_at)
    now = dt.datetime.now(dt.timezone.utc)
    log.info(
        "refreshed %s token, valid for %.0f min",
        scope, (expires_at - now).total_seconds() / 60,
    )


async def _func_token() -> str:
    """Return a cached bearer token, refreshing off-event-loop if needed."""
    scope = FUNCTION_AUDIENCE.rstrip("/") + "/.default"
    now = dt.datetime.now(dt.timezone.utc)
    cached = _token_cache.get(scope)
    if cached and cached[1] > now + dt.timedelta(minutes=5):
        return cached[0]

    # Miss OR near-expiry — refresh under a lock so concurrent callers
    # collapse into a single `az.exe` invocation.
    assert _token_refresh_lock is not None, "startup didn't create lock"
    async with _token_refresh_lock:
        # Re-check inside the lock — the winner may have refreshed while
        # we were waiting.
        cached = _token_cache.get(scope)
        if cached and cached[1] > now + dt.timedelta(minutes=5):
            return cached[0]
        # Actually refresh. run_in_executor so the ~2s CLI shell-out
        # doesn't block the event loop for every other in-flight request.
        loop = asyncio.get_running_loop()
        try:
            await loop.run_in_executor(None, _get_token_sync)
        except Exception:
            # If refresh fails but we still have a valid (if soon-to-expire)
            # token, prefer returning the stale token over hard-failing.
            # This survives a transient `az` blip.
            if cached and cached[1] > now:
                log.warning("token refresh failed, using existing token for %.0f more sec",
                            (cached[1] - now).total_seconds())
                return cached[0]
            raise
    return _token_cache[scope][0]


async def _forward(
    path: str,
    body: dict[str, Any] | None = None,
    timeout: float = 45,
) -> Any:
    """POST body to {FUNCTION_URL}{path} with a bearer token; return JSON."""
    url = f"{FUNCTION_URL}{path}"
    try:
        token = await _func_token()
    except ClientAuthenticationError as exc:
        raise HTTPException(401, f"Cannot acquire {FUNCTION_AUDIENCE} token: {exc}") from exc
    assert _httpx is not None, "startup didn't create httpx client"
    try:
        r = await _httpx.post(
            url,
            json=body or {},
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            timeout=timeout,
        )
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"POST {path} failed: {exc}") from exc
    if r.status_code == 401:
        # Force a token refresh on the next call — the current token may
        # have been invalidated even though it hasn't hit our TTL yet.
        _token_cache.pop(FUNCTION_AUDIENCE.rstrip("/") + "/.default", None)
        raise HTTPException(
            401,
            f"func-sme rejected our token (Easy Auth). "
            f"Confirm your Entra OID is in allowedPrincipals for aud={FUNCTION_AUDIENCE}. "
            f"Body: {r.text[:300]}",
        )
    if r.status_code >= 400:
        raise HTTPException(r.status_code, f"POST {path} -> {r.status_code}: {r.text[:300]}")
    try:
        return r.json()
    except ValueError:
        raise HTTPException(502, f"POST {path} returned non-JSON: {r.text[:200]}")


# --------------------------- App ----------------------------------------

app = FastAPI(title="BI Triage Demo Cockpit", version="0.2.0")

STATIC_DIR = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
def root() -> Any:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/config")
def config() -> Any:
    return {
        "poll_interval_sec":   POLL_INTERVAL_SEC,
        "mailbox_upn":         MAILBOX_UPN,
        "foundry_project_url": FOUNDRY_PROJECT_URL,
        "function_url":        FUNCTION_URL,
        "pbi_workspace_id":    PBI_WORKSPACE_ID,
        "pbi_dataset_id":      PBI_DATASET_ID,
    }


# --------------------------- Read endpoints ------------------------------


@app.get("/api/inbox")
async def inbox() -> Any:
    return await _forward("/api/demo/inbox", {"top": 5})


@app.get("/api/events")
async def events(limit_runs: int = 3) -> Any:
    return await _forward("/api/demo/events", {"limit_runs": limit_runs})


@app.get("/api/heartbeat")
async def heartbeat() -> Any:
    return await _forward("/api/demo/heartbeat", {})


@app.get("/api/data")
async def data() -> Any:
    rows_task      = _forward("/api/demo/rows")
    flags_task     = _forward("/api/demo/flags")
    incidents_task = _forward("/api/demo/incidents", {"top": 10})
    policy_task    = _forward("/api/demo/policy", {"top": 20})
    rows_resp, flags_resp, incidents_resp, policy_resp = await asyncio.gather(
        rows_task, flags_task, incidents_task, policy_task,
    )
    return {
        "source_orders": rows_resp.get("rows", []),
        "dq_flags":      flags_resp.get("rows", []),
        "incidents":     incidents_resp.get("rows", []),
        "policy_ledger": policy_resp.get("rows", []),
    }


@app.get("/api/incidents")
async def incidents(top: int = 10) -> Any:
    return await _forward("/api/demo/incidents", {"top": top})


@app.get("/api/policy")
async def policy(top: int = 20) -> Any:
    return await _forward("/api/demo/policy", {"top": top})


# --------------------------- Safety-rail tiles ---------------------------


@app.get("/api/approvals")
async def approvals(top: int = 10) -> Any:
    """Human-in-the-loop gate state (Scenarios 5 + 6)."""
    return await _forward("/api/demo/approvals", {"top": top})


@app.post("/api/approvals/decide")
async def approvals_decide(payload: dict[str, Any]) -> Any:
    """Approve or deny a pending approval from the cockpit.

    Body: { "fingerprint": "<64 hex>", "decision": "granted"|"denied",
            "actor": "<upn>" }
    """
    return await _forward("/api/approvals/decide", payload)


@app.get("/api/inbox_audit")
async def inbox_audit(top: int = 25) -> Any:
    """Rejected mail from the fail-closed poller filter (invariant #11)."""
    return await _forward("/api/demo/inbox_audit", {"top": top})


@app.get("/api/prompt_versions")
async def prompt_versions() -> Any:
    """Deployed prompt hashes per agent (invariant #12 / Todo #3)."""
    return await _forward("/api/demo/prompt_versions")


@app.post("/api/playbooks/lookup")
async def playbooks_lookup(payload: dict[str, Any]) -> Any:
    """Retrieved-knowledge lookup for the current error text (Todo #4).

    Body: { "error_text": "...", "limit": 3 }
    """
    return await _forward("/api/playbooks/lookup", payload)


# --------------------------- Actions -------------------------------------


@app.post("/api/reset")
async def reset() -> Any:
    """Soft reset - truncate dq_flags + demo_events. source_orders untouched.

    Uses a longer server-side httpx timeout (110s) than the default 45s
    because the Function App can cold-start (~20s) and SQL Serverless
    can auto-resume (~90s), and the client-side reset button budget is
    120s. Anything longer than that means the runtime is genuinely stuck.
    """
    import time
    t0 = time.perf_counter()
    log.info("[reset] client requested — forwarding to /api/demo/cleanup (timeout=110s)")
    try:
        result = await _forward("/api/demo/cleanup", timeout=110)
    except HTTPException as exc:
        elapsed = int((time.perf_counter() - t0) * 1000)
        log.error("[reset] ❌ FAILED after %dms: %s", elapsed, exc.detail)
        raise
    elapsed = int((time.perf_counter() - t0) * 1000)
    log.info("[reset] ✅ ok in %dms — %s", elapsed, result)
    return result


# --------------------------- Startup log --------------------------------


@app.on_event("startup")
async def _startup() -> None:
    global _httpx, _token_refresh_lock
    log.info("Cockpit starting")
    log.info("  FUNCTION_URL       = %s", FUNCTION_URL)
    log.info("  FUNCTION_AUDIENCE  = %s", FUNCTION_AUDIENCE)
    log.info("  MAILBOX_UPN        = %s (proxied via func-sme)", MAILBOX_UPN)
    log.info("  FOUNDRY_PROJECT_URL= %s", FOUNDRY_PROJECT_URL)
    log.info("  POLL_INTERVAL_SEC  = %d", POLL_INTERVAL_SEC)

    # One long-lived HTTP client for every proxied call. Reusing the
    # connection pool prevents the socket leak we hit after ~30 min of
    # steady polling with per-request clients.
    _httpx = httpx.AsyncClient(
        limits=httpx.Limits(
            max_connections=32,
            max_keepalive_connections=16,
            keepalive_expiry=60.0,
        ),
        timeout=httpx.Timeout(45.0, connect=10.0),
    )
    _token_refresh_lock = asyncio.Lock()

    try:
        _ = await _func_token()
        log.info("  func-sme token     = ok")
    except Exception as exc:
        log.warning(
            "  func-sme token FAILED: %s -- run 'az login' and confirm your "
            "Entra OID is in func-sme's Easy Auth allowedPrincipals.",
            exc,
        )


@app.on_event("shutdown")
async def _shutdown() -> None:
    global _httpx
    if _httpx is not None:
        await _httpx.aclose()
        _httpx = None
    log.info("Cockpit shut down cleanly")
