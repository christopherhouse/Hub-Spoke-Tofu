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

// Spokes. Each entry gets its own resource group, virtual network and subnets, peers
// bidirectionally with the hub named in `hubName`, and is linked to every Private DNS zone.
// Every subnet gets a dedicated NSG with no custom rules; add `securityRules` to a subnet to
// extend it, using priority 200 or above so it cannot collide with the generated Bastion rule
// at 100.
//
// Address plan: 10.0.0.0/16 is hubs, one /19 each. 10.1.0.0/16 onward is spokes, one /20
// each. Spoke 1 is 10.1.0.0/20 (10.1.0.0 - 10.1.15.255):
//   10.1.0.0/24    snet-workload
//   10.1.1.0/24    snet-privateendpoints
//   10.1.2.0 - 10.1.15.255   free
param spokes = [
  {
    name: 'spoke-app-cus'
    hubName: 'hub-cus'
    location: 'centralus'
    // ME-MngEnvMCAP758145-chhouse-2. The deployment identity holds Contributor here because
    // the subscription is listed in targetSubscriptionIds in infra/bootstrap/main.bicepparam.
    subscriptionId: '8043efb5-d046-4aac-abcd-2c1a00e5ab86'
    resourceGroupName: 'RG-WORKLOAD-APP-CUS'
    addressPrefixes: [
      '10.1.0.0/20'
    ]
    subnets: [
      {
        name: 'snet-workload'
        addressPrefix: '10.1.0.0/24'
      }
      {
        // Hosts no virtual machines, so the Bastion RDP and SSH rule would be dead weight.
        name: 'snet-privateendpoints'
        addressPrefix: '10.1.1.0/24'
        allowBastionAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
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
