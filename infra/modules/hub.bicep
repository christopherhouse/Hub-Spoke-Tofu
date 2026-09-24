targetScope = 'resourceGroup'

import { hubBastionType, hubFirewallType, hubSubnetType, jumpboxType, hubVirtualNetworkName, subnetNetworkSecurityGroupName, subnetRouteTableName, subnetRouteType, defaultPrivateEndpointNetworkPolicies } from '../types.bicep'

// Hub network for the hub-and-spoke topology.
//
// Composes AVM resource modules rather than avm/ptn/network/hub-networking: that pattern
// module is flagged ORPHANED in its own README (security and bug fixes only), and it assumes
// a mesh-peered multi-hub shape with firewall and route tables that this design keeps
// optional. See infra/README.md.

@description('Required. Short name of the hub. Resource names are derived from it.')
@minLength(1)
@maxLength(40)
param name string

@description('Optional. Azure region for the hub resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Address space of the hub virtual network.')
@minLength(1)
param addressPrefixes string[]

@description('Optional. Azure Bastion configuration. Omit to deploy the hub without Bastion.')
param bastion hubBastionType?

@description('Optional. Subnet for management jump boxes. Omit to deploy the hub without one.')
param jumpboxSubnet hubSubnetType?

@description('Optional. Azure Firewall for the hub. It is the next hop that makes spoke-to-spoke transit and centralised egress work. Omit to deploy the hub without one.')
param firewall hubFirewallType?

@description('Optional. Management jump boxes. Each lands in the jump box subnet with no public IP. Requires `jumpboxSubnet`.')
param jumpboxes jumpboxType[] = []

