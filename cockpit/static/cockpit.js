/* Demo Cockpit — architecture-canvas front-end.
 *
 * Every ~2s: fetch /api/heartbeat, /api/events, /api/data.
 * From heartbeat -> render countdown.
 * From events   -> render architecture canvas node states + right-column feed.
 * From data     -> render 4 SQL tables at the bottom.
 */

// -------------------- config / constants --------------------

const POLL_MS = 2000;

// Ordered list of every stage Triage/DQ can log — the feed shows them in
// arrival order. Poller heartbeat (`poll_tick`) is filtered out here AND
// server-side.
const STAGE_LABELS = {
    email_received:      "Email received",
    incident_opened:     "Incident opened",
    duplicate_suppressed:"Duplicate suppressed",
    action_refused:      "Action refused",
    playbook_retrieved:  "Playbook retrieved",
    dq_delegated:        "DQ delegated",
    dq_verdict:          "DQ verdict",
    tier1_classified:    "Tier-1 classified",
    policy_denied:       "Policy denied",
    refresh_triggered:   "Refresh triggered",
    dq_flagged:          "Duplicates flagged",
    approval_requested:  "Approval requested",
    approval_granted:    "Approval granted",
    approval_denied:     "Approval denied",
    model_contradicted:  "Model contradicted",
    incident_closed:     "Incident closed",
    escalated:           "Escalated",
    teams_posted:        "Teams posted",
    poll_tick:           "Mailbox poll",
};

// Stage -> Mermaid node id + state to apply when that stage lands.
// state: "active" | "ok" | "error" | "refused"
const STAGE_TO_NODE = {
    email_received:       { node: "Inbox",       state: "ok"      },
    incident_opened:      { node: "Incidents",   state: "ok"      },
    duplicate_suppressed: { node: "Incidents",   state: "refused" },
    playbook_retrieved:   { node: "Triage",      state: "active"  },
    dq_delegated:         { node: "Triage",      state: "active"  },
    dq_verdict:           { node: "DQ",          state: "ok"      },  // overridden to error if status=error
    tier1_classified:     { node: "Triage",      state: "ok"      },
    policy_denied:        { node: "Policy",      state: "refused" },
    action_refused:       { node: "Policy",      state: "refused" },
    refresh_triggered:    { node: "PBI",         state: "ok"      },
    dq_flagged:           { node: "SQL",         state: "ok"      },
    approval_requested:   { node: "Teams",       state: "active"  },
    approval_granted:     { node: "Policy",      state: "ok"      },
    approval_denied:      { node: "Policy",      state: "refused" },
    model_contradicted:   { node: "DQ",          state: "refused" },
    incident_closed:      { node: "Incidents",   state: "ok"      },  // overridden to error if downgraded
    escalated:            { node: "Teams",       state: "error"   },
    teams_posted:         { node: "Teams",       state: "ok"      },
};

// PBI workspace + dataset targets. Real values come from /api/config at
// init time (populated by cockpit/.env → PBI_WORKSPACE_ID / PBI_DATASET_ID).
// Placeholder GUIDs here just keep the objects well-formed pre-init.
const PBI_PLACEHOLDER = "00000000-0000-0000-0000-000000000000";

