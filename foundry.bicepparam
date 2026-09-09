using './foundry.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'centralus')
param foundryAccountName = readEnvironmentVariable('FOUNDRY_ACCOUNT_NAME', 'ai-foundry-triage')
param foundryProjectName = readEnvironmentVariable('FOUNDRY_PROJECT_NAME', 'proj-triage')
param foundryProjectDisplayName = readEnvironmentVariable('FOUNDRY_PROJECT_DISPLAY_NAME', 'BI Triage Demo')

// Resource id of the delegated subnet for Foundry agent runtime egress.
// Emitted by network.bicep outputs.foundrySubnetId — either wire the outputs
// with `az deployment group show` or plug the id in manually.
param foundrySubnetId = readEnvironmentVariable('FOUNDRY_SUBNET_ID', '')

param modelDeploymentName = readEnvironmentVariable('FOUNDRY_MODEL_DEPLOYMENT_NAME', 'gpt-4o')
param modelName = readEnvironmentVariable('FOUNDRY_MODEL_NAME', 'gpt-4o')
param modelVersion = readEnvironmentVariable('FOUNDRY_MODEL_VERSION', '2024-11-20')
param modelSkuName = readEnvironmentVariable('FOUNDRY_MODEL_SKU', 'GlobalStandard')
param modelCapacity = int(readEnvironmentVariable('FOUNDRY_MODEL_CAPACITY', '50'))
