targetScope = 'resourceGroup'

import { hubBastionType, hubNatGatewayType, hubSubnetType, jumpboxType, hubVirtualNetworkName, subnetNetworkSecurityGroupName, defaultPrivateEndpointNetworkPolicies } from '../types.bicep'

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

@description('Optional. NAT gateway attached to the jump box subnet. Omit to deploy the hub without one.')
param natGateway hubNatGatewayType?

@description('Optional. Subnet delegated to `Microsoft.App/environments` for the Container Apps environment that hosts self-hosted GitHub Actions runners. Omit to deploy the hub without one.')
param runnersSubnet hubSubnetType?

@description('Optional. Management jump boxes. Each lands in the jump box subnet with no public IP. Requires `jumpboxSubnet`.')
param jumpboxes jumpboxType[] = []

@description('Optional. Tags applied to every resource in the hub.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

var bastionEnabled = bastion != null && (bastion.?enabled ?? true)
var jumpboxEnabled = jumpboxSubnet != null && (jumpboxSubnet.?enabled ?? true)
var runnersEnabled = runnersSubnet != null && (runnersSubnet.?enabled ?? true)

// A jump box needs somewhere to land. Filtering here rather than failing means a hub can carry
// jump box definitions before the subnet exists; the jump boxes simply do not deploy, and
// infra/README.md states the requirement.
var jumpboxesToDeploy = jumpboxEnabled ? filter(jumpboxes, jumpbox => jumpbox.?enabled ?? true) : []

// The NAT gateway exists to give the jump box subnet a predictable outbound address, so it is
// only deployed when that subnet is.
var natGatewayEnabled = jumpboxEnabled && natGateway != null && (natGateway.?enabled ?? true)

var virtualNetworkName = hubVirtualNetworkName(name)
var natGatewayName = natGateway.?name ?? 'ng-${name}'
var natGatewayZone = natGateway.?availabilityZone ?? -1
var natGatewayOwnsPublicIp = empty(natGateway.?publicIpResourceIds ?? []) && empty(natGateway.?publicIpPrefixResourceIds ?? [])
var jumpboxSubnetName = jumpboxSubnet.?name ?? 'snet-jumpbox'
var runnersSubnetName = runnersSubnet.?name ?? 'snet-runners'

// Azure fixes this name. A Bastion host of any SKU other than Developer will not deploy
// without a subnet called exactly AzureBastionSubnet.
var bastionSubnetName = 'AzureBastionSubnet'

// Required rules from "Configure NSG rules for Azure Bastion". Applying an NSG to the
// AzureBastionSubnet is optional, but once one is present every rule below must exist or
// Bastion stops receiving platform updates and connectivity breaks.
module bastionNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = if (bastionEnabled) {
  name: 'nsg-${name}-bastion'
  params: {
    name: subnetNetworkSecurityGroupName(virtualNetworkName, 'bastion')
    location: location
    tags: tags
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

// Outbound rules follow "Network security groups for configuring a virtual network in Azure
// Container Apps" for a workload profile environment. They are stated explicitly so the
// environment keeps working if a deny-all rule or a firewall route is introduced later.
// No deny rule is added here: the platform default rules already block inbound from the
// internet, and self-hosted runners need broad outbound access to GitHub and package feeds.
module runnersNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = if (runnersEnabled) {
  name: 'nsg-${name}-runners'
  params: {
    name: subnetNetworkSecurityGroupName(virtualNetworkName, 'runners')
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
    securityRules: concat(
      [
      {
        name: 'AllowContainerAppsSubnetInbound'
        properties: {
          description: 'Communication between addresses inside the Container Apps subnet.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: runnersSubnet!.addressPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancerProbeInbound'
        properties: {
          description: 'Azure Load Balancer probes the Container Apps backend pools.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: runnersSubnet!.addressPrefix
          destinationPortRange: '30000-32767'
        }
      }
      {
        name: 'AllowContainerAppsSubnetOutbound'
        properties: {
          description: 'Communication between addresses inside the Container Apps subnet.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: runnersSubnet!.addressPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowMicrosoftContainerRegistryOutbound'
        properties: {
          description: 'Microsoft Artifact Registry, which serves the Container Apps system containers.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'MicrosoftContainerRegistry'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureFrontDoorFirstPartyOutbound'
        properties: {
          description: 'Dependency of the MicrosoftContainerRegistry service tag.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          protocol: 'Tcp'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureFrontDoor.FirstParty'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureActiveDirectoryOutbound'
        properties: {
          description: 'Managed identity token acquisition, including the federated identity a runner job uses.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          protocol: 'Tcp'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureMonitorOutbound'
        properties: {
          description: 'Container Apps diagnostics to Azure Monitor.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 140
          protocol: 'Tcp'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureContainerRegistryOutbound'
        properties: {
          description: 'Pull runner images from Azure Container Registry. Not required once the registry is reached through a private endpoint.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 150
          protocol: 'Tcp'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureContainerRegistry'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzurePlatformDnsOutbound'
        properties: {
          description: 'Azure DNS at 168.63.129.16. Container Apps does not function if this is denied.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 160
          protocol: '*'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '168.63.129.16'
          destinationPortRange: '53'
        }
      }
      {
        name: 'AllowGitHubHttpsOutbound'
        properties: {
          description: 'Self-hosted runners poll GitHub and download actions and packages over HTTPS.'
          access: 'Allow'
          direction: 'Outbound'
          priority: 200
          protocol: 'Tcp'
          sourceAddressPrefix: runnersSubnet!.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '443'
        }
      }
      ],
      // Appended. The Container Apps outbound requirements above are load-bearing: the
      // environment stops functioning if any of them is displaced.
      runnersSubnet.?securityRules ?? []
    )
  }
}

// A NAT gateway gives the jump box subnet explicit, static outbound SNAT instead of Azure's
// default outbound access, which uses an unpredictable address that cannot be allow-listed and
// is being retired. A NAT gateway is zonal or non-zonal - never zone-redundant - so its public
// IP must sit in the same zone.
module natGatewayResource 'br/public:avm/res/network/nat-gateway:2.1.1' = if (natGatewayEnabled) {
  name: 'ng-${name}'
  params: {
    name: natGatewayName
    location: location
    availabilityZone: natGatewayZone
    natGatewaySku: natGateway.?skuName ?? 'Standard'
    idleTimeoutInMinutes: natGateway.?idleTimeoutInMinutes ?? 4
    publicIpResourceIds: natGateway.?publicIpResourceIds
    publicIPPrefixResourceIds: natGateway.?publicIpPrefixResourceIds
    // Only create an address when none was supplied. A NAT gateway requires at least one
    // Standard SKU static public IP or prefix.
    publicIPAddresses: natGatewayOwnsPublicIp
      ? [
          {
            name: 'pip-${natGatewayName}'
            skuName: 'Standard'
            publicIPAllocationMethod: 'Static'
            availabilityZones: natGatewayZone == -1 ? [] : [natGatewayZone]
          }
        ]
      : null
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'vnet-${name}'
  params: {
    name: virtualNetworkName
    location: location
    addressPrefixes: addressPrefixes
    tags: tags
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
              natGatewayResourceId: natGatewayEnabled ? natGatewayResource!.outputs.resourceId : null
              privateEndpointNetworkPolicies: jumpboxSubnet.?privateEndpointNetworkPolicies ?? defaultPrivateEndpointNetworkPolicies
            }
          ]
        : [],
      runnersEnabled
        ? [
            {
              name: runnersSubnetName
              addressPrefix: runnersSubnet!.addressPrefix
              networkSecurityGroupResourceId: runnersNetworkSecurityGroup!.outputs.resourceId
              // Mandatory for a Container Apps workload profile environment.
              delegation: 'Microsoft.App/environments'
              privateEndpointNetworkPolicies: runnersSubnet.?privateEndpointNetworkPolicies ?? defaultPrivateEndpointNetworkPolicies
            }
          ]
        : []
    )
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
    }
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// One module per jump box, so adding a management host is a parameter change. Each lands in
// the jump box subnet, which is created above with an NSG that admits RDP and SSH from
// `AzureBastionSubnet` alone, and a NAT gateway for outbound.
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

@description('Resource ID of the Container Apps runners subnet, or an empty string when it is not deployed. Pass this as the infrastructure subnet of the Container Apps environment.')
output runnersSubnetResourceId string = runnersEnabled
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, runnersSubnetName)
  : ''

@description('Resource ID of the NAT gateway attached to the jump box subnet, or an empty string when it is not deployed.')
output natGatewayResourceId string = natGatewayEnabled ? natGatewayResource!.outputs.resourceId : ''

@description('The jump boxes that were deployed, with the private IP address to connect to through Bastion.')
output jumpboxes array = [
  for (jumpbox, index) in jumpboxesToDeploy: {
    name: jumpbox.name
    resourceId: jumpboxVirtualMachines[index].outputs.resourceId
    privateIPAddress: jumpboxVirtualMachines[index].outputs.privateIPAddress
    systemAssignedMIPrincipalId: jumpboxVirtualMachines[index].outputs.systemAssignedMIPrincipalId
  }
]