// Copy-pasteable email templates. Each renders as a collapsible card in the
// left panel. Body must include a JSON block the poller's parser can extract
// (needs source_table + key_column at minimum).
const EMAIL_TEMPLATES = [
    {
        id: "clean",
        tag: "S1",
        tagClass: "",
        title: "Transient failure",
        desc: "Refresh failed with a transient error. Data is clean → agent retries via PBI REST.",
        subject: "[BI-DEMO] Daily Orders refresh failed",
        payload: {
            report: "Daily Orders",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "Refresh failed (simulated transient error)",
            source_table: "dbo.source_orders",
            key_column: "line_id",
        },
    },
    {
        id: "duplicates",
        tag: "S2",
        tagClass: "",
        title: "Data-quality failure",
        desc: "Refresh failed. DQ finds duplicates on order_id → agent writes flag, does not retry.",
        subject: "[BI-DEMO] Daily Orders refresh failed (DQ warning)",
        payload: {
            report: "Daily Orders",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "Refresh failed: duplicate rows detected on primary key",
            source_table: "dbo.source_orders",
            key_column: "order_id",
        },
    },
    {
        id: "known_issue",
        tag: "S2b",
        tagClass: "new",
        title: "Known issue (send twice)",
        desc: "Send this email twice within a few minutes. The second is suppressed by signature.",
        subject: "[BI-DEMO] Daily Orders refresh failed",
        payload: {
            report: "Daily Orders",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "Refresh failed (simulated transient error)",
            source_table: "dbo.source_orders",
            key_column: "line_id",
            simulate_refresh: true,
        },
    },
    {
        id: "policy_block",
        tag: "S3",
        tagClass: "new",
        title: "Policy budget refuses second refresh",
        desc: "Payload includes force_second_refresh:true → agent attempts a second refresh → controller refuses.",
        subject: "[BI-DEMO] Sales Ops Overview refresh failed",
        payload: {
            report: "Sales Ops Overview",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "The underlying connection was closed unexpectedly.",
            source_table: "dbo.source_orders",
            key_column: "line_id",
            force_second_refresh: true,
            simulate_refresh: true,
        },
    },
    {
        id: "approval_granted",
        tag: "S5",
        tagClass: "new",
        title: "Human approval — granted",
        desc: "DQ finds duplicates. request_bigger_fix:true → agent asks for approval → click Approve on the Adaptive Card in Teams (or in the Approvals tile below).",
        subject: "[BI-DEMO] Orders Fact repeat duplicates",
        payload: {
            report: "Orders Fact",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "Persistent duplicate rows on order_id; auto-flag did not clear",
            source_table: "dbo.source_orders",
            key_column: "order_id",
            request_bigger_fix: true,
        },
    },
    {
        id: "approval_denied",
        tag: "S6",
        tagClass: "new",
        title: "Human approval — denied",
        desc: "Same setup as S5, but click Deny on the Adaptive Card. Nothing is dispatched — the correct ending.",
        subject: "[BI-DEMO] Orders Fact repeat duplicates",
        payload: {
            report: "Orders Fact",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "Persistent duplicate rows on order_id; auto-flag did not clear",
            source_table: "dbo.source_orders",
            key_column: "order_id",
            request_bigger_fix: true,
        },
    },
    {
        id: "fail",
        tag: "F",
        tagClass: "fail",
        title: "Deliberate failure",
        desc: "Source table doesn't exist → DQ SQL blows up → error surfaces in trace + Teams.",
        subject: "[BI-DEMO] Weekly Revenue refresh failed",
        payload: {
            report: "Weekly Revenue",
            workspace_id: PBI_PLACEHOLDER,
            dataset_id:   PBI_PLACEHOLDER,
            error: "Dataset refresh failed",
            source_table: "dbo.nonexistent_widgets",
            key_column: "widget_id",
        },
    },
];

function applyPbiIds(workspaceId, datasetId) {
    if (!workspaceId || !datasetId) return;
    for (const t of EMAIL_TEMPLATES) {
        t.payload.workspace_id = workspaceId;
        t.payload.dataset_id   = datasetId;
    }
}

// -------------------- state --------------------

let lastCanvasKey = null;
let lastPollAt = null;   // ISO string from /api/heartbeat.last_poll_at
let pollIntervalSec = 30;
let seenEventIds = new Set();

// Per-tile DOM cache. Every poll re-computes the rendered HTML strings for
// each tile, but assigning `.innerHTML = same_string` still tears down and
// rebuilds child nodes — which the browser paints as a visible flash on
// every 2s poll cycle. We hash the rendered string per tile and skip the
// assignment when it hasn't changed.
const lastRendered = {};
function setInnerHTMLIfChanged(el, html, key) {
    if (!el) return;
    if (lastRendered[key] === html) return;   // no change — skip repaint
    el.innerHTML = html;
    lastRendered[key] = html;
}

// -------------------- init --------------------

async function init() {
    try {
        const cfg = await fetch("/api/config").then(r => r.json());
        applyPbiIds(cfg.pbi_workspace_id, cfg.pbi_dataset_id);
        document.getElementById("foot-info").textContent =
            `mailbox ${cfg.mailbox_upn || "(unset)"} · function ${cfg.function_url || "(unset)"}`;
    } catch (e) {
        console.warn("config fetch failed", e);
    }

    mermaid.initialize({
        startOnLoad: false,
        theme: "dark",
        themeVariables: {
            primaryColor: "#161b22",
            primaryTextColor: "#e6edf3",
            primaryBorderColor: "#30363d",
            lineColor: "#8b949e",
            fontFamily: "Segoe UI, sans-serif",
            fontSize: "15px",
        },
        flowchart: {
            curve: "basis",
            htmlLabels: true,
            padding: 20,
            nodeSpacing: 55,
            rankSpacing: 75,
            useMaxWidth: false,
        },
    });

    renderEmailCards();
    document.getElementById("reset-btn").addEventListener("click", onReset);
    document.getElementById("playbook-btn").addEventListener("click", onPlaybookLookup);
    document.getElementById("playbook-input").addEventListener("keydown", (e) => {
        if (e.key === "Enter") onPlaybookLookup();
    });

    startClock();
    startCountdown();
    poll();
    setInterval(poll, POLL_MS);
}

