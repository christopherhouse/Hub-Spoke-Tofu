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
    // Management jump boxes. No public IP; Bastion is the only way in, and the jump box
    // subnet NSG admits RDP and SSH from AzureBastionSubnet alone. Sign in with Entra ID.
    //
    // Standard_D4as_v7, not a burstable B-series: the x64 B-series is not offered in
    // centralus at all. Check with `az vm list-skus -l <region>` before changing the size.
    jumpboxes: [
      {
        name: 'vm-jb-cus-01'
      }
    ]
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
  // Shared platform services for the region: the Log Analytics workspace every resource sends
  // diagnostics to, the Key Vault holding CI/CD credentials, and the registry holding the
  // self-hosted runner image. They live in a spoke rather than the hub so the hub stays
  // connectivity-only.
  //
  // Spoke 2 is 10.1.16.0/20 (10.1.16.0 - 10.1.31.255):
  //   10.1.16.0/24   snet-privateendpoints
  //   10.1.17.0 - 10.1.31.255   free
  {
    name: 'spoke-platform-cus'
    hubName: 'hub-cus'
    location: 'centralus'
    resourceGroupName: 'RG-PLATFORM-SHARED-CUS'
    addressPrefixes: [
      '10.1.16.0/20'
    ]
    subnets: [
      {
        name: 'snet-privateendpoints'
        addressPrefix: '10.1.16.0/24'
        allowBastionAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
]

// Shared platform services. `spokeName` supplies the subscription, resource group and region,
// so none of them is restated. The Key Vault and registry names are globally unique across
// Azure, which is why they are data rather than derived.
param platform = {
  name: 'platform-cus'
  spokeName: 'spoke-platform-cus'
  privateEndpointSubnetName: 'snet-privateendpoints'
  logAnalytics: {
    // 30 days is included at no extra charge. The daily cap is a guard rail against a runaway
    // diagnostic source, not a capacity plan; raise it if ingestion is legitimately throttled.
    dataRetention: 30
    dailyQuotaGb: '1'
  }
  keyVault: {
    name: 'kv-platform-cus-hsiac'
  }
  containerRegistry: {
    name: 'acrplatformcushsiac'
    // `az acr build` runs on Microsoft-managed ACR Tasks compute outside the virtual network,
    // so a registry with public access fully disabled would reject the image build that has to
    // happen before any runner exists. These are the IPv4 prefixes of the
    // AzureContainerRegistry.CentralUS service tag; everything else is denied and runners pull
    // over the private endpoint. Refresh them with the command in infra/README.md.
    allowedPublicIpRanges: [
      '13.89.170.216/29'
      '13.89.175.0/25'
      '13.89.178.192/26'
      '20.40.224.64/26'
      '20.44.11.0/25'
      '20.44.11.128/26'
      '20.44.12.0/25'
      '52.182.138.208/29'
      '52.182.142.0/25'
      '52.182.142.128/25'
      '57.175.72.0/26'
      '72.152.15.0/26'
      '104.208.16.80/29'
      '172.212.129.0/24'
    ]
  }
}

// The Container Apps environment that hosts the runner jobs, in the hub runners subnet.
param containerAppsEnvironment = {
  hubName: 'hub-cus'
}

// The GitHub App the runners authenticate as. `applicationId` is the App ID shown on the App
// settings page and `installationId` identifies the App's single installation on the account;
// neither is a secret. The private key is never set here: it is pasted into the Key Vault
// secret named `github-app-private-key`, once, from the jump box. See infra/README.md.
//
// Leave this commented out until the App exists, otherwise the runner jobs deploy with an
// application ID that cannot mint a token.
// param githubApp = {
//   applicationId: '123456'
//   installationId: '98765432'
// }

// One entry per repository. Onboarding repository N+1 is one entry here plus selecting it in
// the App installation; nothing else changes, and `installationId` is not repeated because a
// GitHub App has one installation per account.
//
// Only ever list **private** repositories. A self-hosted runner attached to a public
// repository will execute code from any fork.
//
// The markers below are load-bearing: .github/workflows/onboard-runner.yml inserts new
// entries between them and opens a pull request. Hand-editing inside them is fine; do not
// remove them.
param githubRunners = [
  // BEGIN runners
  // END runners
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
