-- Idempotent seed for demo scenarios.
-- Scenario 1: key_column=line_id  → clean            → refresh path
-- Scenario 2: key_column=order_id → duplicates_found → flag path
IF OBJECT_ID('dbo.approvals', 'U') IS NOT NULL DROP TABLE dbo.approvals;
IF OBJECT_ID('dbo.prompt_versions', 'U') IS NOT NULL DROP TABLE dbo.prompt_versions;
IF OBJECT_ID('dbo.inbox_audit', 'U') IS NOT NULL DROP TABLE dbo.inbox_audit;
IF OBJECT_ID('dbo.policy_ledger', 'U') IS NOT NULL DROP TABLE dbo.policy_ledger;
IF OBJECT_ID('dbo.incidents', 'U') IS NOT NULL DROP TABLE dbo.incidents;
IF OBJECT_ID('dbo.demo_events', 'U') IS NOT NULL DROP TABLE dbo.demo_events;
IF OBJECT_ID('dbo.dq_flags', 'U') IS NOT NULL DROP TABLE dbo.dq_flags;
IF OBJECT_ID('dbo.source_orders', 'U') IS NOT NULL DROP TABLE dbo.source_orders;

CREATE TABLE dbo.source_orders (
    line_id      INT           NOT NULL,
    order_id     NVARCHAR(32)  NOT NULL,
    customer_id  NVARCHAR(32)  NOT NULL,
    order_date   DATE          NOT NULL,
    amount       DECIMAL(10,2) NOT NULL,
    region       NVARCHAR(16)  NOT NULL,
    loaded_at    DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.dq_flags (
    flag_id       INT IDENTITY(1,1) PRIMARY KEY,
    table_name    NVARCHAR(128) NOT NULL,
    key_columns   NVARCHAR(256) NOT NULL,
    key_value     NVARCHAR(256) NOT NULL,
    dup_count     INT           NOT NULL,
    detected_at   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    source_run_id NVARCHAR(64)  NULL
);

-- Demo Cockpit event log — Triage log_event tool writes one row per stage
-- so the cockpit can render the Agent Flow tile in real time.
CREATE TABLE dbo.demo_events (
    event_id    INT IDENTITY(1,1) PRIMARY KEY,
    run_id      NVARCHAR(64)   NOT NULL,
    scenario    NVARCHAR(32)   NULL,
    stage       NVARCHAR(32)   NOT NULL,
    status      NVARCHAR(16)   NOT NULL,
    detail      NVARCHAR(1000) NULL,
    trace_url   NVARCHAR(500)  NULL,
    agent       NVARCHAR(32)   NULL,        -- Todo #3: which agent logged this
    prompt_hash CHAR(16)       NULL,        -- Todo #3: prompt version at time of run
    created_at  DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_demo_events_run    ON dbo.demo_events (run_id, event_id);
CREATE INDEX IX_demo_events_recent ON dbo.demo_events (created_at DESC);

-- Incident dedup table — Scenario 2b (known issue suppression).
-- Signature is a 16-char SHA-256 prefix over the normalized error class,
-- computed by the Function App so the presenter can't fudge it. A second
-- alert with the same signature increments occurrence_count instead of
-- kicking off a second remediation.
CREATE TABLE dbo.incidents (
    signature        CHAR(16)      NOT NULL PRIMARY KEY,
    first_seen_at    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    last_seen_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    occurrence_count INT           NOT NULL DEFAULT 1,
    status           NVARCHAR(32)  NOT NULL DEFAULT 'open',
    report           NVARCHAR(128) NULL,
    source_table     NVARCHAR(128) NULL,
    key_column       NVARCHAR(128) NULL,
    error_class      NVARCHAR(500) NULL,
    source_run_id    NVARCHAR(64)  NULL,
    -- Todo #6 (outcome validation): reconciled terminal state.
    -- Set by /api/incidents/close, NOT by the agent's own claim.
    terminal_outcome NVARCHAR(32)  NULL,
    terminal_reason  NVARCHAR(500) NULL,
    closed_at        DATETIME2(3)  NULL
);
CREATE INDEX IX_incidents_last_seen ON dbo.incidents (last_seen_at DESC);

-- Todo #1: inbox_audit — every rejected mail. See migration_001.sql.
CREATE TABLE dbo.inbox_audit (
    audit_id      INT IDENTITY(1,1) PRIMARY KEY,
    message_id    NVARCHAR(256) NULL,
    received_at   DATETIME2(3)  NULL,
    subject       NVARCHAR(500) NULL,
    sender        NVARCHAR(256) NULL,
    reason        NVARCHAR(64)  NOT NULL,
    pattern_used  NVARCHAR(256) NULL,
    seen_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_inbox_audit_recent ON dbo.inbox_audit (seen_at DESC);

-- Todo #3: prompt_versions — SHA-256 prefix of each deployed prompt.
CREATE TABLE dbo.prompt_versions (
    version_id       INT IDENTITY(1,1) PRIMARY KEY,
    agent            NVARCHAR(64)  NOT NULL,
    prompt_hash      CHAR(16)      NOT NULL,
    instructions_len INT           NOT NULL,
    deployed_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deployed_by      NVARCHAR(128) NULL
);
CREATE INDEX IX_prompt_versions_agent
    ON dbo.prompt_versions (agent, deployed_at DESC);

-- Todo #7: approvals — fail-closed human-in-the-loop gate.
CREATE TABLE dbo.approvals (
    fingerprint   CHAR(64)      NOT NULL PRIMARY KEY,
    run_id        NVARCHAR(64)  NOT NULL,
    action        NVARCHAR(64)  NOT NULL,
    args_hash     CHAR(16)      NOT NULL,
    requested_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    expires_at    DATETIME2(3)  NOT NULL,
    decision      NVARCHAR(16)  NOT NULL DEFAULT 'pending',
    decided_at    DATETIME2(3)  NULL,
    actor         NVARCHAR(128) NULL,
    used_at       DATETIME2(3)  NULL,
    detail        NVARCHAR(500) NULL
);
CREATE INDEX IX_approvals_run     ON dbo.approvals (run_id);
CREATE INDEX IX_approvals_pending ON dbo.approvals (decision, expires_at);

-- Policy ledger — Scenarios 3 (budget) and 4 (allowlist).
-- One row per policy check. `allowed=1` means the remediation was authorized;
-- `allowed=0` means the controller refused, with `deny_reason` explaining why.
-- Scoped per run_id so budgets don't leak across scenarios.
CREATE TABLE dbo.policy_ledger (
    ledger_id    INT IDENTITY(1,1) PRIMARY KEY,
    run_id       NVARCHAR(64)   NOT NULL,
    action       NVARCHAR(64)   NOT NULL,
    allowed      BIT            NOT NULL,
    deny_reason  NVARCHAR(128)  NULL,
    detail       NVARCHAR(500)  NULL,
    charged_at   DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_policy_ledger_run    ON dbo.policy_ledger (run_id, ledger_id);
CREATE INDEX IX_policy_ledger_recent ON dbo.policy_ledger (charged_at DESC);

INSERT INTO dbo.source_orders(line_id, order_id, customer_id, order_date, amount, region) VALUES
 (1, 'O-1001','C-01','2026-08-01', 129.50,'NA'),
 (2, 'O-1002','C-02','2026-08-02',  42.00,'EU'),
 (3, 'O-1003','C-03','2026-08-02', 875.10,'NA'),
 (4, 'O-1004','C-01','2026-08-03',  59.99,'NA'),
 (5, 'O-1005','C-04','2026-08-04',1240.00,'APAC'),
 (6, 'O-1006','C-05','2026-08-05',  15.25,'EU'),
 (7, 'O-1007','C-06','2026-08-05', 320.00,'NA'),
 (8, 'O-1008','C-07','2026-08-06',  88.10,'APAC'),
 -- Scenario 2: duplicate order_id (O-1003 x3)
 (9, 'O-1003','C-03','2026-08-02', 875.10,'NA'),
 (10,'O-1003','C-08','2026-08-06', 875.10,'NA');

SELECT 'source_orders rows'   AS metric, COUNT(*) AS value FROM dbo.source_orders
UNION ALL SELECT 'dq_flags rows',        COUNT(*) FROM dbo.dq_flags
UNION ALL SELECT 'demo_events rows',     COUNT(*) FROM dbo.demo_events
UNION ALL SELECT 'incidents rows',       COUNT(*) FROM dbo.incidents
UNION ALL SELECT 'policy_ledger rows',   COUNT(*) FROM dbo.policy_ledger
UNION ALL SELECT 'inbox_audit rows',     COUNT(*) FROM dbo.inbox_audit
UNION ALL SELECT 'prompt_versions rows', COUNT(*) FROM dbo.prompt_versions
UNION ALL SELECT 'approvals rows',       COUNT(*) FROM dbo.approvals;