function startClock() {
    const el = document.getElementById("clock");
    setInterval(() => { el.textContent = new Date().toLocaleTimeString(); }, 1000);
}

// -------------------- countdown --------------------

function startCountdown() {
    // Client-side tick — independent of poll cycle so the number moves smoothly.
    setInterval(renderCountdown, 250);
}

function renderCountdown() {
    const valEl = document.getElementById("countdown-value");
    const noteEl = document.getElementById("countdown-note");
    if (!lastPollAt) {
        valEl.innerHTML = `--<span class="unit">s</span>`;
        valEl.classList.remove("polling");
        return;
    }
    const elapsed = (Date.now() - Date.parse(lastPollAt)) / 1000;
    const remaining = Math.max(0, pollIntervalSec - elapsed);
    if (remaining < 1.5) {
        valEl.innerHTML = `Polling…`;
        valEl.classList.add("polling");
    } else {
        valEl.innerHTML = `${Math.ceil(remaining)}<span class="unit">s</span>`;
        valEl.classList.remove("polling");
    }
    noteEl.textContent = `last poll ${new Date(lastPollAt).toLocaleTimeString([], {hour12:false})}`;
}

// -------------------- reset --------------------

// Global handle so subsequent clicks can cancel an in-flight reset.
let activeResetController = null;
let activeResetTicker    = null;

async function onReset() {
    const btn = document.getElementById("reset-btn");
    const status = document.getElementById("status");

    // Second click while reset is running == "cancel please".
    if (activeResetController) {
        console.warn("[reset] second click — aborting in-flight reset");
        activeResetController.abort();
        clearInterval(activeResetTicker);
        activeResetController = null;
        activeResetTicker = null;
        btn.disabled = false;
        btn.textContent = "Reset";
        status.textContent = "reset cancelled";
        status.className = "status err";
        return;
    }

    if (!confirm("Truncate demo_events + dq_flags + incidents + policy_ledger + inbox_audit + approvals?\n(source_orders and heartbeat are preserved.)")) return;
    const originalStatus = status.textContent;
    const t0 = performance.now();

    console.groupCollapsed(`[reset] click at ${new Date().toISOString()}`);
    console.log("[reset] step 1/3: locking UI");
    btn.disabled = false;      // stay clickable so second click can cancel
    btn.title = "click again to cancel";

    let ticks = 0;
    activeResetTicker = setInterval(() => {
        ticks += 1;
        btn.textContent = `resetting ${ticks}s (click to cancel)`;
        status.textContent = `resetting ${ticks}s…`;
        if (ticks === 5)   console.log("[reset] still working (5s)…");
        if (ticks === 15)  console.warn("[reset] 15s — direct curl to /api/demo/cleanup returns in <1s. Uvicorn may be stuck.");
        if (ticks === 30)  console.error("[reset] 30s — check the uvicorn terminal. Restart it if there are no [reset] logs there.");
    }, 1000);
    btn.textContent = "resetting 0s (click to cancel)";
    status.textContent = "resetting 0s…";
    status.className = "status";

    // 60s cap — anything past that and the operator should restart uvicorn.
    activeResetController = new AbortController();
    const timeoutId = setTimeout(() => {
        console.warn("[reset] 60s hard timeout hit — aborting fetch");
        if (activeResetController) activeResetController.abort();
    }, 60_000);

    try {
        console.log("[reset] step 2/3: POST /api/reset (up to 60s)");
        const fetchStart = performance.now();
        const r = await fetch("/api/reset", {
            method: "POST",
            signal: activeResetController.signal,
        });
        const fetchMs = Math.round(performance.now() - fetchStart);
        console.log(`[reset] step 2/3 done: HTTP ${r.status} in ${fetchMs}ms`);

        const text = await r.text();
        if (!r.ok) throw new Error(`HTTP ${r.status}: ${text.slice(0, 200)}`);
        console.log("[reset] server payload:", text);

        console.log("[reset] step 3/3: clearing rendered tables + feed");
        seenEventIds.clear();
        lastCanvasKey = null;
        for (const id of [
            "orders-table","flags-table","incidents-table","policy-table",
            "approvals-table","inbox-audit-table","prompt-versions-table",
        ]) {
            const tb = document.querySelector(`#${id} tbody`);
            if (tb) tb.innerHTML = "";
        }
        const feedList = document.getElementById("feed-list");
        if (feedList) feedList.innerHTML = "";
        // NOTE: intentionally NOT calling poll() here — the regular 2s
        // interval will repaint on its own. Calling poll() inline can
        // itself hang if one of the six proxied endpoints stalls, and
        // that would look like the reset is stuck.

        const totalMs = Math.round(performance.now() - t0);
        status.textContent = `reset ok (${(totalMs/1000).toFixed(2)}s)`;
        status.className = "status ok";
        console.log(`[reset] ✅ complete in ${totalMs}ms`);
    } catch (e) {
        const totalMs = Math.round(performance.now() - t0);
        const msg = e.name === "AbortError"
            ? `aborted after ${(totalMs/1000).toFixed(1)}s`
            : e.message;
        console.error(`[reset] ❌ FAILED after ${totalMs}ms:`, msg);
        status.textContent = "reset failed: " + msg;
        status.className = "status err";
        alert(
            "Reset failed: " + msg +
            "\n\nRecovery:\n" +
            "  1. Check the uvicorn terminal for [reset] lines.\n" +
            "  2. If nothing appears, uvicorn is stuck — Ctrl+C and restart it.\n" +
            "  3. If lines appear but no ✅, the Function App is stuck — restart it in the portal."
        );
    } finally {
        clearInterval(activeResetTicker);
        clearTimeout(timeoutId);
        activeResetTicker = null;
        activeResetController = null;
        btn.disabled = false;
        btn.textContent = "Reset";
        btn.title = "";
        console.groupEnd();
        setTimeout(() => {
            if (status.textContent.startsWith("reset")) {
                status.textContent = originalStatus;
            }
        }, 5000);
    }
}

