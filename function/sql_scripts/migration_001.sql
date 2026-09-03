-- migration_001.sql — additive schema for the 10 improvements from
-- SQLBImhugh/foundry-fabric-triage-demo:
--
--   * dbo.inbox_audit       — Todo #1  (fail-closed poller filter)
--   * dbo.prompt_versions   — Todo #3  (prompt version hashing)
--   * dbo.approvals         — Todo #7  (human-in-the-loop)
--   * demo_events.prompt_hash, demo_events.agent  — Todo #3
--   * incidents.terminal_outcome, incidents.terminal_reason  — Todo #6
--
-- Idempotent. Safe to re-run. Not destructive — never drops or truncates.
-- Called by /api/demo/migrate. Run once after deploying the new bits.
SET NOCOUNT ON;
SET XACT_ABORT ON;

-------------------------------------------------------------------------
-- 1. dbo.inbox_audit — one row per mail the poller REJECTED (subject
--    didn't match, pattern was invalid, non-demo sender, etc.)
--    Auditable evidence that the inbox filter is a security control,
--    not housekeeping. Invariant: never widen the filter to make the
--    demo "find something"; log the rejection and send a matching one.
-------------------------------------------------------------------------
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

-------------------------------------------------------------------------
-- 2. dbo.prompt_versions — SHA-256 of every deployed agent instructions
--    block. deploy-agents.ps1 posts to /api/admin/register_prompt_hash
--    after each successful PATCH. Agents stamp the current hash onto
--    every demo_events row so a prompt change is traceable in run logs.
-------------------------------------------------------------------------
IF OBJECT_ID('dbo.prompt_versions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.prompt_versions (
        version_id    INT IDENTITY(1,1) PRIMARY KEY,
        agent         NVARCHAR(64)  NOT NULL,
        prompt_hash   CHAR(16)      NOT NULL,
        instructions_len INT        NOT NULL,
        deployed_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
        deployed_by   NVARCHAR(128) NULL
    );
    CREATE INDEX IX_prompt_versions_agent
        ON dbo.prompt_versions (agent, deployed_at DESC);
END;
GO

-------------------------------------------------------------------------
-- 3. dbo.approvals — human-in-the-loop gate (Scenarios 5 + 6).
--    Fail-closed by design:
--      * Only an explicit `granted` decision counts as yes.
--      * `fingerprint` is HMAC(secret, run_id|action|args_hash).
--      * `expires_at` is TTL — expired rows never count as approved.
--      * `used_at` set on first dispatch — an approval is one-use.
--    Every column above is a rule the reference repo's approvals module
--    encodes. Losing any of them re-opens the "silence reads as consent"
--    failure mode.
-------------------------------------------------------------------------
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

-------------------------------------------------------------------------
-- 4. Additive columns on existing tables.
-------------------------------------------------------------------------
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

-- Verify
SELECT 'inbox_audit'     AS obj, OBJECT_ID('dbo.inbox_audit')     AS id
UNION ALL SELECT 'prompt_versions', OBJECT_ID('dbo.prompt_versions')
UNION ALL SELECT 'approvals',       OBJECT_ID('dbo.approvals');
