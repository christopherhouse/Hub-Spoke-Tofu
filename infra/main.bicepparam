using './main.bicep'

param dnsResourceGroupName = 'RG-CONNECTIVITY-DNS-CUS'

// Also substituted into regional zone names, e.g. privatelink.centralus.azurecontainerapps.io
param location = 'centralus'

// Hubs. Each entry gets its own resource group, virtual network, subnets and Bastion, and is
// linked to every Private DNS zone automatically. Add `subscriptionId` to place a hub in
// another subscription of the same tenant.
//
// Hub 1 address plan, inside 10.0.0.0/19 (10.0.0.0 - 10.0.31.255):
//   10.0.0.0/26    AzureBastionSubnet   Azure minimum is /26
//   10.0.0.64/27   snet-jumpbox
//   10.0.0.96/27   free                 keeps snet-runners on a /26 boundary
//   10.0.0.128/26  snet-runners         Container Apps, 50 usable IPs
//   10.0.0.192 - 10.0.31.255            reserved for firewall, gateway, DNS resolver
param hubs = [
  {
    name: 'hub-cus'
    location: 'centralus'
    resourceGroupName: 'RG-CONNECTIVITY-HUB-CUS'
    addressPrefixes: [
      '10.0.0.0/19'
    ]
    bastion: {
      // Standard, not Developer: Developer cannot peer, so it could not reach spoke VMs.
      skuName: 'Standard'
      subnetAddressPrefix: '10.0.0.0/26'
    }
    jumpboxSubnet: {
      addressPrefix: '10.0.0.64/27'
    }
    // Outbound SNAT for the jump box subnet through a static, allow-listable public IP,
    // instead of Azure default outbound access.
    natGateway: {}
    // A Container Apps environment cannot have its subnet resized afterwards, so this is
    // sized well past the handful of concurrent runners actually needed.
    runnersSubnet: {
      addressPrefix: '10.0.0.128/26'
    }
  }
]

// Extra virtual networks to link to every zone, beyond the hubs above, which are linked
// automatically. Each entry is an object: { virtualNetworkResourceId: '<vnet resource id>' }
param virtualNetworkLinks = []

// Container Apps zones for regions other than `location` must be listed here explicitly,
// because the module resolves {regionName} from `location` only.
param additionalPrivateLinkPrivateDnsZonesToInclude = [
  'privatelink.westus3.azurecontainerapps.io'
]

param tags = {
  workload: 'connectivity'
  'managed-by': 'bicep'
  environment: 'shared'
}
