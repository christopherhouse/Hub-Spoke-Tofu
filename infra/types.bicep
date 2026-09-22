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
@description('Returns the name of the route table attached to a subnet. A route table is only created for a subnet that declares routes, so unlike the network security group convention this is not applied to every subnet. Azure limits the name to 80 characters.')
func subnetRouteTableName(virtualNetworkName string, suffix string) string =>
  'rt-${virtualNetworkName}-${suffix}'

// The hub firewall is the next hop for transit routing, but its private IP is not known when
// the route tables are built: a route table must exist before the virtual network that
// references it, and the firewall cannot exist until its subnet does. Naming the firewall
// symbolically here breaks that cycle and keeps IP addresses out of the parameter file.
@export()
@description('Required. Next hop for a route. `HubFirewall` is resolved by the template to the private IP of the hub firewall, so no address is hand-copied into a parameter file; it requires the hub to define `firewall`. The remaining values are the Azure next hop types, and `VirtualAppliance` requires `nextHopIpAddress`.')
type subnetRouteNextHopType =
  | 'HubFirewall'
  | 'VirtualAppliance'
  | 'VirtualNetworkGateway'
  | 'VnetLocal'
  | 'Internet'
  | 'None'

@export()
@description('Optional. A user-defined route in a subnet route table.')
type subnetRouteType = {
  @description('Required. Name of the route.')
  @minLength(1)
  @maxLength(80)
  name: string

  @description('Required. Destination prefix the route applies to, in CIDR notation. `0.0.0.0/0` sends all otherwise-unmatched traffic to the next hop.')
  @minLength(7)
  addressPrefix: string

  @description('Required. Next hop for traffic matching the prefix. Prefer `HubFirewall`, which resolves to the hub firewall private IP.')
  nextHopType: subnetRouteNextHopType

  @description('Optional. Next hop IP address. Required when `nextHopType` is `VirtualAppliance`, and ignored otherwise. Leave it unset for `HubFirewall`, which supplies the address itself.')
  nextHopIpAddress: string?
}

@export()
@description('Optional. Azure Firewall in a hub. It is the next hop that makes spoke-to-spoke transit and centralised egress work: virtual network peering is not transitive, so without an appliance in the hub a spoke can only reach its hub and not another spoke. Requires a dedicated subnet named exactly `AzureFirewallSubnet`, sized /26 or larger.')
type hubFirewallType = {
  @description('Optional. Deploy the firewall. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Name of the firewall. Defaults to `afw-<hub name>`.')
  @minLength(1)
  @maxLength(80)
  name: string?

  @description('Required. Address prefix for `AzureFirewallSubnet`, in CIDR notation. Azure requires /26 or larger. The subnet name is fixed by Azure and cannot be changed.')
  @minLength(9)
  subnetAddressPrefix: string

  @description('Optional. Address prefix for `AzureFirewallManagementSubnet`, in CIDR notation, /26 or larger. Required by the `Basic` SKU, which always deploys a management NIC, and otherwise only needed for forced tunnelling. The subnet name is fixed by Azure.')
  @minLength(9)
  managementSubnetAddressPrefix: string?

  @description('Optional. Firewall SKU tier. Defaults to `Basic`, which is sufficient for transit and egress filtering with application rules and costs roughly a third of `Standard`. `Basic` is throughput-limited to around 250 Mbps and always requires `managementSubnetAddressPrefix`.')
  skuTier: ('Basic' | 'Standard' | 'Premium')?

  @description('Optional. Availability zones for the firewall. Defaults to `[]`, meaning no zone. Zone redundancy costs nothing for the firewall itself but does incur inter-zone data transfer.')
  availabilityZones: (1 | 2 | 3)[]?

  @description('Optional. Application rules, evaluated before network rules and always SNATed by Azure Firewall. Prefer these for traffic destined to a private endpoint. Defaults to an empty collection.')
  applicationRules: firewallApplicationRuleType[]?

  @description('Optional. Network rules, matched on address or service tag rather than FQDN. These are only SNATed when the destination falls outside `snatPrivateRanges`. Defaults to an empty collection.')
  networkRules: firewallNetworkRuleType[]?

  @description('Optional. Destination ranges the firewall treats as private and therefore does **not** SNAT. Defaults to `[\'255.255.255.255/32\']`, which means always SNAT, including to private addresses. That default is load-bearing: it lets a spoke reach a private endpoint in another spoke, because the endpoint then sees the firewall private IP, which its own hub peering can already route back to. Setting `0.0.0.0/0` is the opposite - never SNAT - and stops the firewall reaching the internet.')
  snatPrivateRanges: string[]?
}