@description('Optional. Resource ID of the shared Log Analytics workspace that receives diagnostics from every hub resource. Empty to create no diagnostic settings. The workspace must already exist, because a diagnostic setting naming one that does not fails the deployment.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Tags applied to every resource in the hub.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

var bastionEnabled = bastion != null && (bastion.?enabled ?? true)
var jumpboxEnabled = jumpboxSubnet != null && (jumpboxSubnet.?enabled ?? true)
var firewallEnabled = firewall != null && (firewall.?enabled ?? true)

// One diagnostic setting shape, reused by every module below, so that turning diagnostics on
// or off is a single decision rather than a per-resource one.
var hubDiagnosticSettings = empty(logAnalyticsWorkspaceResourceId)
  ? null
  : [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]

// The NAT gateway that used to give the jump box subnet its outbound address is gone. Every
// subnet that needs egress now routes 0.0.0.0/0 to the firewall, which SNATs to its own public
// IP, so there is one egress point and one address to allow-list rather than two.
var virtualNetworkName = hubVirtualNetworkName(name)
var jumpboxSubnetName = jumpboxSubnet.?name ?? 'snet-jumpbox'
var firewallName = firewall.?name ?? 'afw-${name}'
var firewallSkuTier = firewall.?skuTier ?? 'Basic'

// Azure fixes these names. A Bastion host of any SKU other than Developer will not deploy
// without a subnet called exactly AzureBastionSubnet, and the firewall subnets are the same.
var bastionSubnetName = 'AzureBastionSubnet'
var firewallSubnetName = 'AzureFirewallSubnet'
var firewallManagementSubnetName = 'AzureFirewallManagementSubnet'

// The Basic SKU always deploys a management NIC and therefore always needs the management
// subnet. Standard and Premium only need one for forced tunnelling, which this design avoids.
var firewallManagementSubnetEnabled = firewallEnabled && firewall.?managementSubnetAddressPrefix != null

// The firewall's private IP is needed to build the route tables, but the route tables have to
// exist before the virtual network that references them, and the firewall cannot exist until
// its subnet does - a cycle. It is broken by computing the address instead of reading it back.
//
// Azure reserves the first four addresses of any subnet (network, gateway, and two for DNS),
// so the first assignable address is the subnet base plus four, and Azure Firewall takes the
// first assignable address in AzureFirewallSubnet. `cidrHost` is zero-based from base plus
// one, so index 3 is that address. The firewall module still outputs the real value, and that
// is what `firewallPrivateIp` returns for callers that are not caught by the cycle.
var firewallPrivateIpAddress = firewallEnabled ? cidrHost(firewall!.subnetAddressPrefix, 3) : ''

// Routes are declared symbolically so that no IP address is written into a parameter file.
// `HubFirewall` resolves here, at the one place that knows the address.
func resolveRoutes(routes subnetRouteType[], firewallIpAddress string) object[] =>
  map(routes, route => {
    name: route.name
    properties: {
      addressPrefix: route.addressPrefix
      nextHopType: route.nextHopType == 'HubFirewall' ? 'VirtualAppliance' : route.nextHopType
      nextHopIpAddress: route.nextHopType == 'HubFirewall'
        ? firewallIpAddress
        : route.?nextHopIpAddress
    }
  })

var jumpboxRoutes = jumpboxSubnet.?routes ?? []
var jumpboxRouteTableEnabled = jumpboxEnabled && !empty(jumpboxRoutes)

// A jump box needs somewhere to land. Filtering here rather than failing means a hub can carry
// jump box definitions before the subnet exists; the jump boxes simply do not deploy, and
// infra/README.md states the requirement.
var jumpboxesToDeploy = jumpboxEnabled ? filter(jumpboxes, jumpbox => jumpbox.?enabled ?? true) : []

// Required rules from "Configure NSG rules for Azure Bastion". Applying an NSG to the
// AzureBastionSubnet is optional, but once one is present every rule below must exist or
// Bastion stops receiving platform updates and connectivity breaks.
module bastionNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = if (bastionEnabled) {
  name: 'nsg-${name}-bastion'
  params: {
    name: subnetNetworkSecurityGroupName(virtualNetworkName, 'bastion')
    location: location
    tags: tags
    diagnosticSettings: hubDiagnosticSettings
    enableTelemetry: enableTelemetry
    securityRules: concat(
      [
      {
        name: 'AllowHttpsInbound'
        properties: {
          description: 'Browser sessions reach the Bastion host over HTTPS.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 120
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          description: 'Bastion control plane communicates with the host.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 130
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          description: 'Azure Load Balancer health probes.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 140
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          description: 'Internal communication between Bastion host components.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 150
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          description: 'Bastion reaches target virtual machines over private IP.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          description: 'Bastion writes diagnostic and metering logs to Azure public endpoints.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          description: 'Internal communication between Bastion host components.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          description: 'Session and certificate validation.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
      ],
      // Appended, never substituted. The rules above are the required Azure Bastion set; a
      // caller rule that displaced one would break connectivity and stop platform updates.
      bastion.?securityRules ?? []
    )
  }
}

// Jump boxes are reachable only through Bastion. No management port is exposed to the
// internet; the platform default rules deny that, and nothing here re-opens it.
module jumpboxNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = if (jumpboxEnabled) {
  name: 'nsg-${name}-jumpbox'
  params: {
    name: subnetNetworkSecurityGroupName(virtualNetworkName, 'jumpbox')
    location: location
    tags: tags
    diagnosticSettings: hubDiagnosticSettings
    enableTelemetry: enableTelemetry
    securityRules: concat(
      bastionEnabled
        ? [
            {
              name: 'AllowBastionRdpSshInbound'
              properties: {
                description: 'RDP and SSH from the AzureBastionSubnet only.'
                access: 'Allow'
                direction: 'Inbound'
                priority: 100
                protocol: 'Tcp'
                sourceAddressPrefix: bastion!.subnetAddressPrefix
                sourcePortRange: '*'
                destinationAddressPrefix: jumpboxSubnet!.addressPrefix
                destinationPortRanges: [
                  '22'
                  '3389'
                ]
              }
            }
          ]
        : [],
      jumpboxSubnet.?securityRules ?? []
    )
  }
}

// The route table must exist before the virtual network that references it, which is why the
// firewall private IP is computed rather than read back from the firewall module. See
// `firewallPrivateIpAddress` above.
//
// No route table is ever generated for AzureBastionSubnet or AzureFirewallSubnet. Bastion
// requires direct outbound internet access and stops working behind a default route, and a
// default route on the firewall subnet is forced tunnelling, which would blackhole the
// firewall's own egress. Neither subnet accepts routes from the parameter file, so this is
// structural rather than a convention someone has to remember.
module jumpboxRouteTable 'br/public:avm/res/network/route-table:0.5.0' = if (jumpboxRouteTableEnabled) {
  name: 'rt-${name}-jumpbox'
  params: {
    name: subnetRouteTableName(virtualNetworkName, 'jumpbox')
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
    routes: resolveRoutes(jumpboxRoutes, firewallPrivateIpAddress)
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'vnet-${name}'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: addressPrefixes
    tags: tags
    diagnosticSettings: hubDiagnosticSettings
    enableTelemetry: enableTelemetry
    subnets: concat(
      bastionEnabled
        ? [
            {
              name: bastionSubnetName
              addressPrefix: bastion!.subnetAddressPrefix
              networkSecurityGroupResourceId: bastionNetworkSecurityGroup!.outputs.resourceId
              privateEndpointNetworkPolicies: bastion.?privateEndpointNetworkPolicies ?? defaultPrivateEndpointNetworkPolicies
            }
          ]
        : [],
      jumpboxEnabled
        ? [
            {
              name: jumpboxSubnetName
              addressPrefix: jumpboxSubnet!.addressPrefix
              networkSecurityGroupResourceId: jumpboxNetworkSecurityGroup!.outputs.resourceId
              // Outbound goes through the hub firewall, via a 0.0.0.0/0 route, rather than
              // through a NAT gateway. One egress point, one allow-listable address.
              routeTableResourceId: jumpboxRouteTableEnabled ? jumpboxRouteTable!.outputs.resourceId : null
              privateEndpointNetworkPolicies: jumpboxSubnet.?privateEndpointNetworkPolicies ?? defaultPrivateEndpointNetworkPolicies
            }
          ]
        : [],
      // Azure fixes the name and requires /26 or larger. No NSG: Azure Firewall manages its
      // own subnet, and applying one is unsupported.
      firewallEnabled
        ? [
            {
              name: firewallSubnetName
              addressPrefix: firewall!.subnetAddressPrefix
            }
          ]
        : [],
      firewallManagementSubnetEnabled
        ? [
            {
              name: firewallManagementSubnetName
              addressPrefix: firewall!.managementSubnetAddressPrefix!
            }
          ]
        : []
    )
  }
}

// Deployed after the virtual network because it needs AzureFirewallSubnet to exist. Nothing
// in the hub routes through it at deployment time, so nothing depends on it in turn; the
// route tables use the computed address instead.
module firewallResource 'firewall.bicep' = if (firewallEnabled) {
  name: 'afw-${name}'
  params: {
    name: firewallName
    location: location
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    skuTier: firewallSkuTier
    availabilityZones: firewall.?availabilityZones ?? []
    applicationRules: firewall.?applicationRules ?? []
    networkRules: firewall.?networkRules ?? []
    snatPrivateRanges: firewall.?snatPrivateRanges ?? ['255.255.255.255/32']
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// Standard SKU, not Developer: Developer does not support virtual network peering, so it
// could only reach virtual machines in the hub itself. The module creates the required
// Standard SKU public IP from publicIPAddressObject.
module bastionHost 'br/public:avm/res/network/bastion-host:0.8.2' = if (bastionEnabled) {
  name: 'bas-${name}'
  params: {
    name: bastion.?name ?? 'bas-${name}'
    location: location
    virtualNetworkResourceId: virtualNetwork.outputs.resourceId
    skuName: bastion.?skuName ?? 'Standard'
    scaleUnits: bastion.?scaleUnits ?? 2
    availabilityZones: bastion.?availabilityZones ?? []
    publicIPAddressObject: {
      name: 'pip-${bastion.?name ?? 'bas-${name}'}'
      skuName: 'Standard'
      publicIPAllocationMethod: 'Static'
      diagnosticSettings: hubDiagnosticSettings
    }
    tags: tags
    diagnosticSettings: hubDiagnosticSettings
    enableTelemetry: enableTelemetry
  }
}

// One module per jump box, so adding a management host is a parameter change. Each lands in
// the jump box subnet, which is created above with an NSG that admits RDP and SSH from
// `AzureBastionSubnet` alone, and a route table that sends outbound through the firewall.
module jumpboxVirtualMachines 'jumpbox.bicep' = [
  for jumpbox in jumpboxesToDeploy: {
    // Deployment names are capped at 64 characters, and the jump box name is capped at 15.
    name: 'deploy-jb-${uniqueString(name, jumpbox.name)}'
    dependsOn: [
      // The subnet resource ID below is composed, not read from the virtual network module,
      // so nothing else orders the jump box behind the network that hosts it.
      virtualNetwork
    ]
    params: {
      name: jumpbox.name
      location: location
      subnetResourceId: resourceId(
        'Microsoft.Network/virtualNetworks/subnets',
        virtualNetworkName,
        jumpboxSubnetName
      )
      adminUsername: jumpbox.?adminUsername ?? 'azureadmin'
      vmSize: jumpbox.?vmSize ?? 'Standard_D4as_v7'
      availabilityZone: jumpbox.?availabilityZone ?? -1
      // Azure Edition, not `2025-datacenter-g2`: only an exact publisher/offer/SKU from the
      // automatic guest patching supported image list can use `AutomaticByPlatform`, and the
      // plain Generation 2 desktop SKU is not on it. See infra/modules/jumpbox.bicep.
      image: jumpbox.?image ?? {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-azure-edition'
        version: 'latest'
      }
      osDiskSizeGB: jumpbox.?osDiskSizeGB
      osDiskStorageAccountType: jumpbox.?osDiskStorageAccountType ?? 'Premium_LRS'
      entraLogin: jumpbox.?entraLogin ?? true
      enableAcceleratedNetworking: jumpbox.?enableAcceleratedNetworking ?? false
      autoShutdown: jumpbox.?autoShutdown ?? {}
      bootstrap: jumpbox.?bootstrap ?? {}
      tags: jumpbox.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

@description('Resource ID of the hub virtual network.')
output virtualNetworkResourceId string = virtualNetwork.outputs.resourceId

@description('Name of the hub virtual network.')
output virtualNetworkName string = virtualNetwork.outputs.name

@description('Address space of the hub virtual network.')
output addressPrefixes string[] = addressPrefixes

@description('Location the hub was deployed into.')
output location string = location

@description('Resource ID of the AzureBastionSubnet, or an empty string when Bastion is not deployed.')
output bastionSubnetResourceId string = bastionEnabled
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, bastionSubnetName)
  : ''

@description('Resource ID of the Azure Bastion host, or an empty string when Bastion is not deployed.')
output bastionResourceId string = bastionEnabled ? bastionHost!.outputs.resourceId : ''

@description('Resource ID of the jump box subnet, or an empty string when it is not deployed.')
output jumpboxSubnetResourceId string = jumpboxEnabled
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, jumpboxSubnetName)
  : ''

@description('Resource ID of the Azure Firewall, or an empty string when it is not deployed.')
output firewallResourceId string = firewallEnabled ? firewallResource!.outputs.resourceId : ''

@description('Private IP address of the Azure Firewall, or an empty string when it is not deployed. This is the next hop for every route that transits the hub. Read back from the firewall itself, so a caller outside this module gets the real address rather than the computed one.')
output firewallPrivateIp string = firewallEnabled ? firewallResource!.outputs.privateIp : ''

@description('The jump boxes that were deployed, with the private IP address to connect to through Bastion.')
output jumpboxes array = [
  for (jumpbox, index) in jumpboxesToDeploy: {
    name: jumpbox.name
    resourceId: jumpboxVirtualMachines[index].outputs.resourceId
    privateIPAddress: jumpboxVirtualMachines[index].outputs.privateIPAddress
    systemAssignedMIPrincipalId: jumpboxVirtualMachines[index].outputs.systemAssignedMIPrincipalId
  }
]
