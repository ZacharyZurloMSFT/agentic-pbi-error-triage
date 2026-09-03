using './function.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'centralus')
param functionAppName = readEnvironmentVariable('FUNCTION_APP_NAME', 'func-sme')

// Subnet resource ids emitted by network.bicep outputs.
param functionSubnetId = readEnvironmentVariable('FUNCTION_SUBNET_ID', '')
param privateEndpointSubnetId = readEnvironmentVariable('PE_SUBNET_ID', '')

param sqlServerFqdn = readEnvironmentVariable('SQL_SERVER_FQDN', 'sql-server-sme.database.windows.net')
param sqlDatabaseName = readEnvironmentVariable('SQL_DATABASE_NAME', 'sql-db-sme')

// Monitored mailbox — Function App poller reads unread [BI-DEMO] mail here.
param mailboxUpn = readEnvironmentVariable('MAILBOX_UPN', '')

// Set once the Triage prompt agent is created (agents/deploy-agents.ps1
// prints the responses endpoint on first run).
param triageEndpoint = readEnvironmentVariable('TRIAGE_ENDPOINT', '')

// Populate with the Foundry PROJECT MI object id (proj-sme, from
// foundry.bicep outputs.foundryProjectPrincipalId). Any caller whose Entra
// token oid is in this list passes Easy Auth; everyone else gets 401.
param foundryAllowedPrincipals = [
  readEnvironmentVariable('FOUNDRY_PROJECT_MI_OBJECT_ID', '')
]
