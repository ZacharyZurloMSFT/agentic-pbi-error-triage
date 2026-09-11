using './network.bicep'

param location = 'centralus'
param sqlServerName = 'sql-server-triage'
param vnetName = 'vnet-triage'
param vnetAddressPrefix = '10.50.0.0/24'
param peSubnetName = 'snet-pe'
param peSubnetPrefix = '10.50.0.0/27'
param sqlPrivateEndpointName = 'pe-sql-server-triage'
param jumpSubnetName = 'snet-jump'
param jumpSubnetPrefix = '10.50.0.32/27'
param foundrySubnetName = 'snet-foundry'
param foundrySubnetPrefix = '10.50.0.96/27'

