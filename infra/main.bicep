targetScope = 'subscription'

import { curatedPrivateLinkPrivateDnsZones } from './zones.bicep'
import { hubType, hubVirtualNetworkName, spokeType, spokeVirtualNetworkName } from './types.bicep'

@description('Required. Name of the resource group that holds the shared Private DNS zones.')
@minLength(1)
@maxLength(90)
param dnsResourceGroupName string

@description('Required. Azure region for the deployment. Private DNS zones are global, but this sets the resource group location and is substituted into regional zone names such as Container Apps.')
param location string

@description('Optional. Hubs to deploy. Each entry creates its own resource group, virtual network, subnets and Azure Bastion, and its virtual network is linked to every Private DNS zone. Hubs may target other subscriptions in the same tenant.')
param hubs hubType[] = []

@description('Optional. Spokes to deploy. Each entry creates its own resource group, virtual network and subnets, peers bidirectionally with the hub named in `hubName`, and is linked to every Private DNS zone. Spokes may target other subscriptions in the same tenant, provided the deployment identity holds Contributor there.')
param spokes spokeType[] = []

@description('Optional. Additional virtual networks to link to every Private DNS zone, on top of the hub virtual networks, which are linked automatically. Each object needs a virtualNetworkResourceId.')
param virtualNetworkLinks array = []

@description('Optional. Additional Private Link DNS zones to create on top of the curated catalog. Use this for regional zones in regions other than the deployment location, or for services the catalog does not cover.')
param additionalPrivateLinkPrivateDnsZonesToInclude string[] = []