// -------------------- poll loop --------------------

async function poll() {
    const status = document.getElementById("status");
    try {
        const [heartbeat, events, data, approvals, inboxAudit, promptVersions] = await Promise.all([
            fetchJson("/api/heartbeat"),
            fetchJson("/api/events"),
            fetchJson("/api/data"),
            fetchJson("/api/approvals"),
            fetchJson("/api/inbox_audit"),
            fetchJson("/api/prompt_versions"),
        ]);
        if (heartbeat) {
            lastPollAt = heartbeat.last_poll_at;
            pollIntervalSec = heartbeat.poll_interval_sec || 30;
        }
        if (events) { renderCanvas(events); renderFeed(events); }
        if (data)   renderData(data);
        if (approvals)      renderApprovals(approvals);
        if (inboxAudit)     renderInboxAudit(inboxAudit);
        if (promptVersions) renderPromptVersions(promptVersions);

        const failed = [
            heartbeat      ? null : "heartbeat",
            events         ? null : "events",
            data           ? null : "data",
            approvals      ? null : "approvals",
            inboxAudit     ? null : "inbox_audit",
            promptVersions ? null : "prompt_versions",
        ].filter(Boolean);
        if (failed.length === 0) {
            status.textContent = "connected";
            status.className = "status ok";
        } else {
            status.textContent = "degraded: " + failed.join(", ");
            status.className = "status err";
        }
    } catch (e) {
        status.textContent = "error: " + e.message;
        status.className = "status err";
        console.error(e);
    }
}

async function fetchJson(path) {
    // 10s ceiling per poll request. If a proxied endpoint hangs (uvicorn
    // stuck, MI token acquisition slow, Function cold-starting) it cannot
    // wedge the poll loop or queue behind a reset click forever.
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);
    try {
        const r = await fetch(path, { signal: controller.signal });
        if (!r.ok) { console.warn(`${path} -> ${r.status}`); return null; }
        return await r.json();
    } catch (e) {
        if (e.name === "AbortError") {
            console.warn(`${path} aborted after 10s`);
        } else {
            console.warn(`${path} threw`, e);
        }
        return null;
    } finally {
        clearTimeout(timeout);
    }
}

// -------------------- email cards --------------------

function renderEmailCards() {
    const host = document.getElementById("email-cards");
    host.innerHTML = EMAIL_TEMPLATES.map(t => {
        const bodyText = emailBody(t);
        return `
        <details class="email-card">
            <summary>
                <span class="em-title">${escapeHtml(t.title)}</span>
                <span class="em-tag ${t.tagClass}">${escapeHtml(t.tag)}</span>
            </summary>
            <div class="em-desc">${escapeHtml(t.desc)}</div>
            <div class="em-field">
                <div class="em-label">
                    <span>Subject</span>
                    <button class="copy-btn" data-copy="${escapeAttr(t.subject)}">Copy</button>
                </div>
                <pre>${escapeHtml(t.subject)}</pre>
            </div>
            <div class="em-field">
                <div class="em-label">
                    <span>Body</span>
                    <button class="copy-btn" data-copy="${escapeAttr(bodyText)}">Copy</button>
                </div>
                <pre>${escapeHtml(bodyText)}</pre>
            </div>
        </details>`;
    }).join("");
    host.querySelectorAll(".copy-btn").forEach(b =>
        b.addEventListener("click", (e) => onCopy(e.currentTarget)));
}

