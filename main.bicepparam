// Populated at deploy time by scripts/load-env.ps1 + azd. Do NOT commit real values.
// Copy .env.example to .env, fill it in, then dot-source scripts/load-env.ps1.

using './main.bicep'

param sqlServerName = readEnvironmentVariable('SQL_SERVER_NAME', 'sql-server-triage')
param sqlDatabaseName = readEnvironmentVariable('SQL_DATABASE_NAME', 'sql-db-triage')
param location = readEnvironmentVariable('AZURE_LOCATION', 'centralus')

// Entra ID admin on the SQL server. All three are required — Azure SQL
// AAD-only auth needs object id, login, and tenant.
param aadAdminObjectId = readEnvironmentVariable('AAD_ADMIN_OBJECT_ID', '')
param aadAdminLogin = readEnvironmentVariable('AAD_ADMIN_LOGIN', '')
param aadAdminTenantId = readEnvironmentVariable('AZURE_TENANT_ID', '')
param aadAdminPrincipalType = readEnvironmentVariable('AAD_ADMIN_PRINCIPAL_TYPE', 'User')
