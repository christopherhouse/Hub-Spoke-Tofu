targetScope = 'resourceGroup'

import { spokeSubnetType, subnetNetworkSecurityGroupName, spokeVirtualNetworkName, defaultPrivateEndpointNetworkPolicies } from '../types.bicep'

// Spoke network for the hub-and-spoke topology.
//
// Every subnet gets its own network security group, even when it carries no custom rules, so
// that adding a rule later is a parameter change rather than new infrastructure and a subnet
// re-association. The baseline is deliberately empty: the Azure platform default rules
// already deny inbound from the internet and allow VNet-to-VNet, and restating them here
// would be maintenance with no benefit and a risk of drifting from the platform.

@description('Required. Short name of the spoke. Resource names are derived from it.')
@minLength(1)
@maxLength(40)
param name string

@description('Optional. Azure region for the spoke resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Address space of the spoke virtual network.')
@minLength(1)
param addressPrefixes string[]

@description('Optional. Subnets in the spoke. Each gets a dedicated network security group.')
param subnets spokeSubnetType[] = []

@description('Required. Resource ID of the hub virtual network this spoke peers with. May live in another subscription or region of the same tenant.')
@minLength(1)
param hubVirtualNetworkResourceId string

@description('Optional. Address prefix of the hub `AzureBastionSubnet`. Supply it to allow RDP and SSH from Bastion into spoke subnets. Empty when the hub has no Bastion, in which case no Bastion rule is generated.')
param hubBastionSubnetAddressPrefix string = ''

@description('Optional. Allow traffic forwarded by a network virtual appliance rather than originated in the peer. Defaults to `true`: inert until a hub firewall exists, and enabling it up front avoids re-peering later.')
param allowForwardedTraffic bool = true

@description('Optional. Let the spoke use a gateway in the hub. Defaults to `false`. Setting it before the hub has a VPN or ExpressRoute gateway fails the peering.')
param useRemoteGateways bool = false

@description('Optional. Let the hub share its gateway with this spoke. Defaults to `false`. Set it together with `useRemoteGateways` once a hub gateway exists.')
param allowHubGatewayTransit bool = false

@description('Optional. Tags applied to every resource in the spoke.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

var virtualNetworkName = spokeVirtualNetworkName(name)

var bastionAccessAvailable = !empty(hubBastionSubnetAddressPrefix)

// One NSG per subnet. The rule set is the generated Bastion rule, where applicable, followed
// by whatever the caller supplied; caller rules are appended so a generated rule can never be
// displaced by accident. Generated rules occupy priority 100, so caller rules should start at
// 200. A collision is an Azure deployment error rather than a build error.
module subnetNetworkSecurityGroups 'br/public:avm/res/network/network-security-group:0.5.3' = [
  for subnet in subnets: {
    // Deployment names are capped at 64 characters. The uniqueString prefix guarantees
    // distinctness, so truncating the readable part cannot make two subnets collide.
    name: take('nsg-${uniqueString(subnet.name)}-${subnet.name}', 64)
    params: {
      name: subnetNetworkSecurityGroupName(virtualNetworkName, subnet.name)
      location: location
      tags: tags
      enableTelemetry: enableTelemetry
      securityRules: concat(
        bastionAccessAvailable && (subnet.?allowBastionAccess ?? true)
          ? [
              {
                name: 'AllowBastionRdpSshInbound'
                properties: {
                  description: 'RDP and SSH from the hub AzureBastionSubnet only.'
                  access: 'Allow'
                  direction: 'Inbound'
                  priority: 100
                  protocol: 'Tcp'
                  sourceAddressPrefix: hubBastionSubnetAddressPrefix
                  sourcePortRange: '*'
                  destinationAddressPrefix: subnet.addressPrefix
                  destinationPortRanges: [
                    '22'
                    '3389'
                  ]
                }
              }
            ]
          : [],
        subnet.?securityRules ?? []
      )
    }
  }
]

// The AVM module creates both directions when remotePeeringEnabled is set, and derives the
// remote subscription and resource group by splitting remoteVirtualNetworkResourceId. That is
// what makes cross-subscription peering a parameter change: no provider plumbing, only
// Contributor on both subscriptions.
module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'vnet-${name}'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: addressPrefixes
    tags: tags
    enableTelemetry: enableTelemetry
    subnets: [
      for (subnet, index) in subnets: {
        name: subnet.name
        addressPrefix: subnet.addressPrefix
        networkSecurityGroupResourceId: subnetNetworkSecurityGroups[index].outputs.resourceId
        delegation: subnet.?delegation
        serviceEndpoints: subnet.?serviceEndpoints
        privateEndpointNetworkPolicies: subnet.?privateEndpointNetworkPolicies ?? defaultPrivateEndpointNetworkPolicies
      }
    ]
    peerings: [
      {
        remoteVirtualNetworkResourceId: hubVirtualNetworkResourceId
        // Bidirectional. A spoke peered in one direction only drops return traffic.
        remotePeeringEnabled: true
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: allowForwardedTraffic
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: allowForwardedTraffic
        // Gateway transit is the hub's side of the arrangement; the spoke consumes it.
        useRemoteGateways: useRemoteGateways
        allowGatewayTransit: false
        remotePeeringUseRemoteGateways: false
        remotePeeringAllowGatewayTransit: allowHubGatewayTransit
      }
    ]
  }
}

@description('Resource ID of the spoke virtual network.')
output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId

@description('Name of the spoke virtual network.')
output virtualNetworkName string = virtualNetwork.outputs.name

@description('Address space of the spoke virtual network.')
output addressPrefixes string[] = addressPrefixes

@description('Location the spoke was deployed into.')
output location string = location

@description('The subnets that were created, each with its resource ID and the resource ID of its dedicated network security group.')
output subnets object[] = [
  for (subnet, index) in subnets: {
    name: subnet.name
    addressPrefix: subnet.addressPrefix
    resourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, subnet.name)
    networkSecurityGroupResourceId: subnetNetworkSecurityGroups[index].outputs.resourceId
  }
]