function emailBody(t) {
    const json = JSON.stringify(t.payload, null, 2);
    return (
        `Simulated Power BI refresh failure — please triage.\n\n` +
        `${json}\n\n` +
        `— BI Ops (demo)`
    );
}

async function onCopy(btn) {
    const text = btn.getAttribute("data-copy");
    try {
        await navigator.clipboard.writeText(text);
        btn.textContent = "Copied!";
        btn.classList.add("copied");
        setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1400);
    } catch (e) {
        alert("Clipboard failed: " + e.message);
    }
}

// -------------------- canvas --------------------

function renderCanvas({ runs = [] }) {
    const hint = document.getElementById("canvas-hint");
    // Determine node states from the LATEST run only. The canvas shows what
    // just happened, not history. History lives in the event feed.
    const latest = runs[0];
    const nodeState = {
        Inbox: "idle", Triage: "idle", DQ: "idle",
        Incidents: "idle", Policy: "idle",
        SQL: "idle", PBI: "idle", Teams: "idle",
    };

    let scenarioLabel = "idle";
    let runComplete = false;
    let terminalOutcome = null;
    if (latest) {
        for (const stage of latest.stages) {
            const map = STAGE_TO_NODE[stage.stage];
            if (!map) continue;
            let s = map.state;
            // dq_verdict flips to error when the verdict itself failed.
            if (stage.stage === "dq_verdict" && /verdict=(error|failed)/i.test(stage.detail || "")) {
                s = "error";
            }
            nodeState[map.node] = s;
            if (stage.stage === "incident_closed") {
                runComplete = true;
                const m = /final=([a-z_]+)/i.exec(stage.detail || "");
                if (m) terminalOutcome = m[1];
            }
        }
        // Triage always runs on every email — light it green if the run has
        // reached any post-triage stage successfully, or red if anything failed.
        const stages = latest.stages.map(s => s.stage);
        const hadError = latest.stages.some(s => s.status === "error" || s.status === "failed");
        if (hadError) {
            nodeState.Triage = "error";
        } else if (stages.length > 0) {
            nodeState.Triage = "ok";
        }

        // Terminal-state inference: after incident_closed, the agent's
        // contract requires it to have called post_teams_message. Force
        // Teams=ok even if the agent's follow-up log_event didn't land
        // (LLMs occasionally drop the last bookkeeping call).
        if (runComplete && nodeState.Teams === "idle") {
            nodeState.Teams = "ok";
        }

        // Mark the LATEST stage's node as "active" so the presenter can see
        // which step is currently executing. Only meaningful mid-run.
        if (!runComplete && latest.stages.length > 0) {
            const lastStage = latest.stages[latest.stages.length - 1];
            const map = STAGE_TO_NODE[lastStage.stage];
            if (map && nodeState[map.node] === "ok") {
                nodeState[map.node] = "active";
            }
        }

        const runShort = latest.run_id.slice(0, 8);
        if (runComplete) {
            scenarioLabel = `✓ COMPLETED · ${terminalOutcome || "done"} · run ${runShort}`;
        } else {
            const lastStageName = latest.stages.length
                ? latest.stages[latest.stages.length - 1].stage
                : "starting";
            scenarioLabel = `▶ ACTIVE · ${lastStageName} · run ${runShort}`;
        }
    }
    hint.textContent = scenarioLabel;

    // Build a stable key so we skip re-rendering identical Mermaid.
    const key = Object.entries(nodeState).map(([k, v]) => `${k}=${v}`).join("|");
    if (key === lastCanvasKey) return;
    lastCanvasKey = key;

    const src = buildMermaid(nodeState);
    const container = document.getElementById("canvas-container");
    container.innerHTML = `<div class="mermaid">${src}</div>`;
    try {
        mermaid.run({ nodes: container.querySelectorAll(".mermaid") })
            .then(() => {
                // Strip Mermaid's inline sizing so the SVG scales to the
                // container via viewBox + preserveAspectRatio.
                const svg = container.querySelector("svg");
                if (svg) {
                    svg.removeAttribute("width");
                    svg.removeAttribute("height");
                    svg.removeAttribute("style");
                    svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
                }
                highlightActiveNodes(container);
            })
            .catch(err => {
                console.error("Mermaid render failed:", err);
                console.log("---- Mermaid source ----\n" + src);
            });
    } catch (e) {
        console.error("mermaid.run threw synchronously:", e);
        console.log("---- Mermaid source ----\n" + src);
    }
}

