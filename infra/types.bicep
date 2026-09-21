// Shared user-defined types for the hub-and-spoke topology.
//
// Topology is data: every hub is an entry in the `hubs` parameter of infra/main.bicep, and
// every spoke an entry in `spokes`, so adding either - in another region, resource group, or
// subscription - is a parameter change rather than a template change.

// Re-exported so every subnet type shares one strongly typed rule shape and the NSG module
// version is pinned in a single place. Callers get IntelliSense and compile-time validation
// of security rules written in a .bicepparam file, instead of an untyped array whose mistakes
// only surface at deployment.
import { securityRuleType } from 'br/public:avm/res/network/network-security-group:0.5.3'

@export()
@description('Optional. An NSG security rule. Re-exported from the Azure Verified Module so hub and spoke subnets share one definition.')
type subnetSecurityRuleType = securityRuleType

@export()
@description('Optional. Whether NSGs and route tables apply to private endpoints in a subnet.')
type subnetPrivateEndpointNetworkPoliciesType =
  | 'Disabled'
  | 'Enabled'
  | 'NetworkSecurityGroupEnabled'
  | 'RouteTableEnabled'

// Always sent explicitly, never left to the Azure Resource Manager default. Recent subnet API
// versions changed that default from `Disabled` to `Enabled`, so a template that omits the
// property produces a permanent what-if difference against any subnet created before the
// change, and its value silently depends on the module version in use. `Disabled` matches
// both the documented ARM default and the deployed subnets. See infra/README.md.
@export()
@description('Optional. Default private endpoint network policies applied to every subnet that does not override it.')
var defaultPrivateEndpointNetworkPolicies = 'Disabled'

@export()
@description('Returns the virtual network name a hub of the given name deploys. Single source of the convention, so callers can build a hub virtual network resource ID without reading the hub module outputs.')
func hubVirtualNetworkName(hubName string) string => 'vnet-${hubName}'

@export()
@description('Returns the virtual network name a spoke of the given name deploys. Single source of the convention, so callers can build a spoke virtual network resource ID without reading the spoke module outputs.')
func spokeVirtualNetworkName(spokeName string) string => 'vnet-${spokeName}'

@export()
@description('Returns the name of the network security group attached to a subnet. Every subnet gets its own, so rules can be added later without adding infrastructure. The suffix is a short purpose label: hub subnets pass `bastion`, `jumpbox` or `runners`, and spoke subnets pass the subnet name, whose purpose is already in it. Azure limits the name to 80 characters.')
func subnetNetworkSecurityGroupName(virtualNetworkName string, suffix string) string =>
  'nsg-${virtualNetworkName}-${suffix}'

@export()
@description('Optional. Azure Bastion configuration for a hub. Bastion Standard is used so that the host can reach virtual machines in peered spokes; the Developer SKU cannot peer.')
type hubBastionType = {
  @description('Optional. Deploy Azure Bastion into the hub. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Name of the Bastion host. Defaults to `bas-<hub name>`.')
  @minLength(1)
  @maxLength(80)
  name: string?

  @description('Optional. Bastion SKU. Defaults to `Standard`. `Developer` is deliberately excluded: it supports neither a dedicated subnet nor virtual network peering, so it cannot reach spoke virtual machines.')
  skuName: ('Basic' | 'Standard' | 'Premium')?

  @description('Required. Address prefix for the `AzureBastionSubnet`. Azure requires /26 or larger for Bastion resources created after 2 November 2021.')
  @minLength(9)
  subnetAddressPrefix: string

  @description('Optional. Availability zones for the Bastion host and its public IP. Empty by default because zonal Bastion is not available in every region.')
  availabilityZones: (1 | 2 | 3)[]?

  @description('Optional. Scale units for the Bastion host. Only honoured by the Standard and Premium SKUs. Defaults to `2`.')
  @minValue(2)
  @maxValue(50)
  scaleUnits: int?

  @description('Optional. Extra security rules appended to the `AzureBastionSubnet` NSG. The required Azure Bastion rule set is always present and is never replaced; removing any of it breaks connectivity and blocks platform updates. Generated rules occupy priorities 120-150, so use 300 or above.')
  securityRules: subnetSecurityRuleType[]?

  @description('Optional. Private endpoint network policies for the `AzureBastionSubnet`. Defaults to `Disabled`. The subnet is dedicated to Bastion and hosts no private endpoints, so this only exists to keep the value explicit.')
  privateEndpointNetworkPolicies: subnetPrivateEndpointNetworkPoliciesType?
}