@export()
@description('Optional. An Azure Firewall application rule, matched on destination FQDN. Azure Firewall always SNATs traffic processed by application rules, which is why Microsoft recommends them over network rules for traffic destined to a private endpoint.')
type firewallApplicationRuleType = {
  @description('Required. Name of the rule.')
  @minLength(1)
  name: string

  @description('Required. Source address prefixes the rule applies to.')
  @minLength(1)
  sourceAddresses: string[]

  @description('Optional. Destination FQDNs, for example `mcr.microsoft.com` or `*.data.mcr.microsoft.com`.')
  targetFqdns: string[]?

  @description('Optional. Destination FQDN tags, for example `WindowsUpdate`. A rule uses either `targetFqdns` or `fqdnTags`, never both.')
  fqdnTags: string[]?

  @description('Optional. Protocols and ports the rule allows. Defaults to HTTPS on 443.')
  protocols: firewallApplicationProtocolType[]?
}

@export()
@description('Optional. A protocol and port pair for an Azure Firewall application rule.')
type firewallApplicationProtocolType = {
  @description('Required. Protocol type.')
  protocolType: ('Http' | 'Https' | 'Mssql')

  @description('Required. Destination port.')
  @minValue(1)
  @maxValue(65535)
  port: int
}

@export()
@description('Optional. An Azure Firewall network rule, matched on destination address or service tag.')
type firewallNetworkRuleType = {
  @description('Required. Name of the rule.')
  @minLength(1)
  name: string

  @description('Required. Source address prefixes the rule applies to.')
  @minLength(1)
  sourceAddresses: string[]

  @description('Required. Destination addresses, prefixes or service tags, for example `AzureActiveDirectory`.')
  @minLength(1)
  destinationAddresses: string[]

  @description('Required. Destination ports.')
  @minLength(1)
  destinationPorts: string[]

  @description('Optional. IP protocols the rule allows. Defaults to TCP.')
  protocols: ('TCP' | 'UDP' | 'ICMP' | 'Any')[]?
}

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

  @description('Optional. User-defined routes for this subnet. A route table is created and associated only when routes are supplied. Use `nextHopType: \'HubFirewall\'` to send traffic through the hub firewall. Never add a `0.0.0.0/0` route to `AzureBastionSubnet`, which requires direct internet access, or to `AzureFirewallSubnet`, where it is forced tunnelling.')
  routes: subnetRouteType[]?

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

  @description('Optional. Azure Firewall for the hub. It is the next hop that makes spoke-to-spoke transit and centralised egress work, because virtual network peering is not transitive. Omit to deploy the hub without one, in which case no subnet can route through it.')
  firewall: hubFirewallType?

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

  @description('Optional. User-defined routes for this subnet. A route table is created and associated only when routes are supplied. Use `nextHopType: \'HubFirewall\'` to send traffic through the hub firewall, which is how a spoke reaches another spoke: peering is not transitive, so without it a spoke can only reach its hub.')
  routes: subnetRouteType[]?

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

// ---------------------------------------------------------------------------------------
// Shared platform services
//
// Log Analytics, Key Vault and the container registry are regional shared services, not
// connectivity. They land in a spoke named by `spokeName` rather than in the hub, so the hub
// stays connectivity-only, and they inherit that spoke's location, subscription and resource
// group instead of restating them.
// ---------------------------------------------------------------------------------------

@export()
@description('Optional. Shared Log Analytics workspace for a region. Every resource in the deployment sends its diagnostics here. It is deliberately reachable over its public endpoint: there is no Azure Monitor Private Link Scope in this design, and adding one would silently break ingestion from anything outside the scope.')
type platformLogAnalyticsType = {
  @description('Optional. Deploy the workspace. Defaults to `true`. Setting `false` also disables diagnostic settings everywhere, because there is nowhere to send them.')
  enabled: bool?

  @description('Optional. Name of the workspace. Defaults to `log-<platform name>`.')
  @minLength(4)
  @maxLength(63)
  name: string?

  @description('Optional. Retention in days. Defaults to `30`, the amount included at no extra charge.')
  @minValue(30)
  @maxValue(730)
  dataRetention: int?

  @description('Optional. Daily ingestion cap in GB, as a string so fractional values such as `0.5` work. Defaults to `1`, which is a guard rail against a runaway diagnostic source rather than a capacity plan. Set `-1` to remove the cap.')
  @minLength(1)
  dailyQuotaGb: string?
}