function buildMermaid(nodeState) {
    // Use inline `:::` class assignment (safer than trailing `class NodeName cls`
    // in Mermaid v10). Drop <br/> — quoted labels don't parse HTML.
    const S = (n) => `state_${nodeState[n]}`;
    return `flowchart LR
    Inbox["Inbox"]:::${S("Inbox")}
    Poller["Poller"]:::state_idle
    Triage["Triage Agent"]:::${S("Triage")}
    DQ["DQ Agent"]:::${S("DQ")}
    Incidents[("incidents")]:::${S("Incidents")}
    Policy[("policy_ledger")]:::${S("Policy")}
    SQL[("dq_flags")]:::${S("SQL")}
    PBI["Power BI REST"]:::${S("PBI")}
    Teams["Teams"]:::${S("Teams")}

    Inbox --> Poller --> Triage
    Triage --> Incidents
    Triage --> DQ
    Triage --> Policy
    DQ --> SQL
    Triage --> PBI
    Triage --> Teams

    classDef state_idle fill:#1c2129,stroke:#6e7681,color:#8b949e,stroke-width:1.5px
    classDef state_active fill:#3a2d10,stroke:#d29922,color:#d29922,stroke-width:3px
    classDef state_ok fill:#0d2818,stroke:#3fb950,color:#3fb950,stroke-width:2px
    classDef state_error fill:#2d0d0d,stroke:#f85149,color:#f85149,stroke-width:2px
    classDef state_refused fill:#1c2129,stroke:#f85149,color:#f85149,stroke-width:2px,stroke-dasharray:6 4
`;
}

// Add a CSS pulse animation to the currently-active node after mermaid renders.
function highlightActiveNodes(container) {
    const svg = container.querySelector("svg");
    if (!svg) return;
    // Mermaid tags each node's <g> with class names matching classDef selectors.
    svg.querySelectorAll("g.node").forEach(g => {
        const isActive = Array.from(g.classList).some(c => c.includes("state_active"));
        if (isActive) {
            g.classList.add("pulse-active");
        }
    });
}

// -------------------- event feed --------------------

function renderFeed({ runs = [] }) {
    const hint = document.getElementById("feed-hint");
    const list = document.getElementById("feed-list");

    if (!runs.length) {
        hint.textContent = "waiting for first run";
        setInnerHTMLIfChanged(list,
            `<li style="color:var(--fg-faint);border:none;">no events yet — send a [BI-DEMO] email</li>`,
            "feed");
        return;
    }
    hint.textContent = `${runs.length} recent run${runs.length === 1 ? "" : "s"}`;

    // Flatten runs into a single time-ordered list (newest first). Skip poll_tick.
    const rows = [];
    runs.forEach((run, runIdx) => {
        const cls = ["run-a", "run-b", "run-c"][runIdx % 3];
        run.stages.forEach(s => {
            if (s.stage === "poll_tick") return;
            rows.push({
                run_id: run.run_id,
                scenario: run.scenario,
                stage: s.stage,
                status: s.status,
                detail: s.detail || "",
                at: s.at,
                runCls: cls,
            });
        });
    });
    rows.sort((a, b) => (b.at || "").localeCompare(a.at || ""));

    const html = rows.map(r => {
        const sniff = /verdict=(error|failed)/i.test(r.detail) && r.status === "ok" ? "error" : r.status;
        const glyph = sniff === "ok" ? "✓" : sniff === "info" ? "•" : sniff === "error" || sniff === "failed" ? "✗" : "…";
        const eid = `${r.run_id}|${r.stage}|${r.at}`;
        const isNew = !seenEventIds.has(eid);
        seenEventIds.add(eid);
        return `<li class="${sniff} ${r.runCls} ${isNew ? "new" : ""}">
            <span class="t">${fmtTime(r.at)}</span>
            <span class="st"><span class="stage">${escapeHtml(STAGE_LABELS[r.stage] || r.stage)}</span><span class="detail">${escapeHtml(r.detail)}</span></span>
            <span class="ic">${glyph}</span>
        </li>`;
    }).join("");
    setInnerHTMLIfChanged(list, html, "feed");
}

// -------------------- state tables --------------------

