targetScope = 'resourceGroup'

@description('Location for the Foundry account.')
param location string = resourceGroup().location

@description('AI Foundry account name (Microsoft.CognitiveServices/accounts, kind=AIServices).')
param foundryAccountName string = 'ai-foundry-triage'

@description('AI Foundry project name (child accounts/projects).')
param foundryProjectName string = 'proj-triage'

@description('Foundry project display name.')
param foundryProjectDisplayName string = 'BI Triage Demo'

@description('Resource id of the delegated subnet (Microsoft.App/environments) for Foundry agent-runtime egress.')
param foundrySubnetId string

@description('Model deployment name (referenced by agents).')
param modelDeploymentName string = 'gpt-4o'

@description('Foundation model to deploy.')
param modelName string = 'gpt-4o'

@description('Model version.')
param modelVersion string = '2024-11-20'

@description('Model deployment SKU.')
param modelSkuName string = 'GlobalStandard'

@description('Model deployment capacity (thousands of tokens per minute).')
param modelCapacity int = 50

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryAccountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Agent-runtime egress through our VNet so it can reach private SQL PE
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: foundrySubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
    // Inbound: enabled. The demo trigger (demo-fire.ps1) POSTs directly to the
    // Responses endpoint from the presenter's laptop over the public data plane;
    // deploy-agents.ps1 does the same for the agent definitions. Access is
    // still Entra-gated at both the control plane and the Function App via
    // Easy Auth v2 + MI audience validation.
    publicNetworkAccess: 'Enabled'
    // SFI: disable local (key) auth on the account
    disableLocalAuth: true
    customSubDomainName: foundryAccountName
    allowProjectManagement: true
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryAccount
  name: foundryProjectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: foundryProjectDisplayName
    description: 'BI Triage demo — Triage + DQ agents'
  }
}

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundryAccount
  name: modelDeploymentName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

output foundryAccountName string = foundryAccount.name
output foundryAccountId string = foundryAccount.id
output foundryAccountPrincipalId string = foundryAccount.identity.principalId
output foundryProjectName string = foundryProject.name
output foundryProjectId string = foundryProject.id
output foundryProjectPrincipalId string = foundryProject.identity.principalId
output foundryProjectEndpoint string = 'https://${foundryAccount.name}.services.ai.azure.com/api/projects/${foundryProject.name}'
output modelDeploymentName string = modelDeployment.name