@export()
@description('Optional. Shared Key Vault for a region. It holds the CI/CD credentials the Container Apps runner jobs need, is reachable only over a private endpoint, and uses Azure RBAC rather than access policies.')
type platformKeyVaultType = {
  @description('Optional. Deploy the vault. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Name of the vault. Defaults to `kv-<platform name>-<suffix>`, where the suffix is derived from the subscription and the platform stamp name. Key Vault names share a single namespace across every Azure tenant, so a readable name is usually already taken; the derived suffix makes one unique without it becoming a decision, and is stable across redeployments. Supply a name only to adopt a vault that already exists.')
  @minLength(3)
  @maxLength(24)
  name: string?

  @description('Optional. SKU. Defaults to `standard`. `premium` only adds HSM-backed keys, which nothing here uses.')
  skuName: ('standard' | 'premium')?

  @description('Optional. Days a soft-deleted vault is recoverable. Defaults to `90`. Purge protection is always on, so this cannot be shortened after the fact.')
  @minValue(7)
  @maxValue(90)
  softDeleteRetentionInDays: int?
}

@export()
@description('Optional. Shared Azure Container Registry for a region. It holds the self-hosted runner image. Premium is required, because only Premium supports private endpoints.')
type platformContainerRegistryType = {
  @description('Optional. Deploy the registry. Defaults to `true`.')
  enabled: bool?

  @description('Optional. Name of the registry. Defaults to `acr<platform name><suffix>`, with hyphens stripped because registry names allow lowercase alphanumerics only, and the same derived suffix the Key Vault uses. Registry names share a single namespace across every Azure tenant. Supply a name only to adopt a registry that already exists.')
  @minLength(5)
  @maxLength(50)
  name: string?

  @description('Optional. Public IP ranges allowed to reach the registry data plane, in CIDR notation. This exists for one reason: `az acr build` runs on Microsoft-managed ACR Tasks compute outside the virtual network, and a registry with public network access fully disabled rejects it. Supply the IPv4 prefixes of the `AzureContainerRegistry.<region>` service tag. Everything else is denied, and runners pull over the private endpoint. See infra/README.md for the refresh command.')
  allowedPublicIpRanges: string[]?

  @description('Optional. Retention in days for untagged manifests. Defaults to `7`. Every runner image build supersedes the last, so untagged layers would otherwise accumulate forever.')
  @minValue(0)
  @maxValue(365)
  untaggedManifestRetentionDays: int?
}

@export()
@description('Optional. Shared platform services for a region. They land in the spoke named by `spokeName`, and inherit its location, subscription and resource group.')
type platformType = {
  @description('Required. Short name of the platform stamp. Resource names are derived from it, for example `log-<name>` and `id-<name>-runner`.')
  @minLength(1)
  @maxLength(40)
  name: string

  @description('Required. Name of the spoke that hosts these services. Must match the `name` of an entry in the `spokes` parameter. The spoke supplies the location, subscription and resource group, so none of them is restated here.')
  @minLength(1)
  @maxLength(40)
  spokeName: string

  @description('Required. Name of the subnet in that spoke that private endpoints land in. Must match a subnet defined on the spoke, and that subnet should carry `allowBastionAccess: false` because it hosts no virtual machines.')
  @minLength(1)
  @maxLength(80)
  privateEndpointSubnetName: string

  @description('Optional. Shared Log Analytics workspace. Omit to take the defaults.')
  logAnalytics: platformLogAnalyticsType?

  @description('Optional. Shared Key Vault. Omit to deploy the platform without one, in which case the runner jobs have nowhere to read their GitHub App key from.')
  keyVault: platformKeyVaultType?

  @description('Optional. Shared container registry. Omit to deploy the platform without one, in which case there is nowhere to publish the runner image.')
  containerRegistry: platformContainerRegistryType?

  @description('Optional. Tags applied to every platform resource. Defaults to the deployment tags.')
  tags: object?
}

// ---------------------------------------------------------------------------------------
// Self-hosted CI/CD runners
// ---------------------------------------------------------------------------------------

@export()
@description('Returns the name of the Container Apps environment deployed for a spoke of the given name. Single source of the convention, so a caller can compose the resource ID without reading the module outputs.')
func containerAppsEnvironmentName(spokeName string) string => 'cae-${spokeName}'

@export()
@description('Optional. The Azure Container Apps environment that hosts the self-hosted runner jobs. It lands in a spoke subnet, which must exist and be delegated to `Microsoft.App/environments`. It is deliberately not in the hub: a hub is a connectivity landing zone and should not host workload compute.')
type containerAppsEnvironmentType = {
  @description('Optional. Deploy the environment. Defaults to `true`.')
  enabled: bool?

  @description('Required. Name of the spoke that hosts the environment. Must match the `name` of an entry in the `spokes` parameter, and that spoke must define the subnet named in `subnetName`.')
  @minLength(1)
  @maxLength(40)
  spokeName: string

  @description('Optional. Name of the delegated subnet in that spoke that the environment uses as its infrastructure subnet. Defaults to `snet-runners`. It must be delegated to `Microsoft.App/environments` and sized /27 or larger, and its prefix cannot be changed once an environment exists in it.')
  @minLength(1)
  @maxLength(80)
  subnetName: string?

  @description('Optional. Name of the environment. Defaults to `cae-<spoke name>`.')
  @minLength(1)
  @maxLength(60)
  name: string?

  @description('Optional. Give the environment an internal load balancer only, with no public static IP. Defaults to `true`. Runner jobs take no inbound traffic at all, so there is nothing to expose.')
  internal: bool?

  @description('Optional. Spread the environment across availability zones. Defaults to `false`, and **cannot be changed after the environment is created**. Runner replicas are ephemeral and hold no state, so a zonal outage costs a retried workflow rather than data; set `true` before first deployment if you disagree.')
  zoneRedundant: bool?
}

