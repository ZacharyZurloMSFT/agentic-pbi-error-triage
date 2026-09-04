"""Function App — DQ + admin endpoints, plus the mailbox poller timer.

Replaces the previous hosted DQ + Triage agent containers and the ACI-based
mailbox trigger. Prompt agents in Foundry call `/dq/check` and `/dq/flag`
via an OpenAPI tool with managed-identity auth (Foundry project MI presents
a bearer token whose `aud` matches this Function App's App Registration).
Easy Auth v2 enforces the allowedPrincipals gate.

HTTP endpoints (all POST):
  /api/dq/check                — duplicate scan; DQ agent JSON contract
  /api/dq/flag                 — write one row per duplicate into dbo.dq_flags
  /api/log_event               — Cockpit Agent Flow event log
  /api/incidents/check_or_open — signature-based dedup (Scenario 2b)
  /api/incidents/close         — outcome validation / silent-failure guard (Todo #6)
  /api/policy/charge           — remediation budget (Scenario 3)
  /api/policy/propose_action   — allowlist gate (Scenario 4)
  /api/approvals/request       — human-in-the-loop request  (Todo #7 / Scenarios 5+6)
  /api/approvals/decide        — Teams Action.Submit callback
  /api/approvals/status        — Triage polls this while waiting
  /api/playbooks/lookup        — retrieved knowledge lookup (Todo #4)
  /api/prompts/register        — deploy-agents.ps1 stamps this (Todo #3)
  /api/prompts/current         — agents read this at run start
  /api/demo/*                  — cockpit tile sources + admin (seed/reset/migrate)

Timer:
  poll_inbox — every 30s, reads unread [BI-DEMO] mail and POSTs the extracted
               payload to the Triage agent's Responses endpoint. Fail-closed
               subject filter (Todo #1) — invalid pattern refuses to poll.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import logging
import os
import pathlib
import re
import secrets
from html import unescape

import azure.functions as func
import httpx
from azure.identity import DefaultAzureCredential

from sql import connect as sql_connect, valid_ident
from redaction import redact
import playbooks as playbook_catalog

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

MAILBOX_UPN         = os.environ.get("MAILBOX_UPN", "")
TRIAGE_ENDPOINT     = os.environ.get("TRIAGE_ENDPOINT", "")
DEMO_SUBJECT_PREFIX = os.environ.get("DEMO_SUBJECT_PREFIX", "[BI-DEMO]")
# Todo #1: fail-closed inbox filter. Full regex applied to the subject.
# Invalid regex refuses to poll; the poller writes an inbox_audit row and
# stops. Never widen this to make the demo "find something".
DEMO_SUBJECT_PATTERN = os.environ.get("DEMO_SUBJECT_PATTERN", r"^\[BI-DEMO\]")

# Todo #7: HMAC secret for approval fingerprints. If unset, approvals
# refuse to issue — an approval without a signing secret is a joke.
# Rotate by changing this app setting and re-deploying; pending approvals
# from the previous secret become unclaimable (fail-closed).
APPROVAL_HMAC_SECRET = os.environ.get("APPROVAL_HMAC_SECRET", "")
APPROVAL_TTL_MIN     = int(os.environ.get("APPROVAL_TTL_MIN", "15"))
# Where the Adaptive Card's Approve/Deny button sends the human. Teams
# Workflows Incoming Webhooks have no Action.Submit back-channel, so we
# render an Action.OpenUrl that hands the decision to the cockpit instead.
APPROVAL_UI_URL      = os.environ.get("APPROVAL_UI_URL", "http://localhost:8000/#approvals")

_credential = DefaultAzureCredential()
GRAPH = "https://graph.microsoft.com/v1.0"

# Special run_id used for poll heartbeat rows. Filtered out of /demo/events
# so it never pollutes the Agent Flow tile, but exposed via /demo/heartbeat
# so the cockpit can render an honest countdown to the next mailbox poll.
POLLER_RUN_ID = "__poller__"

# T-SQL scripts are bundled next to function_app.py at deploy time.
_SQL_DIR = pathlib.Path(__file__).parent / "sql_scripts"

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _json(body, status: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(body, default=str),
        status_code=status,
        mimetype="application/json",
    )


def _now_iso() -> str:
    return dt.datetime.utcnow().isoformat(timespec="seconds") + "Z"


def _read_json(req: func.HttpRequest) -> dict:
    try:
        return req.get_json() or {}
    except ValueError:
        return {}


def _split_batches(script: str) -> list[str]:
    """Split a T-SQL script on standalone `GO` separators (case-insensitive)."""
    lines = script.splitlines()
    batches: list[list[str]] = [[]]
    for line in lines:
        if line.strip().upper() == "GO":
            batches.append([])
        else:
            batches[-1].append(line)
    return [b for b in ("\n".join(chunk).strip() for chunk in batches) if b]


def _run_script(script_name: str) -> dict:
    path = _SQL_DIR / script_name
    if not path.exists():
        raise FileNotFoundError(str(path))
    script = path.read_text(encoding="utf-8")
    batches = _split_batches(script)
    results: list[dict] = []
    with sql_connect(autocommit=True) as conn:
        cur = conn.cursor()
        for i, batch in enumerate(batches):
            cur.execute(batch)
            # Drain a SELECT result if the batch produced one (final verify SELECTs).
            if cur.description:
                cols = [c[0] for c in cur.description]
                rows = cur.fetchall()
                results.append({
                    "batch": i,
                    "columns": cols,
                    "rows": [
                        {c: r[j] for j, c in enumerate(cols)} for r in rows
                    ],
                })
    return {"batches": len(batches), "results": results, "ran_at": _now_iso()}


# --------------------------------------------------------------------------
# /dq/check
# --------------------------------------------------------------------------


@app.function_name("dq_check")
@app.route(route="dq/check", methods=["POST"])
def dq_check(req: func.HttpRequest) -> func.HttpResponse:
    """Duplicate scan against a source table on a declared key column.

    Request:  {"table_name": "dbo.source_orders", "key_column": "order_id"}
    Response contract matches the old DQ agent so no downstream changes:
        {
          "verdict": "clean" | "duplicates_found" | "error",
          "table": "...",
          "key_column": "...",
          "duplicate_count": <int>,
          "duplicates": [{ "key_value": "...", "dup_count": <int> }, ...],
          "checked_at": "<ISO 8601 UTC>"
        }
    """
    payload = _read_json(req)
    table_name = payload.get("table_name") or ""
    key_column = payload.get("key_column") or ""
    checked_at = _now_iso()

    try:
        table = valid_ident(table_name)
        key   = valid_ident(key_column)
    except ValueError as exc:
        return _json({
            "verdict": "error",
            "table": table_name,
            "key_column": key_column,
            "duplicate_count": 0,
            "duplicates": [],
            "checked_at": checked_at,
            "error": str(exc),
        }, status=400)

    sql = (
        f"SELECT {key} AS key_value, COUNT(*) AS dup_count "
        f"FROM {table} "
        f"GROUP BY {key} "
        f"HAVING COUNT(*) > 1 "
        f"ORDER BY dup_count DESC, key_value"
    )

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(sql)
            rows = cur.fetchall()
        duplicates = [
            {"key_value": str(r[0]), "dup_count": int(r[1])} for r in rows
        ]
        return _json({
            "verdict": "duplicates_found" if duplicates else "clean",
            "table": table,
            "key_column": key,
            "duplicate_count": len(duplicates),
            "duplicates": duplicates,
            "checked_at": checked_at,
        })
    except Exception as exc:
        logging.exception("dq_check failed for %s / %s", table, key)
        # Return 200 (not 500) so the DQ agent's OpenAPI tool wrapper sees a
        # legitimate response body and can surface {verdict:"error"} to
        # Triage. Reserving 500 for HTTP-level failures keeps the failure
        # path — bad table name, etc. — flowing through the agent trace as
        # designed rather than as an opaque tool exception.
        return _json({
            "verdict": "error",
            "table": table,
            "key_column": key,
            "duplicate_count": 0,
            "duplicates": [],
            "checked_at": checked_at,
            "error": f"{type(exc).__name__}: {exc}",
        })


# --------------------------------------------------------------------------
# /dq/flag
# --------------------------------------------------------------------------


@app.function_name("dq_flag")
@app.route(route="dq/flag", methods=["POST"])
def dq_flag(req: func.HttpRequest) -> func.HttpResponse:
    """Insert a duplicate flag row.

    Request body:
      {
        "table_name":    "dbo.source_orders",
        "key_columns":   "order_id",
        "key_value":     "O-1003",
        "dup_count":     3,
        "source_run_id": "<foundry run id>"    # optional
      }
    Response:
      { "flag_id": <int>, "detected_at": "<ISO>", ...echoed inputs }
    """
    payload = _read_json(req)
    try:
        table_name    = str(payload["table_name"])
        key_columns   = str(payload["key_columns"])
        key_value     = str(payload["key_value"])
        dup_count     = int(payload["dup_count"])
    except (KeyError, TypeError, ValueError) as exc:
        return _json({"status": "failed", "error": f"bad request: {exc}"}, status=400)
    source_run_id = str(payload.get("source_run_id") or "") or None

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO dbo.dq_flags "
                "(table_name, key_columns, key_value, dup_count, source_run_id) "
                "OUTPUT INSERTED.flag_id, INSERTED.detected_at "
                "VALUES (%s, %s, %s, %s, %s)",
                (table_name, key_columns, key_value, dup_count, source_run_id),
            )
            row = cur.fetchone()
            conn.commit()
        return _json({
            "flag_id": int(row[0]),
            "detected_at": row[1].isoformat() + "Z",
            "table_name": table_name,
            "key_columns": key_columns,
            "key_value": key_value,
            "dup_count": dup_count,
        })
    except Exception as exc:
        logging.exception("dq_flag insert failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /log_event  (cockpit Agent Flow tile source)
# --------------------------------------------------------------------------


@app.function_name("log_event")
@app.route(route="log_event", methods=["POST"])
def log_event(req: func.HttpRequest) -> func.HttpResponse:
    """Insert a run-stage row into dbo.demo_events.

    Triage calls this once per stage so the Demo Cockpit can light up the
    Agent Flow tile in real time. Cheap fire-and-forget log; no SELECTs.

    Request body:
      {
        "run_id":    "<foundry run id or triage-generated GUID>",
        "scenario":  "transient" | "data_quality" | "escalate",
        "stage":     "email_received" | "dq_delegated" | "dq_verdict"
                     | "refresh_triggered" | "flag_written" | "teams_posted",
        "status":    "ok" | "failed" | "info",
        "detail":    "<short human-readable summary>",     # optional
        "trace_url": "<Foundry run trace deep link>"       # optional
      }
    Response: { "event_id": <int>, "created_at": "<ISO>" }
    """
    payload = _read_json(req)
    try:
        run_id = str(payload["run_id"])
        stage  = str(payload["stage"])
        status = str(payload["status"])
    except (KeyError, TypeError) as exc:
        return _json({"status": "failed", "error": f"bad request: {exc}"}, status=400)
    scenario  = (payload.get("scenario")  or None) and str(payload["scenario"])
    # Todo #2 (redaction): detail is user-controlled text — redact at the
    # store boundary, never at the call site.
    detail    = redact((payload.get("detail") or None) and str(payload["detail"]))
    trace_url = (payload.get("trace_url") or None) and str(payload["trace_url"])
    # Todo #3 (prompt hashing): agents stamp their identity + prompt hash on
    # every event so a prompt change is traceable in run history.
    agent       = (payload.get("agent")       or None) and str(payload["agent"])[:32]
    prompt_hash = (payload.get("prompt_hash") or None) and str(payload["prompt_hash"])[:16]

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO dbo.demo_events "
                "(run_id, scenario, stage, status, detail, trace_url, agent, prompt_hash) "
                "OUTPUT INSERTED.event_id, INSERTED.created_at "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                (run_id, scenario, stage, status, detail, trace_url, agent, prompt_hash),
            )
            row = cur.fetchone()
            conn.commit()
        return _json({
            "event_id": int(row[0]),
            "created_at": row[1].isoformat() + "Z",
        })
    except Exception as exc:
        logging.exception("log_event insert failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /admin/seed  &  /admin/reset
# --------------------------------------------------------------------------


@app.function_name("demo_seed")
@app.route(route="demo/seed", methods=["POST"])
def demo_seed(req: func.HttpRequest) -> func.HttpResponse:
    """Run seed.sql — deterministic bootstrap + duplicate seed."""
    try:
        return _json(_run_script("seed.sql"))
    except Exception as exc:
        logging.exception("admin_seed failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_reset")
@app.route(route="demo/reset", methods=["POST"])
def demo_reset(req: func.HttpRequest) -> func.HttpResponse:
    """Run reset.sql — fast reset between demo runs."""
    try:
        return _json(_run_script("reset.sql"))
    except Exception as exc:
        logging.exception("admin_reset failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


def _select_all(sql: str) -> list[dict]:
    with sql_connect() as conn:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [c[0] for c in cur.description]
        return [{c: r[i] for i, c in enumerate(cols)} for r in cur.fetchall()]


@app.function_name("demo_flags")
@app.route(route="demo/flags", methods=["POST"])
def demo_flags(req: func.HttpRequest) -> func.HttpResponse:
    """Dump dbo.dq_flags for demo inspection between runs."""
    try:
        rows = _select_all(
            "SELECT flag_id, table_name, key_columns, key_value, dup_count, "
            "detected_at, source_run_id FROM dbo.dq_flags ORDER BY flag_id"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("admin_flags failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_rows")
@app.route(route="demo/rows", methods=["POST"])
def demo_rows(req: func.HttpRequest) -> func.HttpResponse:
    """Dump dbo.source_orders for demo inspection."""
    try:
        rows = _select_all(
            "SELECT line_id, order_id, customer_id, order_date, amount, region "
            "FROM dbo.source_orders ORDER BY line_id"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("admin_rows failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_cleanup")
@app.route(route="demo/cleanup", methods=["POST"])
def demo_cleanup(req: func.HttpRequest) -> func.HttpResponse:
    """TRUNCATE dbo.dq_flags + dbo.demo_events between demo runs (fast state reset).

    Leaves dbo.source_orders untouched so the seeded rows survive scenario resets.
    Called by the cockpit's Reset button between scenarios.
    """
    try:
        with sql_connect(autocommit=True) as conn:
            cur = conn.cursor()
            cur.execute("TRUNCATE TABLE dbo.dq_flags")
            # demo_events / incidents / policy_ledger may not exist on older
            # DBs; ignore + log if any fails. dq_flags is the only mandatory one.
            events_cleared = incidents_cleared = policy_cleared = False
            audit_cleared = approvals_cleared = False
            try:
                cur.execute("TRUNCATE TABLE dbo.demo_events")
                events_cleared = True
            except Exception as inner:
                logging.warning("truncate demo_events skipped: %s", inner)
            try:
                cur.execute("TRUNCATE TABLE dbo.incidents")
                incidents_cleared = True
            except Exception as inner:
                logging.warning("truncate incidents skipped: %s", inner)
            try:
                cur.execute("TRUNCATE TABLE dbo.policy_ledger")
                policy_cleared = True
            except Exception as inner:
                logging.warning("truncate policy_ledger skipped: %s", inner)
            try:
                cur.execute("TRUNCATE TABLE dbo.inbox_audit")
                audit_cleared = True
            except Exception as inner:
                logging.warning("truncate inbox_audit skipped: %s", inner)
            try:
                cur.execute("TRUNCATE TABLE dbo.approvals")
                approvals_cleared = True
            except Exception as inner:
                logging.warning("truncate approvals skipped: %s", inner)
            # Re-seed a poll_tick after truncate so the cockpit countdown
            # doesn't snap to "Polling…" for the full 30s window.
            if events_cleared:
                try:
                    cur.execute(
                        "INSERT INTO dbo.demo_events "
                        "(run_id, scenario, stage, status, detail) "
                        "VALUES (%s, %s, %s, %s, %s)",
                        (POLLER_RUN_ID, "poller", "poll_tick", "info",
                         "reset preserves heartbeat"),
                    )
                except Exception as inner:
                    logging.warning("post-reset heartbeat write skipped: %s", inner)
        cleared = ["dq_flags"]
        if events_cleared:    cleared.append("demo_events")
        if incidents_cleared: cleared.append("incidents")
        if policy_cleared:    cleared.append("policy_ledger")
        if audit_cleared:     cleared.append("inbox_audit")
        if approvals_cleared: cleared.append("approvals")
        return _json({
            "status": "ok",
            "action": "truncate " + " + ".join(cleared),
            "at": _now_iso(),
        })
    except Exception as exc:
        logging.exception("admin_cleanup failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /admin/events — cockpit Agent Flow tile source
# --------------------------------------------------------------------------


@app.function_name("demo_events")
@app.route(route="demo/events", methods=["POST"])
def demo_events(req: func.HttpRequest) -> func.HttpResponse:
    """Return the latest N runs from dbo.demo_events, grouped by run_id.

    Request body (all optional):
      { "limit_runs": 3 }
    Response:
      {
        "runs": [
          {
            "run_id":     "...",
            "scenario":   "transient" | "data_quality" | "escalate" | null,
            "trace_url":  "..." | null,
            "started_at": "<ISO>",
            "stages": [
              { "stage": "...", "status": "...", "detail": "...", "at": "<ISO>" },
              ...
            ]
          }, ...
        ],
        "checked_at": "<ISO>"
      }
    """
    payload = _read_json(req)
    try:
        limit_runs = int(payload.get("limit_runs") or 3)
    except (TypeError, ValueError):
        limit_runs = 3
    limit_runs = max(1, min(limit_runs, 20))

    sql = (
        "WITH recent_runs AS ("
        "  SELECT TOP (%s) run_id, MAX(created_at) AS last_ts "
        "  FROM dbo.demo_events "
        "  WHERE run_id <> '__poller__' "
        "  GROUP BY run_id "
        "  ORDER BY MAX(created_at) DESC"
        ") "
        "SELECT e.event_id, e.run_id, e.scenario, e.stage, e.status, "
        "       e.detail, e.trace_url, e.created_at "
        "FROM dbo.demo_events e "
        "JOIN recent_runs r ON r.run_id = e.run_id "
        "ORDER BY r.last_ts DESC, e.event_id ASC"
    )

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(sql, (limit_runs,))
            cols = [c[0] for c in cur.description]
            rows = [{c: r[i] for i, c in enumerate(cols)} for r in cur.fetchall()]
    except Exception as exc:
        logging.exception("admin_events failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)

    runs: dict[str, dict] = {}
    for row in rows:
        rid = row["run_id"]
        started_at = row["created_at"]
        run = runs.setdefault(rid, {
            "run_id": rid,
            "scenario": row.get("scenario"),
            "trace_url": row.get("trace_url"),
            "started_at": started_at.isoformat() + "Z",
            "stages": [],
        })
        # Prefer any non-null scenario/trace_url encountered.
        if row.get("scenario") and not run["scenario"]:
            run["scenario"] = row["scenario"]
        if row.get("trace_url") and not run["trace_url"]:
            run["trace_url"] = row["trace_url"]
        run["stages"].append({
            "stage": row["stage"],
            "status": row["status"],
            "detail": row.get("detail"),
            "at": row["created_at"].isoformat() + "Z",
        })

    return _json({"runs": list(runs.values()), "checked_at": _now_iso()})


# --------------------------------------------------------------------------
# /incidents/check_or_open — Scenario 2b (known-issue dedup)
# --------------------------------------------------------------------------

# Patterns used to normalize the raw error into a stable class before hashing.
# GUIDs, ISO timestamps, and long numeric IDs are noise — two occurrences of
# the same failure will differ on those but not on the underlying message.
_GUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
_ISO_TS_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?")
_LONG_NUM_RE = re.compile(r"\b\d{6,}\b")


def _normalize_error(err: str) -> str:
    """Strip GUIDs / timestamps / long numeric IDs from a raw error string so
    two occurrences of the same failure collide on the signature."""
    txt = err or ""
    txt = _GUID_RE.sub("<guid>", txt)
    txt = _ISO_TS_RE.sub("<ts>", txt)
    txt = _LONG_NUM_RE.sub("<n>", txt)
    return " ".join(txt.split()).lower()


def _incident_signature(report: str, source_table: str, key_column: str, err: str) -> str:
    """16-char SHA-256 prefix over the normalized incident fingerprint."""
    fingerprint = "|".join([
        (report or "").strip().lower(),
        (source_table or "").strip().lower(),
        (key_column or "").strip().lower(),
        _normalize_error(err),
    ])
    return hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()[:16]


@app.function_name("incidents_check_or_open")
@app.route(route="incidents/check_or_open", methods=["POST"])
def incidents_check_or_open(req: func.HttpRequest) -> func.HttpResponse:
    """Open a new incident or bump the counter on an existing one.

    Called by Triage as the FIRST step of every run. A second alert with the
    same signature is suppressed — Triage skips DQ, refresh, and flag write.

    Request:
      {
        "report":       "<name>",
        "source_table": "<schema.table>",
        "key_column":   "<column>",
        "error":        "<raw error text>",
        "run_id":       "<foundry run id>"
      }
    Response:
      {
        "signature":        "<16 hex chars>",
        "action":           "open" | "suppress",
        "occurrence_count": <int>,
        "first_seen_at":    "<ISO>",
        "last_seen_at":     "<ISO>",
        "error_class":      "<normalized error>"
      }
    """
    payload = _read_json(req)
    report       = str(payload.get("report") or "")
    source_table = str(payload.get("source_table") or "")
    key_column   = str(payload.get("key_column") or "")
    raw_error    = str(payload.get("error") or "")
    run_id       = str(payload.get("run_id") or "")

    signature   = _incident_signature(report, source_table, key_column, raw_error)
    # Todo #2: error_class enters SQL — redact at the store boundary.
    error_class = redact(_normalize_error(raw_error))

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT signature, first_seen_at, last_seen_at, occurrence_count "
                "FROM dbo.incidents WHERE signature = %s",
                (signature,),
            )
            row = cur.fetchone()
            if row is None:
                cur.execute(
                    "INSERT INTO dbo.incidents "
                    "(signature, occurrence_count, status, report, source_table, "
                    " key_column, error_class, source_run_id) "
                    "OUTPUT INSERTED.first_seen_at, INSERTED.last_seen_at "
                    "VALUES (%s, 1, 'open', %s, %s, %s, %s, %s)",
                    (signature, report[:128] or None, source_table[:128] or None,
                     key_column[:128] or None, error_class[:500] or None,
                     run_id[:64] or None),
                )
                first_seen, last_seen = cur.fetchone()
                conn.commit()
                return _json({
                    "signature":        signature,
                    "action":           "open",
                    "occurrence_count": 1,
                    "first_seen_at":    first_seen.isoformat() + "Z",
                    "last_seen_at":     last_seen.isoformat() + "Z",
                    "error_class":      error_class,
                })
            _, first_seen, _, current_count = row
            cur.execute(
                "UPDATE dbo.incidents "
                "SET occurrence_count = occurrence_count + 1, "
                "    last_seen_at = SYSUTCDATETIME() "
                "OUTPUT INSERTED.occurrence_count, INSERTED.last_seen_at "
                "WHERE signature = %s",
                (signature,),
            )
            new_count, last_seen = cur.fetchone()
            conn.commit()
            return _json({
                "signature":        signature,
                "action":           "suppress",
                "occurrence_count": int(new_count),
                "first_seen_at":    first_seen.isoformat() + "Z",
                "last_seen_at":     last_seen.isoformat() + "Z",
                "error_class":      error_class,
            })
    except Exception as exc:
        logging.exception("incidents_check_or_open failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /policy/charge — Scenario 3 (remediation budget)
# --------------------------------------------------------------------------

# Actions that consume the per-run remediation budget. Read-only tools
# (log_event, dq_check, post_teams_message, incidents/check_or_open) never
# hit /policy/charge and never count against it.
_REMEDIATION_ACTIONS = {"refresh_pbi_dataset", "write_dq_flag"}


@app.function_name("policy_charge")
@app.route(route="policy/charge", methods=["POST"])
def policy_charge(req: func.HttpRequest) -> func.HttpResponse:
    """Charge the per-run remediation ledger before taking an action.

    Triage MUST call this before every remediation. The ledger is authoritative:
    if `allowed=false` comes back, the agent does NOT take the action, logs
    `policy_denied`, and escalates via Teams. This is how "one remediation per
    run" is enforced across every agent in the run — no wording change to the
    prompt raises the budget.

    Request:
      {
        "run_id":          "<foundry run id>",
        "action":          "refresh_pbi_dataset" | "write_dq_flag",
        "budget_override": <int, optional>   # demo escape hatch
      }
    Response:
      {
        "allowed":     true | false,
        "remaining":   <int>,           # after this call
        "budget":      <int>,           # total budget
        "deny_reason": "<short>" | null,
        "ledger_id":   <int>
      }
    """
    payload = _read_json(req)
    run_id = str(payload.get("run_id") or "").strip()
    action = str(payload.get("action") or "").strip()
    if not run_id or not action:
        return _json({"status": "failed", "error": "run_id and action are required"}, status=400)

    try:
        budget = int(payload.get("budget_override")) if payload.get("budget_override") is not None else 1
    except (TypeError, ValueError):
        budget = 1
    budget = max(0, budget)

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT COUNT(*) FROM dbo.policy_ledger "
                "WHERE run_id = %s AND allowed = 1",
                (run_id,),
            )
            spent = int(cur.fetchone()[0])
            allowed = spent < budget
            deny_reason = None if allowed else "budget_exhausted"
            detail = f"budget={budget}, spent={spent}"
            cur.execute(
                "INSERT INTO dbo.policy_ledger "
                "(run_id, action, allowed, deny_reason, detail) "
                "OUTPUT INSERTED.ledger_id "
                "VALUES (%s, %s, %s, %s, %s)",
                (run_id[:64], action[:64], 1 if allowed else 0,
                 deny_reason, detail[:500]),
            )
            ledger_id = int(cur.fetchone()[0])
            conn.commit()
        remaining = max(0, budget - spent - (1 if allowed else 0))
        return _json({
            "allowed":     allowed,
            "remaining":   remaining,
            "budget":      budget,
            "deny_reason": deny_reason,
            "ledger_id":   ledger_id,
        })
    except Exception as exc:
        logging.exception("policy_charge failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /policy/propose_action — Scenario 4 (allowlist)
# --------------------------------------------------------------------------


@app.function_name("policy_propose_action")
@app.route(route="policy/propose_action", methods=["POST"])
def policy_propose_action(req: func.HttpRequest) -> func.HttpResponse:
    """Gate an arbitrary proposed action against the tool allowlist.

    The allowlist lives in the controller, not the prompt. Anything off-list
    is refused with a legible reason, and the refusal is a `policy_ledger` row
    so the demo can point at it. The agent then escalates via Teams.

    Request:
      {
        "run_id": "<foundry run id>",
        "action": "<proposed action name>",
        "args":   { ... }               # opaque, echoed back
      }
    Response:
      {
        "status":      "dispatched" | "refused",
        "action":      "<proposed action>",
        "deny_reason": "<short>" | null,
        "allowlist":   ["refresh_pbi_dataset", "write_dq_flag"],
        "ledger_id":   <int>
      }
    """
    payload = _read_json(req)
    run_id = str(payload.get("run_id") or "").strip()
    action = str(payload.get("action") or "").strip()
    if not run_id or not action:
        return _json({"status": "failed", "error": "run_id and action are required"}, status=400)

    allowed = action in _REMEDIATION_ACTIONS
    deny_reason = None if allowed else "not_on_allowlist"
    # Todo #2: args_keys is server-computed; still route through redact for
    # the store-boundary invariant.
    detail = redact(
        f"action={action}, args_keys={sorted(list((payload.get('args') or {}).keys()))}"
    )

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO dbo.policy_ledger "
                "(run_id, action, allowed, deny_reason, detail) "
                "OUTPUT INSERTED.ledger_id "
                "VALUES (%s, %s, %s, %s, %s)",
                (run_id[:64], action[:64], 1 if allowed else 0,
                 deny_reason, detail[:500]),
            )
            ledger_id = int(cur.fetchone()[0])
            conn.commit()
        return _json({
            "status":      "dispatched" if allowed else "refused",
            "action":      action,
            "deny_reason": deny_reason,
            "allowlist":   sorted(_REMEDIATION_ACTIONS),
            "ledger_id":   ledger_id,
        })
    except Exception as exc:
        logging.exception("policy_propose_action failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /demo/incidents  &  /demo/policy — cockpit tile sources
# --------------------------------------------------------------------------


@app.function_name("demo_incidents")
@app.route(route="demo/incidents", methods=["POST"])
def demo_incidents(req: func.HttpRequest) -> func.HttpResponse:
    """Return recent rows from dbo.incidents for the cockpit Incidents tile."""
    payload = _read_json(req)
    try:
        top = int(payload.get("top") or 10)
    except (TypeError, ValueError):
        top = 10
    top = max(1, min(top, 50))
    try:
        rows = _select_all(
            f"SELECT TOP ({top}) signature, first_seen_at, last_seen_at, "
            f"occurrence_count, status, report, source_table, key_column, "
            f"error_class, terminal_outcome, terminal_reason, closed_at "
            f"FROM dbo.incidents ORDER BY last_seen_at DESC"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("demo_incidents failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_policy")
@app.route(route="demo/policy", methods=["POST"])
def demo_policy(req: func.HttpRequest) -> func.HttpResponse:
    """Return recent rows from dbo.policy_ledger for the cockpit Policy tile."""
    payload = _read_json(req)
    try:
        top = int(payload.get("top") or 20)
    except (TypeError, ValueError):
        top = 20
    top = max(1, min(top, 100))
    try:
        rows = _select_all(
            f"SELECT TOP ({top}) ledger_id, run_id, action, allowed, "
            f"deny_reason, detail, charged_at "
            f"FROM dbo.policy_ledger ORDER BY ledger_id DESC"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("demo_policy failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /demo/heartbeat — cockpit countdown source
# --------------------------------------------------------------------------


@app.function_name("demo_heartbeat")
@app.route(route="demo/heartbeat", methods=["POST"])
def demo_heartbeat(req: func.HttpRequest) -> func.HttpResponse:
    """Return the latest poll_tick row so the cockpit can render a countdown.

    Response:
      {
        "last_poll_at":      "<ISO or null>",
        "poll_interval_sec": 30,
        "note":              "polled N items"     # last poll's detail
      }
    """
    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT TOP 1 created_at, detail FROM dbo.demo_events "
                "WHERE run_id = %s AND stage = 'poll_tick' "
                "ORDER BY event_id DESC",
                (POLLER_RUN_ID,),
            )
            row = cur.fetchone()
        if row is None:
            return _json({
                "last_poll_at":      None,
                "poll_interval_sec": 30,
                "note":              None,
            })
        return _json({
            "last_poll_at":      row[0].isoformat() + "Z",
            "poll_interval_sec": 30,
            "note":              row[1],
        })
    except Exception as exc:
        logging.exception("demo_heartbeat failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# --------------------------------------------------------------------------
# /admin/inbox — cockpit Inbox tile source
# --------------------------------------------------------------------------


@app.function_name("demo_inbox")
@app.route(route="demo/inbox", methods=["POST"])
def demo_inbox(req: func.HttpRequest) -> func.HttpResponse:
    """Return the last N [BI-DEMO] messages from the monitored mailbox.

    Uses the Function App's MI + Mail.Read app permission — same auth path
    the poll_inbox timer already uses successfully.
    """
    payload = _read_json(req)
    try:
        top = int(payload.get("top") or 5)
    except (TypeError, ValueError):
        top = 5
    top = max(1, min(top, 25))

    if not MAILBOX_UPN:
        return _json({"messages": [], "note": "MAILBOX_UPN not set"})

    url = f"{GRAPH}/users/{MAILBOX_UPN}/mailFolders/Inbox/messages"
    params = {
        "$select": "id,subject,receivedDateTime,isRead,from",
        "$orderby": "receivedDateTime desc",
        "$top": "25",
    }
    try:
        with httpx.Client(timeout=15) as client:
            r = client.get(url, params=params, headers={"Authorization": f"Bearer {_graph_token()}"})
            if r.status_code >= 400:
                logging.error("Graph list mail %s: %s", r.status_code, r.text[:400])
                r.raise_for_status()
            raw = r.json().get("value", [])
    except Exception as exc:
        logging.exception("admin_inbox failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)

    messages = []
    for m in raw:
        subj = m.get("subject") or ""
        if not subj.startswith(DEMO_SUBJECT_PREFIX):
            continue
        messages.append({
            "id":       m.get("id"),
            "subject":  subj,
            "received": m.get("receivedDateTime"),
            "is_read":  bool(m.get("isRead")),
            "sender":   (m.get("from") or {}).get("emailAddress", {}).get("address"),
        })
        if len(messages) >= top:
            break

    return _json({"messages": messages, "checked_at": _now_iso()})


# --------------------------------------------------------------------------
# /admin/teams — cockpit Teams tile source
# --------------------------------------------------------------------------


@app.function_name("demo_teams")
@app.route(route="demo/teams", methods=["POST"])
def demo_teams(req: func.HttpRequest) -> func.HttpResponse:
    """Return the last N messages from the demo Teams channel.

    Reads via Function MI's ChannelMessage.Read.Group app permission. Parses
    the Adaptive Card attachment (application/vnd.microsoft.card.adaptive)
    when present so the cockpit can render the card body directly.

    Request body:
      { "top": 5, "team_id": "<guid or blank>", "channel_id": "<id or blank>" }
    Missing team_id/channel_id fall through to TEAMS_TEAM_ID/TEAMS_CHANNEL_ID
    env vars.
    """
    payload = _read_json(req)
    try:
        top = int(payload.get("top") or 5)
    except (TypeError, ValueError):
        top = 5
    top = max(1, min(top, 20))

    team_id    = str(payload.get("team_id")    or os.environ.get("TEAMS_TEAM_ID", ""))
    channel_id = str(payload.get("channel_id") or os.environ.get("TEAMS_CHANNEL_ID", ""))
    if not (team_id and channel_id):
        return _json({"messages": [], "note": "TEAMS_TEAM_ID / TEAMS_CHANNEL_ID not set"})

    url = f"{GRAPH}/teams/{team_id}/channels/{channel_id}/messages"
    try:
        with httpx.Client(timeout=15) as client:
            r = client.get(
                url,
                params={"$top": str(min(top * 2, 20))},
                headers={"Authorization": f"Bearer {_graph_token()}"},
            )
            if r.status_code >= 400:
                logging.error("Graph teams messages %s: %s", r.status_code, r.text[:400])
                r.raise_for_status()
            raw = r.json().get("value", [])
    except Exception as exc:
        logging.exception("admin_teams failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)

    messages = []
    for m in raw:
        body = m.get("body") or {}
        atts = m.get("attachments") or []
        card = None
        for att in atts:
            if att.get("contentType") == "application/vnd.microsoft.card.adaptive":
                raw_content = att.get("content")
                if isinstance(raw_content, str):
                    try:
                        card = json.loads(raw_content)
                    except json.JSONDecodeError:
                        card = None
                elif isinstance(raw_content, dict):
                    card = raw_content
                break
        from_field = m.get("from") or {}
        messages.append({
            "id":         m.get("id"),
            "web_url":    m.get("webUrl"),
            "created_at": m.get("createdDateTime"),
            "from": (
                ((from_field.get("user") or {}).get("displayName"))
                or ((from_field.get("application") or {}).get("displayName"))
                or ""
            ),
            "body_html":     body.get("content") if body.get("contentType") == "html" else None,
            "body_text":     body.get("content") if body.get("contentType") == "text" else None,
            "adaptive_card": card,
        })
        if len(messages) >= top:
            break

    return _json({"messages": messages, "checked_at": _now_iso()})


# --------------------------------------------------------------------------
# poll_inbox timer
# --------------------------------------------------------------------------


def _graph_token() -> str:
    return _credential.get_token("https://graph.microsoft.com/.default").token


def _ai_token() -> str:
    return _credential.get_token("https://ai.azure.com/.default").token


def _strip_html(body: str) -> str:
    txt = re.sub(r"<style[^>]*>.*?</style>", "", body, flags=re.DOTALL | re.IGNORECASE)
    txt = re.sub(r"<script[^>]*>.*?</script>", "", txt, flags=re.DOTALL | re.IGNORECASE)
    txt = re.sub(r"<[^>]+>", "", txt)
    return unescape(txt).strip()


def _find_json_payload(text: str) -> dict | None:
    # Outlook & other rich-text clients "helpfully" convert straight ASCII
    # quotes into curly quotes and insert non-breaking spaces. Normalize
    # everything back to the ASCII forms json.loads accepts before scanning.
    normalized = (
        text
        .replace("\u201c", '"').replace("\u201d", '"')  # curly double quotes
        .replace("\u2018", "'").replace("\u2019", "'")  # curly single quotes
        .replace("\u00a0", " ")                          # non-breaking space
        .replace("\u200b", "")                           # zero-width space
    )
    for match in re.finditer(r"\{[\s\S]*?\}", normalized):
        try:
            obj = json.loads(match.group(0))
            if isinstance(obj, dict) and "source_table" in obj and "key_column" in obj:
                return obj
        except json.JSONDecodeError:
            continue
    return None


def _write_inbox_audit(
    message_id: str | None,
    subject: str | None,
    sender: str | None,
    received_at: dt.datetime | str | None,
    reason: str,
    pattern_used: str | None,
) -> None:
    """Todo #1 (fail-closed filter): record every mail we did NOT process.

    Reasons in play: subject_no_match, invalid_pattern, non_demo_sender.
    Best-effort — never let an audit-write failure stop the poller.
    """
    try:
        if isinstance(received_at, str):
            try:
                received_at = dt.datetime.fromisoformat(received_at.replace("Z", "+00:00"))
            except ValueError:
                received_at = None
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO dbo.inbox_audit "
                "(message_id, received_at, subject, sender, reason, pattern_used) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (
                    (message_id or "")[:256] or None,
                    received_at,
                    redact((subject or "")[:500]) or None,
                    redact((sender or "")[:256]) or None,
                    reason[:64],
                    (pattern_used or "")[:256] or None,
                ),
            )
            conn.commit()
    except Exception:
        logging.exception("inbox_audit write failed")


def _list_unread(client: httpx.Client) -> list[dict]:
    url = f"{GRAPH}/users/{MAILBOX_UPN}/mailFolders/Inbox/messages"
    params = {
        "$filter": "isRead eq false",
        "$select": "id,subject,receivedDateTime,body,from",
        "$orderby": "receivedDateTime desc",
        "$top": "10",
    }
    r = client.get(
        url, params=params,
        headers={"Authorization": f"Bearer {_graph_token()}"},
    )
    if r.status_code >= 400:
        logging.error("Graph list mail %s: %s", r.status_code, r.text[:800])
    r.raise_for_status()
    all_msgs = r.json().get("value", [])

    # Todo #1: fail-closed regex filter. If the pattern is invalid, refuse
    # to process any mail and audit every message we saw.
    try:
        pattern = re.compile(DEMO_SUBJECT_PATTERN)
    except re.error as exc:
        logging.error("invalid DEMO_SUBJECT_PATTERN %r: %s — refusing to poll",
                      DEMO_SUBJECT_PATTERN, exc)
        for m in all_msgs:
            _write_inbox_audit(
                m.get("id"),
                m.get("subject"),
                (m.get("from") or {}).get("emailAddress", {}).get("address"),
                m.get("receivedDateTime"),
                "invalid_pattern",
                DEMO_SUBJECT_PATTERN,
            )
        return []

    matched: list[dict] = []
    for m in all_msgs:
        subj = m.get("subject") or ""
        if pattern.search(subj):
            matched.append(m)
        else:
            _write_inbox_audit(
                m.get("id"),
                subj,
                (m.get("from") or {}).get("emailAddress", {}).get("address"),
                m.get("receivedDateTime"),
                "subject_no_match",
                DEMO_SUBJECT_PATTERN,
            )
            # Mark rejected mail read so it doesn't re-audit every 30 s
            # and clutter the mailbox. The inbox_audit row is the record.
            try:
                _mark_read(client, m.get("id"))
            except Exception:
                logging.exception("mark_read (subject_no_match) failed for %s", m.get("id"))
    return matched


def _mark_read(client: httpx.Client, message_id: str) -> None:
    url = f"{GRAPH}/users/{MAILBOX_UPN}/messages/{message_id}"
    r = client.patch(
        url,
        json={"isRead": True},
        headers={
            "Authorization": f"Bearer {_graph_token()}",
            "Content-Type": "application/json",
        },
    )
    r.raise_for_status()


def _invoke_triage(client: httpx.Client, payload: dict) -> httpx.Response:
    user_content = (
        "A new BI error email arrived. Process it end-to-end per your workflow. "
        "Payload:\n\n" + json.dumps(payload)
    )
    body = {
        "input": [{"role": "user", "content": user_content}],
        "store": False,
        # A full S1/S2 run is ~14 tool calls before the terminal
        # close_incident+Teams pair; S3/S5/S6 add a few more. The Foundry
        # default cap is low enough to strand runs mid-workflow (the
        # symptom is a 200 response after the last log_event with no
        # policy_charge/refresh/close_incident that follows). Raise the
        # ceiling so every scenario has headroom.
        #
        # max_output_tokens is bumped to gpt-4o's 16k ceiling because the
        # HITL approval poll loop (S5/S6) burns tokens fast: the model has
        # no sleep tool, so it fires check_approval every ~1-2s and each
        # iteration produces reasoning text. At 8k the response truncates
        # mid-loop and the run silently stops after the user approves.
        # HITL (S5/S6) polls `check_approval` up to 40 times, plus ~14
        # pre-approval calls and ~5 post-approval calls = ~60. Cap at 100.
        "max_tool_calls":    100,
        "max_output_tokens": 16000,
    }
    return client.post(
        TRIAGE_ENDPOINT,
        json=body,
        headers={
            "Authorization": f"Bearer {_ai_token()}",
            "Content-Type": "application/json",
        },
        timeout=180,
    )


def _write_poll_heartbeat(message_count: int) -> None:
    """Insert a lightweight poll_tick row so the cockpit can render a countdown.

    Written on EVERY timer tick regardless of whether mail was found. Uses a
    reserved run_id ('__poller__') that /demo/events filters out — this stays
    out of the Agent Flow tile but drives /demo/heartbeat.
    """
    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO dbo.demo_events "
                "(run_id, scenario, stage, status, detail) "
                "VALUES (%s, %s, %s, %s, %s)",
                (POLLER_RUN_ID, "poller", "poll_tick", "info",
                 f"polled {message_count} items"),
            )
            conn.commit()
    except Exception:
        # Heartbeat is best-effort — never let a logging failure break the poller.
        logging.exception("poll heartbeat write failed")


@app.function_name("poll_inbox")
@app.schedule(
    schedule="*/30 * * * * *",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=False,
)
def poll_inbox(timer: func.TimerRequest) -> None:
    if not MAILBOX_UPN or not TRIAGE_ENDPOINT:
        logging.warning("poll_inbox skipped — MAILBOX_UPN / TRIAGE_ENDPOINT not set")
        _write_poll_heartbeat(0)
        return

    with httpx.Client(timeout=30) as client:
        try:
            messages = _list_unread(client)
        except Exception:
            logging.exception("failed to list unread mail")
            _write_poll_heartbeat(0)
            return

        _write_poll_heartbeat(len(messages))

        if not messages:
            return

        logging.info("Found %d unread %s messages", len(messages), DEMO_SUBJECT_PREFIX)
        for msg in messages:
            mid = msg["id"]
            subject = msg.get("subject", "")

            # Mark read FIRST — as soon as the poller picks the message up.
            # This is what makes the demo feel deterministic: one poll cycle
            # = one read-mark, regardless of what happens downstream. Duplicate
            # protection is handled by dbo.incidents signature dedup, not by
            # leaving mail unread. If a mark-read call fails, log and continue;
            # a rare re-poll is preferable to halting the loop.
            try:
                _mark_read(client, mid)
            except Exception:
                logging.exception("mark_read failed for %s (continuing anyway)", mid)

            body_wrapper = msg.get("body") or {}
            body_content = body_wrapper.get("content", "") or ""
            body_text = (
                _strip_html(body_content)
                if body_wrapper.get("contentType") == "html"
                else body_content
            )

            payload = _find_json_payload(body_text)
            if not payload:
                logging.warning(
                    "Message %s (%s) had no JSON payload. Body preview: %r",
                    mid, subject, body_text[:400],
                )
                continue

            logging.info("Invoking Triage for message %s (%s)", mid, subject)
            try:
                r = _invoke_triage(client, payload)
                logging.info(
                    "Triage responded %s in %.1fs",
                    r.status_code, r.elapsed.total_seconds(),
                )
                if r.status_code >= 400:
                    logging.error("Triage error body: %s", r.text[:500])
            except Exception:
                logging.exception("invoke Triage failed for %s", mid)




# =========================================================================
# Todo #3: prompt version hashing — deploy stamp + agent-read helpers.
# =========================================================================

def _prompt_hash(text: str) -> str:
    """16-char SHA-256 prefix. Matches signature hash length for consistency."""
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()[:16]


@app.function_name("register_prompt_hash")
@app.route(route="prompts/register", methods=["POST"])
def register_prompt_hash(req: func.HttpRequest) -> func.HttpResponse:
    """Called by deploy-agents.ps1 after a successful PATCH/POST of an agent.

    Request:
      { "agent": "triage-agent",
        "instructions": "<full prompt body>",
        "deployed_by":  "<upn or 'automation'>" }
    Response:
      { "agent": "...", "prompt_hash": "<16 hex>", "version_id": <int> }
    """
    payload = _read_json(req)
    agent = str(payload.get("agent") or "").strip()[:64]
    instr = str(payload.get("instructions") or "")
    if not agent or not instr:
        return _json({"status": "failed", "error": "agent and instructions required"}, status=400)
    phash = _prompt_hash(instr)
    deployed_by = str(payload.get("deployed_by") or "")[:128] or None
    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            # Skip insert if the same hash is already the latest for this agent
            cur.execute(
                "SELECT TOP 1 prompt_hash, version_id FROM dbo.prompt_versions "
                "WHERE agent = %s ORDER BY version_id DESC",
                (agent,),
            )
            row = cur.fetchone()
            if row and row[0] == phash:
                return _json({
                    "agent": agent, "prompt_hash": phash,
                    "version_id": int(row[1]), "unchanged": True,
                })
            cur.execute(
                "INSERT INTO dbo.prompt_versions "
                "(agent, prompt_hash, instructions_len, deployed_by) "
                "OUTPUT INSERTED.version_id "
                "VALUES (%s, %s, %s, %s)",
                (agent, phash, len(instr), deployed_by),
            )
            version_id = int(cur.fetchone()[0])
            conn.commit()
        return _json({
            "agent": agent, "prompt_hash": phash,
            "version_id": version_id, "unchanged": False,
        })
    except Exception as exc:
        logging.exception("register_prompt_hash failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("current_prompt_hash")
@app.route(route="prompts/current", methods=["POST"])
def current_prompt_hash(req: func.HttpRequest) -> func.HttpResponse:
    """Return the latest prompt_hash for an agent so it can stamp events.

    Request:  { "agent": "triage-agent" }
    Response: { "agent": "...", "prompt_hash": "<16 hex or empty>",
                "deployed_at": "<ISO or null>" }
    Never fails — a missing row returns an empty hash so agents can proceed
    without breaking the run when this table is not yet populated.
    """
    payload = _read_json(req)
    agent = str(payload.get("agent") or "").strip()[:64]
    if not agent:
        return _json({"agent": "", "prompt_hash": "", "deployed_at": None})
    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT TOP 1 prompt_hash, deployed_at FROM dbo.prompt_versions "
                "WHERE agent = %s ORDER BY version_id DESC",
                (agent,),
            )
            row = cur.fetchone()
        if not row:
            return _json({"agent": agent, "prompt_hash": "", "deployed_at": None})
        return _json({
            "agent": agent,
            "prompt_hash": str(row[0]),
            "deployed_at": row[1].isoformat() + "Z",
        })
    except Exception as exc:
        logging.exception("current_prompt_hash failed")
        # Fail-soft so a SQL blip does not kill an in-flight demo run.
        return _json({"agent": agent, "prompt_hash": "", "deployed_at": None,
                      "error": f"{type(exc).__name__}: {exc}"})


# =========================================================================
# Todo #4: playbook retrieval.
# =========================================================================

@app.function_name("playbooks_lookup")
@app.route(route="playbooks/lookup", methods=["POST"])
def playbooks_lookup(req: func.HttpRequest) -> func.HttpResponse:
    """Return up to 3 matching failure-mode playbooks for a raw error string.

    Request:  { "error_text": "...", "limit": 3 }
    Response: { "hits": [ { id, title, retry_useful, summary, source_url,
                            preferred_action }, ... ],
                "checked_at": "<ISO>" }
    """
    payload = _read_json(req)
    error_text = str(payload.get("error_text") or "")
    try:
        limit = int(payload.get("limit") or 3)
    except (TypeError, ValueError):
        limit = 3
    limit = max(1, min(limit, 3))  # Hard cap. If a new playbook matters more
                                    # than an existing one, raise its trigger
                                    # specificity, not the cap.
    hits = playbook_catalog.lookup(error_text, limit=limit)
    return _json({"hits": hits, "checked_at": _now_iso()})


# =========================================================================
# Todo #6: outcome validation / silent-failure guard.
# =========================================================================

# Which stages count as "real work happened" for each claimed outcome. If the
# agent claims a terminal state that we can't corroborate in this dict, the
# controller downgrades to needs_human. Ported from the reference repo's
# outcome-validation invariant.
_OUTCOME_EVIDENCE = {
    "resolved":              ("refresh_triggered", "ok"),
    "flagged_data_quality":  ("dq_flagged", "ok"),
    "duplicate_suppressed":  ("duplicate_suppressed", "info"),
    "escalated":             ("escalated", "error"),
    "action_refused":        ("action_refused", "error"),
    "policy_denied":         ("policy_denied", "error"),
    "approval_denied":       ("approval_denied", "info"),
    "needs_human":           (None, None),  # trivially supported
}


@app.function_name("incidents_close")
@app.route(route="incidents/close", methods=["POST"])
def incidents_close(req: func.HttpRequest) -> func.HttpResponse:
    """Reconcile the agent's claimed outcome against actual evidence.

    Triage MUST call this immediately before /post_teams_message and MUST
    use the returned `final_outcome` in the Teams card. The controller,
    not the agent, decides what actually happened.

    Rules (from AGENTS.md invariant #8 of the reference repo):
      * "resolved" without a refresh_triggered=ok in demo_events  → needs_human
      * "flagged_data_quality" without any dq_flags rows for this run  → needs_human
      * "duplicate_suppressed" without an open incident matching  → needs_human
      * Everything else falls through to the claim.

    Request:
      { "run_id": "...", "signature": "...", "claimed_outcome": "resolved" }
    Response:
      { "final_outcome": "resolved" | "needs_human",
        "downgraded":    true | false,
        "reason":        "<short>",
        "signature":     "..." }
    """
    payload = _read_json(req)
    run_id = str(payload.get("run_id") or "").strip()
    signature = str(payload.get("signature") or "").strip()
    claimed = str(payload.get("claimed_outcome") or "").strip()
    if not run_id or not claimed:
        return _json({"status": "failed", "error": "run_id and claimed_outcome are required"}, status=400)

    downgraded = False
    reason: str | None = None
    final = claimed

    expected = _OUTCOME_EVIDENCE.get(claimed)
    if expected is None:
        final = "needs_human"
        downgraded = True
        reason = f"unrecognized claimed_outcome={claimed}"
    else:
        want_stage, want_status = expected
        try:
            with sql_connect() as conn:
                cur = conn.cursor()
                if want_stage is not None:
                    cur.execute(
                        "SELECT COUNT(*) FROM dbo.demo_events "
                        "WHERE run_id = %s AND stage = %s AND status = %s",
                        (run_id, want_stage, want_status),
                    )
                    stage_hits = int(cur.fetchone()[0])
                    if stage_hits == 0:
                        final = "needs_human"
                        downgraded = True
                        reason = f"no {want_stage}={want_status} event for this run"

                # Extra corroboration for the two claims most likely to lie.
                # NOTE: DQ Agent runs under its own A2A run context and does not
                # receive triage's run_id, so we cannot match on source_run_id.
                # Instead we require evidence that a flag row was written
                # recently (within the last 5 minutes) — this preserves the
                # "outcome must have physical evidence" invariant without
                # depending on run_id plumbing across the A2A boundary.
                if claimed == "flagged_data_quality" and not downgraded:
                    cur.execute(
                        "SELECT COUNT(*) FROM dbo.dq_flags "
                        "WHERE detected_at > DATEADD(minute, -5, SYSUTCDATETIME())"
                    )
                    if int(cur.fetchone()[0]) == 0:
                        final = "needs_human"
                        downgraded = True
                        reason = "no recent dq_flags rows"

                if claimed == "duplicate_suppressed" and not downgraded:
                    if signature:
                        cur.execute(
                            "SELECT COUNT(*) FROM dbo.incidents "
                            "WHERE signature = %s AND occurrence_count > 1",
                            (signature,),
                        )
                        if int(cur.fetchone()[0]) == 0:
                            final = "needs_human"
                            downgraded = True
                            reason = "no matching incident with occurrence_count>1"

                # Persist terminal state onto the incident row (if we have one).
                if signature:
                    cur.execute(
                        "UPDATE dbo.incidents "
                        "SET terminal_outcome = %s, "
                        "    terminal_reason  = %s, "
                        "    status           = 'closed', "
                        "    closed_at        = SYSUTCDATETIME() "
                        "WHERE signature = %s",
                        (final[:32], redact(reason)[:500] if reason else None, signature),
                    )
                conn.commit()
        except Exception as exc:
            logging.exception("incidents_close failed")
            return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)

    return _json({
        "final_outcome": final,
        "downgraded":    downgraded,
        "reason":        reason,
        "signature":     signature or None,
        "claimed":       claimed,
    })


# =========================================================================
# Todo #7: human-in-the-loop approvals.
# =========================================================================

def _args_hash(args: dict | None) -> str:
    """Stable hash over sorted args for approval fingerprinting."""
    payload = json.dumps(args or {}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def _approval_fingerprint(run_id: str, action: str, args_hash: str) -> str:
    """HMAC-SHA256 (secret, run_id|action|args_hash). Hex, 64 chars.

    The secret lives in APPROVAL_HMAC_SECRET. Without it, approvals refuse
    to issue — an unsigned approval is trivially forgeable and would silently
    disarm the whole safety story.
    """
    if not APPROVAL_HMAC_SECRET:
        raise RuntimeError("APPROVAL_HMAC_SECRET not configured")
    msg = f"{run_id}|{action}|{args_hash}".encode("utf-8")
    return hmac.new(
        APPROVAL_HMAC_SECRET.encode("utf-8"), msg, hashlib.sha256
    ).hexdigest()


@app.function_name("approvals_request")
@app.route(route="approvals/request", methods=["POST"])
def approvals_request(req: func.HttpRequest) -> func.HttpResponse:
    """Triage calls this when a policy_charge returns requires_approval.

    Returns a fingerprint the Teams Adaptive Card embeds in Action.Submit
    payloads and an ISO expires_at. Triage then polls /approvals/status
    (Scenario 5+6). Every approval is one-use and TTL-bound.

    Request:
      { "run_id": "...", "action": "apply_bigger_fix",
        "args":   { "table": "dbo.source_orders", "strategy": "keep_latest" },
        "requested_by": "triage-agent" }
    Response:
      { "fingerprint": "<64 hex>", "expires_at": "<ISO>",
        "ttl_min": 15, "adaptive_card": { ... } }
    """
    payload = _read_json(req)
    run_id = str(payload.get("run_id") or "").strip()
    action = str(payload.get("action") or "").strip()
    args = payload.get("args") or {}
    if not run_id or not action:
        return _json({"status": "failed", "error": "run_id and action are required"}, status=400)
    if not APPROVAL_HMAC_SECRET:
        return _json({
            "status": "failed",
            "error": "APPROVAL_HMAC_SECRET not configured — approvals disabled",
        }, status=500)

    args_h = _args_hash(args if isinstance(args, dict) else {})
    fp = _approval_fingerprint(run_id, action, args_h)
    expires_at = dt.datetime.utcnow() + dt.timedelta(minutes=APPROVAL_TTL_MIN)

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            # Idempotent: same run_id+action+args → same fingerprint → single row
            cur.execute(
                "SELECT decision FROM dbo.approvals WHERE fingerprint = %s",
                (fp,),
            )
            row = cur.fetchone()
            if row is None:
                cur.execute(
                    "INSERT INTO dbo.approvals "
                    "(fingerprint, run_id, action, args_hash, expires_at, decision, detail) "
                    "VALUES (%s, %s, %s, %s, %s, 'pending', %s)",
                    (fp, run_id[:64], action[:64], args_h, expires_at,
                     redact(f"args_keys={sorted(list(args.keys())) if isinstance(args, dict) else []}")[:500]),
                )
                conn.commit()
    except Exception as exc:
        logging.exception("approvals_request failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)

    # Build an Adaptive Card that Triage can post directly to Teams.
    #
    # Delivery constraint: this card is posted through a Teams Workflows
    # Incoming Webhook (anonymous). That transport has NO back-channel —
    # Action.Submit payloads go nowhere and Teams renders "Unable to reach
    # app. Please try again." Adaptive Cards do not support Action.Http,
    # and Action.Execute requires a registered bot with an invoke URL,
    # which this demo does not carry.
    #
    # So the card hands the decision off to the cockpit's Approvals tile
    # via Action.OpenUrl. The cockpit already POSTs /api/approvals/decide
    # with the (fingerprint, decision) pair; the fingerprint is the source
    # of truth, not the button label. Fail-closed semantics are unchanged.
    card = {
        "type": "AdaptiveCard",
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "version": "1.4",
        "body": [
            {"type": "TextBlock", "size": "Medium", "weight": "Bolder",
             "text": f"Approval requested: {action}"},
            {"type": "TextBlock", "wrap": True,
             "text": f"Triage would like to apply `{action}` for run `{run_id}`. "
                     f"This request expires at {expires_at.isoformat(timespec='seconds')}Z."},
            {"type": "TextBlock", "wrap": True, "isSubtle": True,
             "text": "Open the cockpit's Approvals tile to record the decision. "
                     "Teams Workflows webhooks cannot deliver an in-card Approve/Deny."},
            {"type": "FactSet", "facts": [
                {"title": "Action",     "value": action},
                {"title": "Args",       "value": json.dumps(args)[:200]},
                {"title": "Fingerprint","value": fp[:12] + "…"},
            ]},
        ],
        "actions": [
            {"type": "Action.OpenUrl", "title": "Approve / Deny in cockpit",
             "url": APPROVAL_UI_URL},
        ],
    }
    return _json({
        "fingerprint":   fp,
        "expires_at":    expires_at.isoformat() + "Z",
        "ttl_min":       APPROVAL_TTL_MIN,
        "adaptive_card": card,
    })


@app.function_name("approvals_decide")
@app.route(route="approvals/decide", methods=["POST"])
def approvals_decide(req: func.HttpRequest) -> func.HttpResponse:
    """Teams Action.Submit callback. Fail-closed.

    An approval is only 'yes' if it is explicit, fingerprint-matched,
    unexpired, and unused. Everything else — timeout, error, malformed
    reply, missing gate — is a no. Silence never reads as consent.

    Request (from the Adaptive Card):
      { "fingerprint": "<64 hex>", "decision": "granted" | "denied",
        "actor": "<upn>" }
    Response:
      { "status": "recorded" | "rejected", "reason": "<if rejected>",
        "final_decision": "granted" | "denied" | "expired" | "reused" | ... }
    """
    payload = _read_json(req)
    fp = str(payload.get("fingerprint") or "").strip()
    decision = str(payload.get("decision") or "").strip().lower()
    actor = str(payload.get("actor") or "")[:128] or None
    if not fp or decision not in ("granted", "denied"):
        return _json({"status": "rejected", "reason": "bad fingerprint or decision",
                      "final_decision": "invalid"}, status=400)

    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT decision, expires_at, used_at FROM dbo.approvals "
                "WHERE fingerprint = %s",
                (fp,),
            )
            row = cur.fetchone()
            if row is None:
                return _json({"status": "rejected", "reason": "unknown fingerprint",
                              "final_decision": "invalid"}, status=404)
            existing_decision, expires_at, used_at = row
            if used_at is not None:
                return _json({"status": "rejected", "reason": "already used",
                              "final_decision": "reused"}, status=409)
            if expires_at < dt.datetime.utcnow():
                return _json({"status": "rejected", "reason": "expired",
                              "final_decision": "expired"}, status=410)
            if existing_decision != "pending":
                return _json({"status": "rejected", "reason": f"already {existing_decision}",
                              "final_decision": existing_decision}, status=409)

            cur.execute(
                "UPDATE dbo.approvals "
                "SET decision = %s, decided_at = SYSUTCDATETIME(), actor = %s "
                "WHERE fingerprint = %s",
                (decision, actor, fp),
            )
            conn.commit()
        return _json({"status": "recorded", "final_decision": decision})
    except Exception as exc:
        logging.exception("approvals_decide failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("approvals_status")
@app.route(route="approvals/status", methods=["POST"])
def approvals_status(req: func.HttpRequest) -> func.HttpResponse:
    """Poll endpoint for Triage while it waits on a human.

    Marks the row 'used' the first time we return a definitive answer,
    so a later re-poll cannot re-consume the same approval to dispatch a
    second remediation. This is the "denial must not consume the budget"
    invariant applied to the approval lifecycle: once you get the yes,
    you get exactly one dispatch.

    Request:  { "fingerprint": "<64 hex>" }
    Response: { "decision": "pending" | "granted" | "denied" | "expired",
                "actor": "<upn or null>", "expires_at": "<ISO>" }
    """
    payload = _read_json(req)
    fp = str(payload.get("fingerprint") or "").strip()
    if not fp:
        return _json({"status": "failed", "error": "fingerprint required"}, status=400)
    try:
        with sql_connect() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT decision, expires_at, decided_at, actor, used_at "
                "FROM dbo.approvals WHERE fingerprint = %s",
                (fp,),
            )
            row = cur.fetchone()
            if row is None:
                return _json({"decision": "unknown"}, status=404)
            dec, expires_at, decided_at, actor, used_at = row
            if dec == "pending" and expires_at < dt.datetime.utcnow():
                cur.execute(
                    "UPDATE dbo.approvals SET decision = 'expired' "
                    "WHERE fingerprint = %s AND decision = 'pending'",
                    (fp,),
                )
                conn.commit()
                dec = "expired"
            # Mark used on the first definitive read of granted/denied.
            if dec in ("granted", "denied") and used_at is None:
                cur.execute(
                    "UPDATE dbo.approvals SET used_at = SYSUTCDATETIME() "
                    "WHERE fingerprint = %s AND used_at IS NULL",
                    (fp,),
                )
                conn.commit()
        return _json({
            "decision":    dec,
            "actor":       actor,
            "decided_at":  decided_at.isoformat() + "Z" if decided_at else None,
            "expires_at":  expires_at.isoformat() + "Z" if expires_at else None,
        })
    except Exception as exc:
        logging.exception("approvals_status failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


# =========================================================================
# Cockpit tile sources for the new tables + admin/migrate.
# =========================================================================

@app.function_name("demo_migrate")
@app.route(route="demo/migrate", methods=["POST"])
def demo_migrate(req: func.HttpRequest) -> func.HttpResponse:
    """Run migration_001.sql (additive; safe on any DB from any prior seed)."""
    try:
        return _json(_run_script("migration_001.sql"))
    except Exception as exc:
        logging.exception("demo_migrate failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_inbox_audit")
@app.route(route="demo/inbox_audit", methods=["POST"])
def demo_inbox_audit(req: func.HttpRequest) -> func.HttpResponse:
    """Return the last N rejected inbox mails (Todo #1). Powers a cockpit tile."""
    payload = _read_json(req)
    try:
        top = int(payload.get("top") or 25)
    except (TypeError, ValueError):
        top = 25
    top = max(1, min(top, 100))
    try:
        rows = _select_all(
            f"SELECT TOP ({top}) audit_id, message_id, received_at, subject, "
            f"sender, reason, pattern_used, seen_at "
            f"FROM dbo.inbox_audit ORDER BY audit_id DESC"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("demo_inbox_audit failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_approvals")
@app.route(route="demo/approvals", methods=["POST"])
def demo_approvals(req: func.HttpRequest) -> func.HttpResponse:
    """Return recent approval records for the cockpit Approvals tile."""
    payload = _read_json(req)
    try:
        top = int(payload.get("top") or 10)
    except (TypeError, ValueError):
        top = 10
    top = max(1, min(top, 50))
    try:
        rows = _select_all(
            f"SELECT TOP ({top}) fingerprint, run_id, action, "
            f"requested_at, expires_at, decision, decided_at, actor, used_at "
            f"FROM dbo.approvals ORDER BY requested_at DESC"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("demo_approvals failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)


@app.function_name("demo_prompt_versions")
@app.route(route="demo/prompt_versions", methods=["POST"])
def demo_prompt_versions(req: func.HttpRequest) -> func.HttpResponse:
    """Latest deployed prompt hashes per agent (Todo #3)."""
    try:
        rows = _select_all(
            "SELECT version_id, agent, prompt_hash, instructions_len, "
            "deployed_at, deployed_by "
            "FROM dbo.prompt_versions ORDER BY version_id DESC"
        )
        return _json({"rows": rows, "count": len(rows), "checked_at": _now_iso()})
    except Exception as exc:
        logging.exception("demo_prompt_versions failed")
        return _json({"status": "failed", "error": f"{type(exc).__name__}: {exc}"}, status=500)