@export()
@description('Optional. NAT gateway for a hub. It is attached to the jump box subnet so that outbound traffic leaves through a known, static public IP rather than an ephemeral default-outbound address. Azure requires a Standard SKU static public IP for a NAT gateway.')
type hubNatGatewayType = {
  @description('Optional. Deploy the NAT gateway. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Name of the NAT gateway. Defaults to `ng-<hub name>`.')
  @minLength(1)
  @maxLength(80)
  name: string?

  @description('Optional. NAT gateway SKU. Defaults to `Standard`.')
  skuName: ('Standard' | 'StandardV2')?

  @description('Optional. Availability zone for the NAT gateway and its public IP. A NAT gateway is either zonal or non-zonal; it cannot be zone-redundant. Defaults to `-1`, meaning no zone.')
  availabilityZone: (-1 | 1 | 2 | 3)?

  @description('Optional. Idle timeout of the outbound flows, in minutes. Defaults to `4`.')
  @minValue(4)
  @maxValue(120)
  idleTimeoutInMinutes: int?

  @description('Optional. Resource IDs of existing public IP addresses to attach. Supply these to keep an already allow-listed address. When omitted, one Standard static public IP is created.')
  publicIpResourceIds: string[]?

  @description('Optional. Resource IDs of existing public IP prefixes to attach. Use a prefix when a contiguous, allow-listable range of outbound addresses is required.')
  publicIpPrefixResourceIds: string[]?
}

@export()
@description('Optional. A plain hub subnet defined by name and address prefix.')
type hubSubnetType = {
  @description('Optional. Create the subnet. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Name of the subnet. A per-subnet default is applied when omitted.')
  @minLength(1)
  @maxLength(80)
  name: string?

  @description('Required. Address prefix for the subnet, in CIDR notation.')
  @minLength(9)
  addressPrefix: string

  @description('Optional. Extra security rules appended to this subnet\'s NSG. Every subnet gets its own NSG, so rules can be added here without any template change. The rules generated for the subnet are always kept; see the reserved priority ranges in infra/README.md.')
  securityRules: subnetSecurityRuleType[]?

  @description('Optional. Private endpoint network policies for the subnet. Defaults to `Disabled`. Set `Enabled` on a subnet that hosts private endpoints and whose NSG or route table must apply to them.')
  privateEndpointNetworkPolicies: subnetPrivateEndpointNetworkPoliciesType?
}

@export()
@description('Optional. Marketplace image for a jump box. Defaults to Windows Server 2025 Datacenter, Generation 2, with the desktop experience.')
type jumpboxImageType = {
  @description('Required. Image publisher, for example `MicrosoftWindowsServer`.')
  @minLength(1)
  publisher: string

  @description('Required. Image offer, for example `WindowsServer`.')
  @minLength(1)
  offer: string

  @description('Required. Image SKU. It must be a Generation 2 SKU, because Trusted Launch is not available on Generation 1, and it must appear on the Azure automatic guest patching supported image list. `2025-datacenter-azure-edition` is the desktop experience; `2025-datacenter-azure-edition-core` is Server Core. Note that `2025-datacenter-g2` is Generation 2 but is NOT supported for automatic guest patching.')
  @minLength(1)
  sku: string

  @description('Optional. Image version. Defaults to `latest`. A virtual machine is not re-imaged when a newer version is published, so this only affects a rebuild.')
  version: string?
}

@export()
@description('Optional. Auto-shutdown schedule for a jump box. It creates a `Microsoft.DevTestLab/schedules` resource, which deallocates the virtual machine so it stops billing for compute.')
type jumpboxAutoShutdownType = {
  @description('Optional. Enable the schedule. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Time of day to shut down, as a 24-hour `HHmm` string. Defaults to `1800`.')
  @minLength(4)
  @maxLength(4)
  time: string?

  @description('Optional. Windows time zone ID the time is expressed in, for example `Central Standard Time`. Defaults to `Central Standard Time`. A Windows ID is used rather than an IANA one, and it covers daylight saving, so the schedule follows the local clock.')
  timeZone: string?
}

@export()
@description('Optional. First-boot tooling for a jump box, installed by a run command. It re-runs on every deployment, so the package list is kept current rather than applied once.')
type jumpboxBootstrapType = {
  @description('Optional. Install the tooling. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Chocolatey package IDs to install. Defaults to the standard platform-engineering set. Chocolatey is used because Windows Server ships no package manager of its own.')
  packages: string[]?

  @description('Optional. Install the Az PowerShell module from the PowerShell Gallery. Defaults to `true`. It is not a Chocolatey package because the Gallery is its first-party source.')
  installAzPowerShell: bool?

  @description('Optional. How long the bootstrap may run before Azure abandons it, in seconds. Defaults to `3600`. A cold install of the full package set is slow.')
  @minValue(300)
  @maxValue(5400)
  timeoutInSeconds: int?
}