function renderData({ source_orders = [], dq_flags = [], incidents = [], policy_ledger = [] }) {
    document.getElementById("orders-count").textContent    = source_orders.length;
    document.getElementById("flags-count").textContent     = dq_flags.length;
    document.getElementById("incidents-count").textContent = incidents.length;
    document.getElementById("policy-count").textContent    = policy_ledger.length;

    const dupIds = new Set();
    const seen = new Set();
    for (const r of source_orders) {
        if (seen.has(r.order_id)) dupIds.add(r.order_id);
        seen.add(r.order_id);
    }

    setInnerHTMLIfChanged(document.querySelector("#orders-table tbody"),
        source_orders.map(r => `
        <tr class="${dupIds.has(r.order_id) ? "dup" : ""}">
            <td>${r.line_id ?? ""}</td>
            <td>${escapeHtml(r.order_id || "")}</td>
            <td>${escapeHtml(r.customer_id || "")}</td>
            <td>${r.order_date || ""}</td>
            <td>${r.amount ?? ""}</td>
            <td>${escapeHtml(r.region || "")}</td>
        </tr>
    `).join(""), "orders");

    setInnerHTMLIfChanged(document.querySelector("#flags-table tbody"),
        (dq_flags.map(f => `
        <tr>
            <td>${f.flag_id}</td>
            <td>${escapeHtml(f.key_columns || "")}</td>
            <td>${escapeHtml(f.key_value || "")}</td>
            <td>${f.dup_count}</td>
            <td>${fmtTime(f.detected_at)}</td>
        </tr>`).join("") || emptyRow(5)), "flags");

    setInnerHTMLIfChanged(document.querySelector("#incidents-table tbody"),
        (incidents.map(i => {
        const outcome = i.terminal_outcome || "";
        const outcomeCls = outcome === "resolved" ? "outcome-ok" :
                           outcome === "needs_human" ? "outcome-warn" :
                           outcome ? "outcome-info" : "";
        const outcomeCell = outcome
            ? `<span class="pill ${outcomeCls}" title="${escapeAttr(i.terminal_reason || "")}">${escapeHtml(outcome)}</span>`
            : `<span class="muted">open</span>`;
        return `<tr class="${(i.occurrence_count || 0) > 1 ? "dup" : ""}">
            <td title="${escapeHtml(i.error_class || "")}">${escapeHtml((i.signature || "").slice(0, 8))}…</td>
            <td>${escapeHtml(i.report || "")}</td>
            <td>${i.occurrence_count ?? ""}</td>
            <td>${outcomeCell}</td>
            <td>${fmtTime(i.last_seen_at)}</td>
        </tr>`;
    }).join("") || emptyRow(5)), "incidents");

    setInnerHTMLIfChanged(document.querySelector("#policy-table tbody"),
        (policy_ledger.map(p => {
        const allowed = p.allowed === true || p.allowed === 1;
        return `<tr class="${allowed ? "" : "policy-deny"}">
            <td>${p.ledger_id}</td>
            <td>${escapeHtml(p.action || "")}</td>
            <td>${allowed ? "allow" : "deny"}</td>
            <td>${escapeHtml(p.deny_reason || "")}</td>
        </tr>`;
    }).join("") || emptyRow(4)), "policy");
}

function emptyRow(cols) {
    return `<tr><td colspan="${cols}" style="color:var(--fg-faint);text-align:center;padding:12px 0;">empty</td></tr>`;
}

// -------------------- safety-rail tiles --------------------

function renderApprovals({ rows = [] }) {
    document.getElementById("approvals-count").textContent = rows.length;
    const tbody = document.querySelector("#approvals-table tbody");
    const html = rows.map(a => {
        const fp = String(a.fingerprint || "");
        const shortFp = fp.slice(0, 10) + "…";
        const runShort = (a.run_id || "").slice(0, 8);
        const pending = a.decision === "pending";
        const cls = a.decision === "granted" ? "outcome-ok" :
                    a.decision === "denied"  ? "outcome-warn" :
                    a.decision === "expired" ? "muted" : "outcome-info";
        const buttons = pending ? `
            <button class="btn tiny approve" data-fp="${escapeAttr(fp)}" data-decision="granted" title="Approve">✓</button>
            <button class="btn tiny deny"    data-fp="${escapeAttr(fp)}" data-decision="denied"  title="Deny">✗</button>
        ` : "";
        return `<tr>
            <td class="mono" title="${escapeAttr(fp)}">${escapeHtml(shortFp)}</td>
            <td class="mono">${escapeHtml(runShort)}</td>
            <td>${escapeHtml(a.action || "")}</td>
            <td><span class="pill ${cls}">${escapeHtml(a.decision || "")}</span></td>
            <td>${escapeHtml(a.actor || "")}</td>
            <td>${fmtTime(a.expires_at)}</td>
            <td class="approve-cell">${buttons}</td>
        </tr>`;
    }).join("") || emptyRow(7);

    if (html === lastRendered["approvals"]) return;  // skip repaint AND handler re-wire
    setInnerHTMLIfChanged(tbody, html, "approvals");

    // Wire click handlers only when content actually changed (otherwise the
    // handlers are already bound and re-adding them is wasted work).
    tbody.querySelectorAll(".approve, .deny").forEach(btn => {
        btn.addEventListener("click", async () => {
            const fp = btn.getAttribute("data-fp");
            const decision = btn.getAttribute("data-decision");
            btn.disabled = true;
            btn.textContent = "…";
            try {
                const r = await fetch("/api/approvals/decide", {
                    method: "POST",
                    headers: {"Content-Type": "application/json"},
                    body: JSON.stringify({
                        fingerprint: fp,
                        decision,
                        actor: "cockpit-user",
                    }),
                });
                if (!r.ok) console.warn("decide failed", await r.text());
            } catch (e) { console.warn(e); }
            // The next poll (≤2s) will refresh the row and swap the pill.
        });
    });
}

