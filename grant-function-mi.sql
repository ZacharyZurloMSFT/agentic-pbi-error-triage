-- Grant the Function App's system-assigned MI SQL access.
-- Run as SQL AAD admin.
--
-- CRITICAL: Managed-identity tokens carry `idtyp: app` and Azure SQL matches
-- the DB user's SID against the byte-swapped GUID of the token's `appid`
-- claim, NOT its `oid` claim (the way it does for user tokens). For MIs the
-- `appid` and `oid` are DIFFERENT GUIDs — you MUST use the appId (not the
-- principalId).
--
-- Step-by-step derivation for THIS deployment:
--
--   1. Read the Function App's system-assigned MI principal id:
--        $PRINCIPAL = az functionapp identity show `
--            -g $env:AZURE_RESOURCE_GROUP -n $env:FUNCTION_APP_NAME `
--            --query principalId -o tsv
--
--   2. Look up the appId for that MI:
--        $APPID     = az ad sp show --id $PRINCIPAL --query appId -o tsv
--
--   3. Convert the appId GUID to a little-endian byte-swapped SID literal:
--        Data1 (4 bytes): reversed
--        Data2 (2 bytes): reversed
--        Data3 (2 bytes): reversed
--        Data4 (8 bytes): as-is
--      Prefix with 0x. Example — a synthetic appId `11223344-5566-7788-99aa-bbccddeeff00`
--      byte-swaps to `0x44332211665588779AABCCDDEEFF00` (padded to 32 hex chars).
--
--   4. Paste the derived SID and the Function App name (default: func-triage)
--      into the CREATE USER statement below.
--
-- Replaces the three per-principal grants under the old hosted-agent
-- architecture (proj-triage, dq-agent, triage-agent) — one MI now covers reads
-- and writes for /dq/check, /dq/flag, /admin/seed, and /admin/reset.

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'func-triage')
    DROP USER [func-triage];

CREATE USER [func-triage]
  WITH SID = 0x00000000000000000000000000000000, TYPE = E;  -- REPLACE with byte-swapped appId

ALTER ROLE db_datareader ADD MEMBER [func-triage];
ALTER ROLE db_datawriter ADD MEMBER [func-triage];
-- Needed for /admin/seed to CREATE TABLE on first run:
ALTER ROLE db_ddladmin  ADD MEMBER [func-triage];

SELECT name, type_desc, authentication_type_desc, CONVERT(VARCHAR(64), sid, 1) AS sid_hex
FROM sys.database_principals
WHERE name = N'func-triage';

SELECT r.name AS role_name
FROM sys.database_role_members m
  JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
  JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
WHERE u.name = N'func-triage';
