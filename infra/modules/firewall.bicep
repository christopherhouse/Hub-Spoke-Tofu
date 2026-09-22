targetScope = 'resourceGroup'

import { firewallApplicationRuleType, firewallNetworkRuleType } from '../types.bicep'

// Azure Firewall for a hub, with its policy.
//
// The firewall exists to make transit routing work. Virtual network peering is not
// transitive, so a spoke peered only to its hub can resolve a private endpoint in another
// spoke - Private DNS zones are linked to every virtual network - but cannot route to it.
// A user-defined route pointing at this firewall is what closes that gap, and the same route
// carries internet egress, so no subnet needs a NAT gateway.

@description('Required. Name of the firewall.')
@minLength(1)
@maxLength(80)
param name string

@description('Optional. Azure region for the firewall. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Resource ID of the virtual network that holds `AzureFirewallSubnet`.')
@minLength(1)
param virtualNetworkResourceId string

@description('Optional. Firewall SKU tier. Defaults to `Basic`.')
param skuTier string = 'Basic'

@description('Optional. Availability zones for the firewall. Defaults to `[]`, meaning no zone.')
param availabilityZones int[] = []

@description('Optional. Application rules, evaluated before network rules and always SNATed. Defaults to an empty collection.')
param applicationRules firewallApplicationRuleType[] = []

@description('Optional. Network rules, matched on address or service tag. Defaults to an empty collection.')
param networkRules firewallNetworkRuleType[] = []

@description('Optional. Destination ranges the firewall does not SNAT. Defaults to `[\'255.255.255.255/32\']`, meaning always SNAT.')
param snatPrivateRanges string[] = ['255.255.255.255/32']

@description('Optional. Resource ID of the shared Log Analytics workspace that receives firewall diagnostics. Empty to create no diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Tags applied to the firewall, its policy and its public IPs.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

// The Basic SKU always deploys a management NIC, so it always needs
// AzureFirewallManagementSubnet and a second public IP. Standard and Premium only need one
// when forced tunnelling is configured, which this design does not do: the firewall egresses
// straight to the internet.
var managementNicRequired = skuTier == 'Basic'

var firewallDiagnosticSettings = empty(logAnalyticsWorkspaceResourceId)
  ? null
  : [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]

// Hoisted out of the policy module because a for-expression is only legal as the value of a
// declaration or of a resource or module property, not nested inside an object literal.
var applicationRuleEntries = [
  for rule in applicationRules: {
    name: rule.name
    ruleType: 'ApplicationRule'
    sourceAddresses: rule.sourceAddresses
    targetFqdns: rule.?targetFqdns ?? []
    fqdnTags: rule.?fqdnTags ?? []
    protocols: rule.?protocols ?? [
      {
        protocolType: 'Https'
        port: 443
      }
    ]
  }
]

var networkRuleEntries = [
  for rule in networkRules: {
    name: rule.name
    ruleType: 'NetworkRule'
    sourceAddresses: rule.sourceAddresses
    destinationAddresses: rule.destinationAddresses
    destinationPorts: rule.destinationPorts
    ipProtocols: rule.?protocols ?? ['TCP']
  }
]

// Rule collections are carried on a firewall policy rather than set directly on the firewall,
// because the policy is where SNAT behaviour can be configured at all. See `snat` below.
module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.6' = {
  name: take('afwp-${uniqueString(name)}-${name}', 64)
  params: {
    name: 'afwp-${name}'
    location: location
    tier: skuTier
    // The AVM defaults this to 'Deny'. Threat intelligence-based filtering is a Standard and
    // Premium feature, and a Basic policy that sets it at all is rejected outright with
    // `FirewallPolicyHigherTierOnlyProperties`.
    threatIntelMode: skuTier == 'Basic' ? 'Off' : 'Deny'
    tags: tags
    enableTelemetry: enableTelemetry
    // Load-bearing, and the single least obvious setting in this repository.
    //
    // Azure Firewall does not SNAT when the destination is an RFC 1918 address. Left at that
    // default, a runner in the West US 3 spoke reaching a private endpoint in the Central US
    // platform spoke would arrive with its own 10.2.x.x source address, and the endpoint would
    // have no route back: the two spokes are not peered to each other.
    //
    // Setting the private ranges to 255.255.255.255/32 means "always SNAT", including to
    // private destinations. The private endpoint then sees this firewall's private IP, which
    // its own hub peering can already route back to, so the return path needs no route table
    // on the private endpoint subnet and no change to `privateEndpointNetworkPolicies` there.
    //
    // Do not "simplify" this to 0.0.0.0/0. That is the opposite setting - never SNAT - and it
    // stops the firewall reaching the internet at all.
    // https://learn.microsoft.com/azure/firewall/snat-private-range
    snat: {
      privateRanges: snatPrivateRanges
      // Explicit, because auto-learn would let route advertisements silently reintroduce the
      // RFC 1918 no-SNAT behaviour that the private ranges above exist to defeat.
      autoLearnPrivateRanges: 'Disabled'
    }
    ruleCollectionGroups: concat(
      empty(applicationRules)
        ? []
        : [
            {
              name: 'rcg-application'
              priority: 300
              ruleCollections: [
                {
                  name: 'allow-application'
                  priority: 300
                  ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
                  action: {
                    type: 'Allow'
                  }
                  rules: applicationRuleEntries
                }
              ]
            }
          ],
      empty(networkRules)
        ? []
        : [
            {
              name: 'rcg-network'
              priority: 400
              ruleCollections: [
                {
                  name: 'allow-network'
                  priority: 400
                  ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
                  action: {
                    type: 'Allow'
                  }
                  rules: networkRuleEntries
                }
              ]
            }
          ]
    )
  }
}

module firewall 'br/public:avm/res/network/azure-firewall:0.9.2' = {
  name: take('afw-${uniqueString(name)}-${name}', 64)
  params: {
    name: name
    location: location
    virtualNetworkResourceId: virtualNetworkResourceId
    azureSkuTier: skuTier
    availabilityZones: availabilityZones
    firewallPolicyId: firewallPolicy.outputs.resourceId
    publicIPAddressObject: {
      name: 'pip-${name}'
      skuName: 'Standard'
      publicIPAllocationMethod: 'Static'
      diagnosticSettings: firewallDiagnosticSettings
    }
    enableManagementNic: managementNicRequired
    managementIPAddressObject: managementNicRequired
      ? {
          name: 'pip-${name}-mgmt'
          skuName: 'Standard'
          publicIPAllocationMethod: 'Static'
          diagnosticSettings: firewallDiagnosticSettings
        }
      : {}
    tags: tags
    diagnosticSettings: firewallDiagnosticSettings
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the firewall.')
output resourceId string = firewall.outputs.resourceId

@description('Name of the firewall.')
output name string = firewall.outputs.name

@description('Private IP address of the firewall. This is the next hop for every user-defined route that sends traffic through it.')
output privateIp string = firewall.outputs.privateIp

@description('Resource ID of the firewall policy that carries the rule collections and the SNAT configuration.')
output policyResourceId string = firewallPolicy.outputs.resourceId
