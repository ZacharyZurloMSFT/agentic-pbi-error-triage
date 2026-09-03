-- reset.sql — fast, idempotent reset for demo re-runs (NFR: <1 min)
-- Safe to run repeatedly. Assumes schema from seed.sql already exists.
-- If tables are missing, bootstraps them; otherwise reuses in place.

SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Bootstrap batch (schema-only, no tran because ALTER TABLE ADD needs to end
-- the batch before subsequent statements can reference the new column).

-- Bootstrap if missing (first run on a fresh DB)
IF OBJECT_ID('dbo.source_orders', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.source_orders (
        line_id      INT           NOT NULL,
        order_id     NVARCHAR(32)  NOT NULL,
        customer_id  NVARCHAR(32)  NOT NULL,
        order_date   DATE          NOT NULL,
        amount       DECIMAL(10,2) NOT NULL,
        region       NVARCHAR(16)  NOT NULL,
        loaded_at    DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
    );
END;

-- Backfill line_id if the column doesn't exist yet (previous seed schema)
IF NOT EXISTS (
    SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.source_orders') AND name = 'line_id'
)
BEGIN
    ALTER TABLE dbo.source_orders ADD line_id INT NULL;
END;
GO

IF OBJECT_ID('dbo.dq_flags', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dq_flags (
        flag_id       INT IDENTITY(1,1) PRIMARY KEY,
        table_name    NVARCHAR(128) NOT NULL,
        key_columns   NVARCHAR(256) NOT NULL,
        key_value     NVARCHAR(256) NOT NULL,
        dup_count     INT           NOT NULL,
        detected_at   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
        source_run_id NVARCHAR(64)  NULL
    );
END;
GO

IF OBJECT_ID('dbo.demo_events', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.demo_events (
        event_id    INT IDENTITY(1,1) PRIMARY KEY,
        run_id      NVARCHAR(64)   NOT NULL,
        scenario    NVARCHAR(32)   NULL,
        stage       NVARCHAR(32)   NOT NULL,
        status      NVARCHAR(16)   NOT NULL,
        detail      NVARCHAR(1000) NULL,
        trace_url   NVARCHAR(500)  NULL,
        created_at  DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_demo_events_run    ON dbo.demo_events (run_id, event_id);
    CREATE INDEX IX_demo_events_recent ON dbo.demo_events (created_at DESC);
END;
GO

IF OBJECT_ID('dbo.incidents', 'U') IS NULL
BEGIN
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
        source_run_id    NVARCHAR(64)  NULL
    );
    CREATE INDEX IX_incidents_last_seen ON dbo.incidents (last_seen_at DESC);
END;
GO

IF OBJECT_ID('dbo.policy_ledger', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.policy_ledger (
        ledger_id   INT IDENTITY(1,1) PRIMARY KEY,
        run_id      NVARCHAR(64)   NOT NULL,
        action      NVARCHAR(64)   NOT NULL,
        allowed     BIT            NOT NULL,
        deny_reason NVARCHAR(128)  NULL,
        detail      NVARCHAR(500)  NULL,
        charged_at  DATETIME2(3)   NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_policy_ledger_run    ON dbo.policy_ledger (run_id, ledger_id);
    CREATE INDEX IX_policy_ledger_recent ON dbo.policy_ledger (charged_at DESC);
END;
GO

-- Todo #1: inbox_audit
IF OBJECT_ID('dbo.inbox_audit', 'U') IS NULL
BEGIN
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
END;
GO

-- Todo #3: prompt_versions
IF OBJECT_ID('dbo.prompt_versions', 'U') IS NULL
BEGIN
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
END;
GO

-- Todo #7: approvals
IF OBJECT_ID('dbo.approvals', 'U') IS NULL
BEGIN
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
END;
GO

-- Additive columns (safe re-run).
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.demo_events') AND name = 'prompt_hash'
)
    ALTER TABLE dbo.demo_events ADD prompt_hash CHAR(16) NULL;
GO
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.demo_events') AND name = 'agent'
)
    ALTER TABLE dbo.demo_events ADD agent NVARCHAR(32) NULL;
GO
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.incidents') AND name = 'terminal_outcome'
)
    ALTER TABLE dbo.incidents ADD terminal_outcome NVARCHAR(32) NULL;
GO
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.incidents') AND name = 'terminal_reason'
)
    ALTER TABLE dbo.incidents ADD terminal_reason NVARCHAR(500) NULL;
GO
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.incidents') AND name = 'closed_at'
)
    ALTER TABLE dbo.incidents ADD closed_at DATETIME2(3) NULL;
GO

-- Data reset + reseed batch, wrapped in a tran.
BEGIN TRAN;

-- Fast reset: TRUNCATE is instant and resets IDENTITY
TRUNCATE TABLE dbo.source_orders;
TRUNCATE TABLE dbo.dq_flags;
TRUNCATE TABLE dbo.demo_events;
TRUNCATE TABLE dbo.incidents;
TRUNCATE TABLE dbo.policy_ledger;
TRUNCATE TABLE dbo.inbox_audit;
TRUNCATE TABLE dbo.approvals;
-- prompt_versions is intentionally NOT truncated — it's deploy-time history,
-- not per-run state, and the current-hash lookup depends on it.

-- Reseed deterministic mock data (Scenario 1: line_id is unique → clean;
--                                 Scenario 2: order_id has duplicate on O-1003 → duplicates_found)
INSERT INTO dbo.source_orders (line_id, order_id, customer_id, order_date, amount, region) VALUES
 (1, 'O-1001','C-01','2026-08-01', 129.50,'NA'),
 (2, 'O-1002','C-02','2026-08-02',  42.00,'EU'),
 (3, 'O-1003','C-03','2026-08-02', 875.10,'NA'),
 (4, 'O-1004','C-01','2026-08-03',  59.99,'NA'),
 (5, 'O-1005','C-04','2026-08-04',1240.00,'APAC'),
 (6, 'O-1006','C-05','2026-08-05',  15.25,'EU'),
 (7, 'O-1007','C-06','2026-08-05', 320.00,'NA'),
 (8, 'O-1008','C-07','2026-08-06',  88.10,'APAC'),
 (9, 'O-1003','C-03','2026-08-02', 875.10,'NA'),
 (10,'O-1003','C-08','2026-08-06', 875.10,'NA');

COMMIT TRAN;

-- Verify
SELECT 'source_orders rows'   AS metric, COUNT(*) AS value FROM dbo.source_orders
UNION ALL SELECT 'dq_flags rows',        COUNT(*)          FROM dbo.dq_flags
UNION ALL SELECT 'demo_events rows',     COUNT(*)          FROM dbo.demo_events
UNION ALL SELECT 'incidents rows',       COUNT(*)          FROM dbo.incidents
UNION ALL SELECT 'policy_ledger rows',   COUNT(*)          FROM dbo.policy_ledger
UNION ALL SELECT 'duplicate keys',       COUNT(*)          FROM (
    SELECT order_id FROM dbo.source_orders GROUP BY order_id HAVING COUNT(*) > 1
) d;