@export()
@description('Required. A management jump box in a hub. It lands in the hub jump box subnet, has no public IP, and is reachable only through Azure Bastion.')
type jumpboxType = {
  @description('Required. Name of the virtual machine. It is used verbatim, as both the Azure resource name and the Windows computer name, so it is capped at the 15-character NetBIOS limit rather than Azure\'s longer one.')
  @minLength(1)
  @maxLength(15)
  name: string

  @description('Optional. Deploy the jump box. Defaults to `true`. Set `false` to keep the definition but remove the virtual machine.')
  enabled: bool?

  @description('Optional. Virtual machine size. Defaults to `Standard_D4as_v7`. Availability is regional: the burstable x64 B-series is not offered in every region, so check with `az vm list-skus` before changing it.')
  @minLength(1)
  vmSize: string?

  @description('Optional. Availability zone. Defaults to `-1`, meaning no zone. A single jump box gains nothing from a zone, and pinning one limits which sizes can be used.')
  availabilityZone: (-1 | 1 | 2 | 3)?

  @description('Optional. Marketplace image. Defaults to Windows Server 2025 Datacenter Generation 2 with the desktop experience.')
  image: jumpboxImageType?

  @description('Optional. OS disk size in GB. Defaults to the image default when omitted.')
  @minValue(30)
  @maxValue(4095)
  osDiskSizeGB: int?

  @description('Optional. OS disk storage type. Defaults to `Premium_LRS`.')
  osDiskStorageAccountType: ('PremiumV2_LRS' | 'Premium_LRS' | 'Premium_ZRS' | 'StandardSSD_LRS' | 'StandardSSD_ZRS' | 'Standard_LRS')?

  @description('Optional. Name of the local administrator account. Defaults to `azureadmin`. Its password is generated at deployment time and deliberately never stored or returned: ordinary sign-in is with Entra ID, and the break-glass path is a password reset through the VMAccess extension. See infra/README.md.')
  @minLength(1)
  @maxLength(20)
  adminUsername: string?

  @description('Optional. Install the Entra ID login extension, so the virtual machine accepts Entra credentials over Bastion. Defaults to `true`. Sign-in additionally needs the `Virtual Machine Administrator Login` or `Virtual Machine User Login` role, which this deployment cannot assign; see infra/README.md.')
  entraLogin: bool?

  @description('Optional. Enable accelerated networking on the network interface. Defaults to `false`. Not every size supports it, and a jump box is not throughput-bound.')
  enableAcceleratedNetworking: bool?

  @description('Optional. Auto-shutdown schedule. Defaults to 18:00 Central, daily. Set `enabled: false` to leave the jump box running.')
  autoShutdown: jumpboxAutoShutdownType?

  @description('Optional. First-boot tooling. Omit to take the default package set.')
  bootstrap: jumpboxBootstrapType?

  @description('Optional. Tags applied to the jump box and its network interface. Defaults to the hub tags.')
  tags: object?
}

@export()
@description('Required. A hub in the hub-and-spoke topology.')
type hubType = {
  @description('Required. Short name of the hub. Resource names are derived from it, for example `vnet-<name>` and `bas-<name>`.')
  @minLength(1)
  @maxLength(40)
  name: string

  @description('Required. Azure region for the hub.')
  @minLength(1)
  location: string

  @description('Optional. Subscription that hosts the hub. Defaults to the subscription the deployment targets. Set this to place a hub in another subscription of the same tenant.')
  @minLength(36)
  @maxLength(36)
  subscriptionId: string?

  @description('Required. Resource group that holds the hub. It is created by the deployment.')
  @minLength(1)
  @maxLength(90)
  resourceGroupName: string

  @description('Required. Address space of the hub virtual network. Must not overlap any other hub or spoke.')
  @minLength(1)
  addressPrefixes: string[]

  @description('Optional. Azure Bastion configuration. Omit to deploy the hub without Bastion.')
  bastion: hubBastionType?

  @description('Optional. Subnet for management jump boxes. Omit to deploy the hub without one.')
  jumpboxSubnet: hubSubnetType?

  @description('Optional. NAT gateway attached to the jump box subnet. Omit to deploy the hub without one, in which case jump boxes fall back to Azure default outbound access.')
  natGateway: hubNatGatewayType?

  @description('Optional. Subnet for the Azure Container Apps environment that hosts self-hosted GitHub Actions runners. Delegated to `Microsoft.App/environments`. A workload profile environment requires /27 or larger, and the prefix cannot be changed once an environment exists in it.')
  runnersSubnet: hubSubnetType?

  @description('Optional. Management jump boxes in the hub. Each one lands in the jump box subnet with no public IP and is reachable only through Bastion. Requires `jumpboxSubnet`.')
  jumpboxes: jumpboxType[]?

  @description('Optional. Tags applied to the hub resource group and every hub resource.')
  tags: object?
}

