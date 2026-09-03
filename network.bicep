targetScope = 'resourceGroup'

@description('Location for networking resources.')
param location string = resourceGroup().location

@description('Existing SQL logical server name to attach the private endpoint to.')
param sqlServerName string = 'sql-server-sme'

@description('VNet name.')
param vnetName string = 'vnet-sme'

@description('VNet address space.')
param vnetAddressPrefix string = '10.50.0.0/24'

@description('Private endpoint subnet name.')
param peSubnetName string = 'snet-pe'

@description('Private endpoint subnet prefix.')
param peSubnetPrefix string = '10.50.0.0/27'

@description('Jumpbox subnet name.')
param jumpSubnetName string = 'snet-jump'

@description('Jumpbox subnet prefix.')
param jumpSubnetPrefix string = '10.50.0.32/27'

@description('Foundry agent-runtime subnet name (delegated to Microsoft.App/environments).')
param foundrySubnetName string = 'snet-foundry'

@description('Foundry agent-runtime subnet prefix.')
param foundrySubnetPrefix string = '10.50.0.96/27'

@description('Function App VNet-integration subnet name (delegated to Microsoft.App/environments for Flex Consumption).')
param functionSubnetName string = 'snet-func'

@description('Function App VNet-integration subnet prefix.')
param functionSubnetPrefix string = '10.50.0.128/28'

@description('Private endpoint name for SQL.')
param sqlPrivateEndpointName string = 'pe-sql-server-sme'

var sqlPrivateDnsZoneName = 'privatelink.database.windows.net'

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' existing = {
  name: sqlServerName
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: jumpSubnetName
        properties: {
          addressPrefix: jumpSubnetPrefix
          delegations: [
            {
              name: 'aciDelegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        name: foundrySubnetName
        properties: {
          addressPrefix: foundrySubnetPrefix
          delegations: [
            {
              name: 'foundryDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: functionSubnetName
        properties: {
          addressPrefix: functionSubnetPrefix
          delegations: [
            {
              name: 'funcDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: sqlPrivateDnsZoneName
  location: 'global'
}

resource sqlDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: sqlPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: sqlPrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/${peSubnetName}'
    }
    privateLinkServiceConnections: [
      {
        name: 'sql-plsc'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource sqlPeDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: sqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: sqlPrivateDnsZone.id
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output peSubnetId string = '${vnet.id}/subnets/${peSubnetName}'
output jumpSubnetId string = '${vnet.id}/subnets/${jumpSubnetName}'
output foundrySubnetId string = '${vnet.id}/subnets/${foundrySubnetName}'
output functionSubnetId string = '${vnet.id}/subnets/${functionSubnetName}'
output sqlPrivateEndpointId string = sqlPrivateEndpoint.id
output sqlPrivateDnsZoneId string = sqlPrivateDnsZone.id