@export()
@description('Optional. The GitHub App that the runner jobs authenticate as. One App covers every repository it is installed on, so there is a single credential to rotate rather than one personal access token per repository.')
type githubAppType = {
  @description('Required. The GitHub App ID, shown on the App settings page. This is not a secret.')
  @minLength(1)
  applicationId: string

  @description('Required. Installation ID of the App on the account that owns the repositories. A GitHub App has **one installation per account**, covering every repository selected in that installation, so this is normally the only one you need. Read it from the browser address bar at `https://github.com/settings/installations/<id>`, or with `gh api /user/installations --jq \'.installations[].id\'`. It is not a secret.')
  @minLength(1)
  installationId: string

  @description('Optional. Name of the Key Vault secret holding the App private key, in PEM form. Defaults to `github-app-private-key`. The value is never set by this deployment: the vault is reachable only over its private endpoint, so it is pasted in once from a jump box. See infra/README.md.')
  @minLength(1)
  @maxLength(127)
  privateKeySecretName: string?

  @description('Optional. GitHub API base URL. Defaults to `https://api.github.com`. Change it only for GitHub Enterprise Server.')
  @minLength(1)
  apiUrl: string?
}

@export()
@description('Required. A self-hosted GitHub Actions runner, deployed as one event-driven Container Apps job. There is one job per repository: a runner registration targets exactly one repository, and the scaler does not tell a replica which repository queued the work. Onboarding another repository is one more entry here.')
type githubRunnerType = {
  @description('Required. Owner of the repository. On a personal account this is the account name.')
  @minLength(1)
  @maxLength(39)
  repositoryOwner: string

  @description('Required. Name of the repository. It must be **private**: a self-hosted runner attached to a public repository will execute code from any fork.')
  @minLength(1)
  @maxLength(100)
  repositoryName: string

  @description('Optional. Installation ID of the GitHub App for this repository, when it differs from the account-level one on `githubApp`. A GitHub App has one installation per account, so this is only needed for a repository owned by a different account that the App is separately installed on.')
  @minLength(1)
  installationId: string?

  @description('Optional. Deploy the job. Defaults to `true`. Set `false` to stop serving a repository without deleting its definition.')
  enabled: bool?

  @description('Optional. Name of the Container Apps job. Defaults to `cj-<repository name>`. Azure limits it to 32 characters, which is shorter than a repository name may be.')
  @minLength(2)
  @maxLength(32)
  name: string?

  @description('Optional. Extra runner labels, on top of the defaults GitHub always applies (`self-hosted`, `linux`, `x64`). A workflow selects this runner with a matching `runs-on`.')
  labels: string[]?

  @description('Optional. Container image, including the tag. Defaults to `<registry login server>/github-runner:latest`. Pin a tag rather than tracking `latest` when a repository needs a stable toolchain.')
  @minLength(1)
  image: string?

  @description('Optional. vCPU per replica. Defaults to `1.0`. On the Consumption workload profile, CPU and memory must be a supported pair: memory in GiB must be exactly twice the CPU count.')
  cpu: string?

  @description('Optional. Memory per replica. Defaults to `2Gi`. Must be exactly twice the CPU count in GiB on the Consumption workload profile.')
  memory: string?

  @description('Optional. Maximum concurrent job executions, and therefore the maximum number of workflow jobs this repository can run at once. Defaults to `5`.')
  @minValue(1)
  @maxValue(100)
  maxExecutions: int?

  @description('Optional. How often the scaler polls the GitHub API, in seconds. Defaults to `30`. Lowering it spends rate limit for a shorter queue wait.')
  @minValue(10)
  @maxValue(3600)
  pollingInterval: int?

  @description('Optional. How long a single replica may run before Azure stops it, in seconds. Defaults to `1800`. This is the ceiling on one workflow job, so raise it for a long build.')
  @minValue(60)
  @maxValue(86400)
  replicaTimeout: int?

  @description('Optional. Tags applied to the job. Defaults to the deployment tags.')
  tags: object?
}

