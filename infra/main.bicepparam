using './main.bicep'

param dnsResourceGroupName = 'RG-CONNECTIVITY-DNS-CUS'

// Also substituted into regional zone names, e.g. privatelink.centralus.azurecontainerapps.io
param location = 'centralus'

// Hub and spoke virtual networks to link to every zone. Empty until those networks exist.
// Each entry is an object: { virtualNetworkResourceId: '<vnet resource id>' }
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