@description('Optional. Tags applied to the resource group and every Private DNS zone.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

module dnsResourceGroup 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'deploy-dns-rg'
  params: {
    name: dnsResourceGroupName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// One resource group per hub. `subscriptionId` makes onboarding another subscription a
// parameter change: Bicep targets a scope per module, so no provider plumbing is needed.
module hubResourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for hub in hubs: {
    name: 'deploy-rg-${hub.name}'
    scope: subscription(hub.?subscriptionId ?? subscription().subscriptionId)
    params: {
      name: hub.resourceGroupName
      location: hub.location
      tags: hub.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

module hubNetworks 'modules/hub.bicep' = [
  for (hub, index) in hubs: {
    name: 'deploy-hub-${hub.name}'
    scope: resourceGroup(hub.?subscriptionId ?? subscription().subscriptionId, hub.resourceGroupName)
    dependsOn: [
      hubResourceGroups[index]
    ]
    params: {
      name: hub.name
      location: hub.location
      addressPrefixes: hub.addressPrefixes
      bastion: hub.?bastion
      jumpboxSubnet: hub.?jumpboxSubnet
      natGateway: hub.?natGateway
      runnersSubnet: hub.?runnersSubnet
      jumpboxes: hub.?jumpboxes ?? []
      tags: hub.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

// Each spoke references exactly one hub, by name. Resolved here rather than passed as a
// resource ID, so no hub virtual network ID is ever hand-copied into a .bicepparam file.
//
// A `hubName` that matches no hub yields null and fails with a null-reference error rather
// than a helpful message: Bicep's `assert` is still an experimental feature, so the invariant
// is documented in infra/README.md rather than enforced here.
var spokeHubs = [
  for spoke in spokes: first(filter(hubs, hub => hub.name == spoke.hubName))
]

// Empty when the hub has no Bastion, which suppresses the generated RDP and SSH rule in the
// spoke rather than emitting one with an empty source prefix.
var spokeHubBastionSubnetPrefixes = [
  for (spoke, index) in spokes: (spokeHubs[index]!.?bastion != null && (spokeHubs[index]!.bastion!.?enabled ?? true))
    ? spokeHubs[index]!.bastion!.subnetAddressPrefix
    : ''
]

module spokeResourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for spoke in spokes: {
    name: 'deploy-rg-${spoke.name}'
    scope: subscription(spoke.?subscriptionId ?? subscription().subscriptionId)
    params: {
      name: spoke.resourceGroupName
      location: spoke.location
      tags: spoke.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

// The hub virtual network must exist before the peering can reference it, and the peering is
// created in both directions from here, so the dependency is explicit.
module spokeNetworks 'modules/spoke.bicep' = [
  for (spoke, index) in spokes: {
    name: 'deploy-spoke-${spoke.name}'
    scope: resourceGroup(spoke.?subscriptionId ?? subscription().subscriptionId, spoke.resourceGroupName)
    dependsOn: [
      spokeResourceGroups[index]
      hubNetworks
    ]
    params: {
      name: spoke.name
      location: spoke.location
      addressPrefixes: spoke.addressPrefixes
      subnets: spoke.?subnets ?? []
      hubVirtualNetworkResourceId: resourceId(
        spokeHubs[index]!.?subscriptionId ?? subscription().subscriptionId,
        spokeHubs[index]!.resourceGroupName,
        'Microsoft.Network/virtualNetworks',
        hubVirtualNetworkName(spokeHubs[index]!.name)
      )
      hubBastionSubnetAddressPrefix: spokeHubBastionSubnetPrefixes[index]
      allowForwardedTraffic: spoke.?peering.?allowForwardedTraffic ?? true
      useRemoteGateways: spoke.?peering.?useRemoteGateways ?? false
      allowHubGatewayTransit: spoke.?peering.?allowHubGatewayTransit ?? false
      tags: spoke.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

// Derived rather than supplied as a parameter, so no hub virtual network resource ID is ever
// hand-copied into a .bicepparam file. The IDs are composed from the hub definitions instead
// of read from the hub module outputs, because a variable loop cannot reference module
// outputs (BCP182) and a for-expression cannot be nested inside concat (BCP138). The hub
// virtual network naming convention lives in types.bicep so it is stated once.
// Registration stays off everywhere: private endpoints own the records in these zones.
var hubVirtualNetworkLinks = [
  for hub in hubs: {
    virtualNetworkResourceId: resourceId(
      hub.?subscriptionId ?? subscription().subscriptionId,
      hub.resourceGroupName,
      'Microsoft.Network/virtualNetworks',
      hubVirtualNetworkName(hub.name)
    )
    registrationEnabled: false
  }
]

// Spokes are linked on the same terms as hubs, so a private endpoint in a spoke resolves
// without waiting for a DNS private resolver in the hub.
var spokeVirtualNetworkLinks = [
  for spoke in spokes: {
    virtualNetworkResourceId: resourceId(
      spoke.?subscriptionId ?? subscription().subscriptionId,
      spoke.resourceGroupName,
      'Microsoft.Network/virtualNetworks',
      spokeVirtualNetworkName(spoke.name)
    )
    registrationEnabled: false
  }
]

// Deployed into the resource group above. Cross-subscription placement for future hubs and
// spokes uses resourceGroup(<subscriptionId>, <name>) here; no provider plumbing is needed.
module privateDnsZones 'br/public:avm/ptn/network/private-link-private-dns-zones:0.7.3' = {
  name: 'deploy-private-dns-zones'
  scope: resourceGroup(dnsResourceGroupName)
  // The hub virtual networks must exist before they can be linked; the resource IDs above
  // are composed, not referenced, so the dependency has to be explicit.
  dependsOn: [
    dnsResourceGroup
    hubNetworks
    spokeNetworks
  ]
  params: {
    location: location
    privateLinkPrivateDnsZones: curatedPrivateLinkPrivateDnsZones
    additionalPrivateLinkPrivateDnsZonesToInclude: additionalPrivateLinkPrivateDnsZonesToInclude
    virtualNetworkLinks: concat(hubVirtualNetworkLinks, spokeVirtualNetworkLinks, virtualNetworkLinks)
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the resource group holding the shared Private DNS zones.')
output dnsResourceGroupResourceId string = dnsResourceGroup.outputs.resourceId

@description('Name of the resource group holding the shared Private DNS zones.')
output dnsResourceGroupName string = dnsResourceGroup.outputs.name

@description('The Private DNS zones that were deployed, with region tokens resolved and virtual network links applied.')
output privateDnsZones array = privateDnsZones.outputs.combinedPrivateLinkPrivateDnsZonesReplacedWithVnetsToLink

@description('The hubs that were deployed, with the resource IDs a spoke or a Container Apps environment needs to attach to one.')
output hubs array = [
  for (hub, index) in hubs: {
    name: hub.name
    location: hub.location
    subscriptionId: hub.?subscriptionId ?? subscription().subscriptionId
    resourceGroupName: hub.resourceGroupName
    virtualNetworkResourceId: hubNetworks[index].outputs.virtualNetworkResourceId
    virtualNetworkName: hubNetworks[index].outputs.virtualNetworkName
    addressPrefixes: hubNetworks[index].outputs.addressPrefixes
    bastionResourceId: hubNetworks[index].outputs.bastionResourceId
    bastionSubnetResourceId: hubNetworks[index].outputs.bastionSubnetResourceId
    jumpboxSubnetResourceId: hubNetworks[index].outputs.jumpboxSubnetResourceId
    natGatewayResourceId: hubNetworks[index].outputs.natGatewayResourceId
    runnersSubnetResourceId: hubNetworks[index].outputs.runnersSubnetResourceId
    jumpboxes: hubNetworks[index].outputs.jumpboxes
  }
]

@description('The spokes that were deployed, with their virtual network and subnet resource IDs and the hub each is peered to.')
output spokes array = [
  for (spoke, index) in spokes: {
    name: spoke.name
    hubName: spoke.hubName
    location: spoke.location
    subscriptionId: spoke.?subscriptionId ?? subscription().subscriptionId
    resourceGroupName: spoke.resourceGroupName
    virtualNetworkResourceId: spokeNetworks[index].outputs.virtualNetworkResourceId
    virtualNetworkName: spokeNetworks[index].outputs.virtualNetworkName
    addressPrefixes: spokeNetworks[index].outputs.addressPrefixes
    subnets: spokeNetworks[index].outputs.subnets
  }
]
