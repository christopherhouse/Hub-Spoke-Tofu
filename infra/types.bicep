// Shared user-defined types for the hub-and-spoke topology.
//
// Topology is data: every hub is an entry in the `hubs` parameter of infra/main.bicep, so
// adding a hub - in another region, resource group, or subscription - is a parameter change
// rather than a template change.

@export()
@description('Returns the virtual network name a hub of the given name deploys. Single source of the convention, so callers can build a hub virtual network resource ID without reading the hub module outputs.')
func hubVirtualNetworkName(hubName string) string => 'vnet-${hubName}'

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

  @description('Optional. Subnet for the Azure Container Apps environment that hosts self-hosted GitHub Actions runners. Delegated to `Microsoft.App/environments`. A workload profile environment requires /27 or larger, and the prefix cannot be changed once an environment exists in it.')
  runnersSubnet: hubSubnetType?

  @description('Optional. Tags applied to the hub resource group and every hub resource.')
  tags: object?
}