@export()
@description('Required. A subnet in a spoke virtual network. A spoke is a workload landing zone, so its subnets are not knowable in advance and are supplied as data.')
type spokeSubnetType = {
  @description('Required. Name of the subnet.')
  @minLength(1)
  @maxLength(80)
  name: string

  @description('Required. Address prefix for the subnet, in CIDR notation. Must fall inside the spoke address space and must not overlap another subnet.')
  @minLength(9)
  addressPrefix: string

  @description('Optional. Allow RDP and SSH inbound from the hub `AzureBastionSubnet` prefix. Defaults to `true`, because Bastion can only reach a peered spoke virtual machine if the subnet NSG admits it. Set `false` for subnets that host no virtual machines, such as a private endpoint subnet, to keep the rule set minimal. Ignored when the hub has no Bastion.')
  allowBastionAccess: bool?

  @description('Optional. Service delegation for the subnet, for example `Microsoft.App/environments`. A delegated subnet is dedicated to that service.')
  delegation: string?

  @description('Optional. Service endpoints to enable on the subnet, for example `Microsoft.Storage`. Prefer private endpoints where the service supports them.')
  serviceEndpoints: string[]?

  @description('Optional. Private endpoint network policies for the subnet. Defaults to `Disabled`. Set `Enabled` on a subnet that hosts private endpoints and whose NSG or route table must apply to them.')
  privateEndpointNetworkPolicies: subnetPrivateEndpointNetworkPoliciesType?

  @description('Optional. Extra security rules appended to this subnet\'s NSG. The generated Bastion rule occupies priority 100, so use 200 or above.')
  securityRules: subnetSecurityRuleType[]?
}

@export()
@description('Optional. Peering options for the link between a spoke and its hub. The defaults suit a traditional bidirectional peering with no gateway; override them only for a specific reason.')
type spokePeeringType = {
  @description('Optional. Allow traffic forwarded by a network virtual appliance, rather than originated in the peer. Defaults to `true`, which is inert until a hub firewall exists and avoids having to re-peer when one is introduced.')
  allowForwardedTraffic: bool?

  @description('Optional. Let the spoke use a gateway in the hub. Defaults to `false`. Setting it before the hub has a VPN or ExpressRoute gateway fails the peering outright. When a hub gateway lands, set this on the spoke and `allowHubGatewayTransit` alongside it.')
  useRemoteGateways: bool?

  @description('Optional. Let the hub share its gateway with this spoke. Defaults to `false`. Set it together with `useRemoteGateways` once a hub gateway exists.')
  allowHubGatewayTransit: bool?
}

@export()
@description('Required. A spoke in the hub-and-spoke topology.')
type spokeType = {
  @description('Required. Short name of the spoke. Resource names are derived from it, for example `vnet-<name>`.')
  @minLength(1)
  @maxLength(40)
  name: string

  @description('Required. Name of the hub this spoke peers with. Must match the `name` of an entry in the `hubs` parameter. Each spoke references exactly one hub; peering is not transitive, so spoke-to-spoke traffic needs a hub firewall or route tables, which this design keeps optional.')
  @minLength(1)
  @maxLength(40)
  hubName: string

  @description('Required. Azure region for the spoke. It does not have to match its hub; peering works across regions.')
  @minLength(1)
  location: string

  @description('Optional. Subscription that hosts the spoke. Defaults to the subscription the deployment targets. Set this to place a spoke in another subscription of the same tenant. The deployment identity needs Contributor there; add it to `targetSubscriptionIds` in infra/bootstrap and redeploy that template by hand.')
  @minLength(36)
  @maxLength(36)
  subscriptionId: string?

  @description('Required. Resource group that holds the spoke. It is created by the deployment.')
  @minLength(1)
  @maxLength(90)
  resourceGroupName: string

  @description('Required. Address space of the spoke virtual network. Must not overlap any hub or any other spoke.')
  @minLength(1)
  addressPrefixes: string[]

  @description('Optional. Subnets in the spoke. Each one gets its own network security group, so rules can be added later without adding infrastructure.')
  subnets: spokeSubnetType[]?

  @description('Optional. Peering options for the link to the hub. Omit to take the defaults, which suit a bidirectional peering with no gateway.')
  peering: spokePeeringType?

  @description('Optional. Tags applied to the spoke resource group and every spoke resource.')
  tags: object?
}
