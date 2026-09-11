targetScope = 'resourceGroup'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('SQL logical server name.')
param sqlServerName string = 'sql-server-triage'

@description('SQL database name.')
param sqlDatabaseName string = 'sql-db-triage'

@description('Entra ID object ID of the SQL AAD admin (user, group, or service principal).')
param aadAdminObjectId string

@description('Entra ID login (UPN or group display name) shown for the SQL AAD admin.')
param aadAdminLogin string

@description('Entra tenant ID for the SQL AAD admin.')
param aadAdminTenantId string = subscription().tenantId

@description('AAD principal type for the SQL AAD admin.')
@allowed([
  'User'
  'Group'
  'Application'
])
param aadAdminPrincipalType string = 'User'

@description('SKU for the SQL database.')
param databaseSku object = {
  name: 'GP_S_Gen5_2'
  tier: 'GeneralPurpose'
  family: 'Gen5'
  capacity: 2
}

@description('Toggle public network access on the SQL server. Set to Enabled + add firewall rules for temporary/demo access.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

@description('List of client public IPv4 addresses to allow through the SQL firewall when publicNetworkAccess is Enabled.')
param allowedClientIps array = []

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // SFI: Entra-only auth; no SQL local authentication
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: aadAdminLogin
      sid: aadAdminObjectId
      tenantId: aadAdminTenantId
      principalType: aadAdminPrincipalType
    }
    minimalTlsVersion: '1.2'
    // SFI: public access is toggleable; keep 'Disabled' for prod, allow 'Enabled' for demo seeding
    publicNetworkAccess: publicNetworkAccess
    restrictOutboundNetworkAccess: 'Disabled'
    version: '12.0'
  }
}

resource sqlFirewallRules 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = [for (ip, i) in allowedClientIps: {
  parent: sqlServer
  name: 'client-ip-${i}'
  properties: {
    startIpAddress: ip
    endIpAddress: ip
  }
}]

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  sku: databaseSku
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: false
    autoPauseDelay: 60
    minCapacity: json('0.5')
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: 'Local'
  }
}

// SFI: enable auditing to server-level (uses managed identity via storage, but here Log Analytics is preferred).
// Diagnostic settings can be layered on with a Log Analytics workspace parameter later.

output sqlServerResourceId string = sqlServer.id
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseResourceId string = sqlDatabase.id
