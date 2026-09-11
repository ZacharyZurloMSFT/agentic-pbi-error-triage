targetScope = 'resourceGroup'

@description('Location.')
param location string = resourceGroup().location

@description('Function App name (globally unique subdomain on azurewebsites.net).')
param functionAppName string = 'func-triage-${uniqueString(resourceGroup().id)}'

@description('Function App Service Plan name (Flex Consumption FC1).')
param planName string = 'plan-func-triage'

@description('Storage account for the Function runtime.')
param storageName string = 'sttriage${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace for App Insights.')
param logAnalyticsName string = 'log-triage'

@description('App Insights component name.')
param appInsightsName string = 'appi-func-triage'

@description('Delegated Function VNet-integration subnet id (Microsoft.Web/serverFarms).')
param functionSubnetId string

@description('SQL server FQDN for the Function to reach via VNet integration + private DNS.')
param sqlServerFqdn string = 'sql-server-triage.database.windows.net'

@description('SQL database name.')
param sqlDatabaseName string = 'sql-db-triage'

@description('Monitored mailbox UPN for the poller.')
param mailboxUpn string = ''

@description('Triage agent responses endpoint. Set post-agent-deploy via azd env.')
param triageEndpoint string = ''

@description('Foundry project managed-identity object ids allowed to call the Function via Easy Auth. Any caller whose token oid is in this list passes; anyone else gets 401.')
param foundryAllowedPrincipals array

@description('App Registration client (appId) that gates the Function via Easy Auth v2. Must match the appId of the App Registration whose identifierUri is `api://<functionAppName>`. Set via .env / function.bicepparam after bootstrap-func-app-reg.ps1 runs.')
param functionAppRegClientId string

@description('Resource id of the subnet used for private endpoints (must be in same VNet as the Function App).')
param privateEndpointSubnetId string

@description('Runtime Python version for the Function App.')
param pythonVersion string = '3.11'

@description('Flex Consumption instance memory in MB.')
@allowed([2048, 4096])
param instanceMemoryMB int = 2048

@description('Flex Consumption maximum instances.')
param maximumInstanceCount int = 40

var deploymentContainerName = 'func-releases'

// --------------------------- Storage ------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    // SFI: shared-key access off; runtime uses MI-based blob access.
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // Org policy StorageAccount_PublicNetwork_Modify silently forces Disabled;
    // matching reality here. Function App reaches storage via VNet + PEs below.
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {}
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

// --------------------------- Storage private endpoints ------------------
// Flex Consumption Python needs the deployment container (blob) and host
// locks (queue). Both go through PEs in snet-pe; VNet-integrated Function
// App resolves them via linked private DNS zones. Added Aug 2026 to fix
// the "app has no registered functions" symptom that occurred when public
// access was policy-disabled without a PE.

var storagePeGroups = [ 'blob', 'queue' ]

resource storagePrivateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for grp in storagePeGroups: {
  name: 'privatelink.${grp}.${environment().suffixes.storage}'
  location: 'global'
}]

resource storagePrivateDnsZoneVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (grp, i) in storagePeGroups: {
  parent: storagePrivateDnsZones[i]
  name: 'vnet-triage-link-${grp}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: split(privateEndpointSubnetId, '/subnets/')[0]
    }
  }
}]

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [for (grp, i) in storagePeGroups: {
  name: 'pe-func-storage-${grp}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'conn-${grp}'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ grp ]
        }
      }
    ]
  }
}]

resource storagePrivateEndpointDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (grp, i) in storagePeGroups: {
  parent: storagePrivateEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: grp
        properties: {
          privateDnsZoneId: storagePrivateDnsZones[i].id
        }
      }
    ]
  }
}]

// --------------------------- Observability ------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// --------------------------- Flex Consumption Plan ----------------------

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

// --------------------------- Function App -------------------------------

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    // VNet-integrate so the Function can reach private SQL via the PE.
    virtualNetworkSubnetId: functionSubnetId
    vnetRouteAllEnabled: true
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: pythonVersion
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SQL_SERVER'
          value: sqlServerFqdn
        }
        {
          name: 'SQL_DATABASE'
          value: sqlDatabaseName
        }
        {
          name: 'MAILBOX_UPN'
          value: mailboxUpn
        }
        {
          name: 'TRIAGE_ENDPOINT'
          value: triageEndpoint
        }
        {
          name: 'DEMO_SUBJECT_PREFIX'
          value: '[BI-DEMO]'
        }
      ]
    }
  }
}

// --------------------------- Easy Auth v2 -------------------------------
// Requires bearer tokens issued by Entra ID (v2 endpoint) with `aud` set to
// this Function App's App Registration. `allowedPrincipals.identities` gates
// on the caller's oid — only the Foundry MIs listed pass through. Everyone
// else gets 401.

resource authSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~2'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: 'https://sts.windows.net/${subscription().tenantId}/v2.0'
          clientId: functionAppRegClientId
        }
        validation: {
          allowedAudiences: [
            'api://${functionAppName}'
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              identities: foundryAllowedPrincipals
            }
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

// --------------------------- Storage RBAC for Function MI ---------------

var storageBlobDataOwnerRole = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'

resource funcStorageRoleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, storageBlobDataOwnerRole)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageBlobDataOwnerRole
    )
  }
}

output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output functionAppResourceId string = functionApp.id
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppAudience string = 'api://${functionAppName}'
output appInsightsConnectionString string = appInsights.properties.ConnectionString