function renderInboxAudit({ rows = [] }) {
    document.getElementById("inbox-audit-count").textContent = rows.length;
    setInnerHTMLIfChanged(document.querySelector("#inbox-audit-table tbody"),
        (rows.map(r => `
        <tr>
            <td>${r.audit_id}</td>
            <td title="${escapeAttr(r.subject || "")}">${escapeHtml((r.subject || "").slice(0, 40))}</td>
            <td>${escapeHtml(r.sender || "")}</td>
            <td><span class="pill outcome-warn">${escapeHtml(r.reason || "")}</span></td>
            <td>${fmtTime(r.seen_at)}</td>
        </tr>`).join("") || emptyRow(5)), "inbox_audit");
}

function renderPromptVersions({ rows = [] }) {
    // Only show the latest per agent — the tile is about "what's live".
    const latestByAgent = new Map();
    for (const r of rows) {
        if (!latestByAgent.has(r.agent)) latestByAgent.set(r.agent, r);
    }
    const latest = [...latestByAgent.values()];
    document.getElementById("prompt-versions-count").textContent = latest.length;
    setInnerHTMLIfChanged(document.querySelector("#prompt-versions-table tbody"),
        (latest.map(v => `
        <tr>
            <td>${escapeHtml(v.agent || "")}</td>
            <td class="mono" title="${escapeAttr(v.prompt_hash || "")}">${escapeHtml((v.prompt_hash || "").slice(0, 10))}…</td>
            <td>${v.instructions_len ?? ""}</td>
            <td>${fmtTime(v.deployed_at)}</td>
            <td>${escapeHtml((v.deployed_by || "").split("@")[0])}</td>
        </tr>`).join("") || emptyRow(5)), "prompt_versions");
}

async function onPlaybookLookup() {
    const input = document.getElementById("playbook-input");
    const btn   = document.getElementById("playbook-btn");
    const tbody = document.querySelector("#playbook-table tbody");
    const badge = document.getElementById("playbook-count");
    const text  = input.value.trim();
    if (!text) return;
    btn.disabled = true; btn.textContent = "…";
    tbody.innerHTML = `<tr><td colspan="3" class="muted">looking up…</td></tr>`;
    try {
        const r = await fetch("/api/playbooks/lookup", {
            method: "POST",
            headers: {"Content-Type": "application/json"},
            body: JSON.stringify({ error_text: text }),
        });
        const j = await r.json();
        const hits = j.hits || [];
        badge.textContent = `${hits.length} hit${hits.length === 1 ? "" : "s"}`;
        tbody.innerHTML = hits.map(h => `
            <tr>
                <td class="mono">${escapeHtml(h.id || "")}</td>
                <td>${h.retry_useful ? `<span class="pill outcome-ok">retry</span>` : `<span class="pill outcome-warn">don't retry</span>`}</td>
                <td><a href="${escapeAttr(h.source_url || "#")}" target="_blank" title="${escapeAttr(h.summary || "")}">${escapeHtml(h.title || h.id || "")}</a></td>
            </tr>`).join("") || `<tr><td colspan="3" class="muted">no matches</td></tr>`;
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="3" class="muted">lookup failed: ${escapeHtml(e.message)}</td></tr>`;
    } finally {
        btn.disabled = false; btn.textContent = "Lookup";
    }
}

// -------------------- utilities --------------------

function fmtTime(iso) {
    if (!iso) return "";
    try { return new Date(iso).toLocaleTimeString([], { hour12: false }); }
    catch { return iso; }
}
function escapeHtml(s) {
    return String(s ?? "")
        .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
}
function escapeAttr(s) {
    return escapeHtml(s).replaceAll("'", "&#39;");
}

init();
