targetScope = 'subscription'

import { curatedPrivateLinkPrivateDnsZones } from './zones.bicep'

@description('Required. Name of the resource group that holds the shared Private DNS zones.')
@minLength(1)
@maxLength(90)
param dnsResourceGroupName string

@description('Required. Azure region for the deployment. Private DNS zones are global, but this sets the resource group location and is substituted into regional zone names such as Container Apps.')
param location string

@description('Optional. Virtual networks to link to every Private DNS zone. Each object needs a virtualNetworkResourceId. Empty until hub and spoke virtual networks exist.')
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

// Deployed into the resource group above. Cross-subscription placement for future hubs and
// spokes uses resourceGroup(<subscriptionId>, <name>) here; no provider plumbing is needed.
module privateDnsZones 'br/public:avm/ptn/network/private-link-private-dns-zones:0.7.3' = {
  name: 'deploy-private-dns-zones'
  scope: resourceGroup(dnsResourceGroupName)
  dependsOn: [
    dnsResourceGroup
  ]
  params: {
    location: location
    privateLinkPrivateDnsZones: curatedPrivateLinkPrivateDnsZones
    additionalPrivateLinkPrivateDnsZonesToInclude: additionalPrivateLinkPrivateDnsZonesToInclude
    virtualNetworkLinks: virtualNetworkLinks
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
