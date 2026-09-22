using './main.bicep'

// The runner NSG rule set lives in its own file rather than inline here because it is a
// reviewed security artifact, the same way the Private DNS zone catalog is.
import { runnerSecurityRules } from './runner-nsg-rules.bicep'

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
//   10.0.0.96/27   free
//   10.0.0.128/26  ORPHANED - DO NOT REUSE. The former snet-runners. Dropped from this
//                  template when the runners moved to spoke-runners-wu3, but still present in
//                  Azure and still occupied by the failed cae-hub-cus environment. See the
//                  Known orphans section of infra/README.md.
//   10.0.0.192/26  AzureFirewallSubnet  fixed name, Azure minimum is /26
//   10.0.1.0/26    AzureFirewallManagementSubnet  fixed name, required by the Basic SKU
//   10.0.1.64 - 10.0.31.255             reserved for gateway and DNS resolver
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
      // The jump box egresses through the firewall rather than a NAT gateway, so the whole
      // estate leaves through one address and one set of logs. `HubFirewall` is resolved to
      // the firewall's private IP by the hub module; no IP address is written down here.
      routes: [
        {
          name: 'default-to-firewall'
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'HubFirewall'
        }
      ]
    }
    // The transit appliance. Peering is not transitive, so without a next-hop appliance in the
    // hub the West US 3 runners could not reach the Central US private endpoints at all.
    //
    // Basic, not Standard: roughly $288/month against $1,015, and Basic supports application
    // rules, which is what the private endpoint return path depends on. Its 250 Mbps ceiling
    // is ample for CI image pulls.
    firewall: {
      skuTier: 'Basic'
      subnetAddressPrefix: '10.0.0.192/26'
      // Basic requires a management NIC and this subnet unconditionally, regardless of
      // forced tunnelling.
      managementSubnetAddressPrefix: '10.0.1.0/26'
      // Pinned to a single zone. Zone redundancy costs nothing on the firewall itself but
      // does incur inter-zone data transfer, which is not worth paying for in a lab.
      availabilityZones: [
        1
      ]
      // Application rules, not network rules, wherever a destination can be named. Azure
      // Firewall always SNATs traffic matched by an application rule, which is exactly what
      // makes a private endpoint in another spoke reachable.
      //
      // This list is the most likely cause of a failed deployment or a runner that never
      // registers. Firewall logs go to log-platform-cus; check them first.
      applicationRules: [
        {
          // Container Apps platform requirements, for any environment.
          // https://learn.microsoft.com/azure/container-apps/use-azure-firewall
          name: 'allow-container-apps-platform'
          sourceAddresses: [
            '10.2.0.0/20'
          ]
          targetFqdns: [
            'mcr.microsoft.com'
            '*.data.mcr.microsoft.com'
            '*.blob.core.windows.net'
            'login.microsoft.com'
            'login.microsoftonline.com'
          ]
        }
        {
          // The registry holding the runner image and the vault holding the GitHub App key,
          // both reached over their private endpoints in spoke-platform-cus. Wildcards rather
          // than exact names because both resource names carry a uniqueness suffix that is
          // computed at deployment time.
          name: 'allow-platform-services'
          sourceAddresses: [
            '10.2.0.0/20'
          ]
          targetFqdns: [
            '*.azurecr.io'
            '*.vaultcore.azure.net'
            '*.vault.azure.net'
          ]
        }
        {
          // The runners themselves, registering with and polling GitHub.
          name: 'allow-github'
          sourceAddresses: [
            '10.2.0.0/20'
          ]
          targetFqdns: [
            'github.com'
            'api.github.com'
            '*.githubusercontent.com'
            '*.actions.githubusercontent.com'
            'ghcr.io'
            '*.pkg.github.com'
          ]
        }
        {
          // The jump box, which lost its NAT gateway and now egresses here. Without this it
          // stays reachable over Bastion but has no internet access.
          name: 'allow-jumpbox-egress'
          sourceAddresses: [
            '10.0.0.64/27'
          ]
          targetFqdns: [
            '*.windowsupdate.com'
            '*.update.microsoft.com'
            '*.delivery.mp.microsoft.com'
            'login.microsoftonline.com'
            'management.azure.com'
            'aka.ms'
            '*.blob.core.windows.net'
            '*.githubusercontent.com'
          ]
        }
      ]
      // Service tags the Container Apps platform needs that are not addressable by FQDN.
      networkRules: [
        {
          name: 'allow-container-apps-service-tags'
          sourceAddresses: [
            '10.2.0.0/20'
          ]
          destinationAddresses: [
            'MicrosoftContainerRegistry'
            'AzureFrontDoorFirstParty'
            'AzureContainerRegistry'
            'AzureActiveDirectory'
            'AzureKeyVault'
          ]
          destinationPorts: [
            '443'
          ]
        }
      ]
    }
    // Management jump boxes. No public IP; Bastion is the only way in, and the jump box
    // subnet NSG admits RDP and SSH from AzureBastionSubnet alone. Sign in with Entra ID.
    //
    // Standard_D4as_v7, not a burstable B-series: the x64 B-series is not offered in
    // centralus at all. Check with `az vm list-skus -l <region>` before changing the size.
    jumpboxes: [
      {
        name: 'vm-jb-cus-01'
        // Preserve the existing OS disk SKU. Azure does not allow changing an attached managed
        // disk's storage account type through a virtual machine update.
        osDiskStorageAccountType: 'Standard_LRS'
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
  // The self-hosted runners. West US 3, not Central US: Container Apps has repeatedly failed
  // to get capacity in centralus, which is what forced this spoke to exist. It peers back to
  // hub-cus and reaches the Central US platform services through the hub firewall, so the
  // registry, the vault and the GitHub App secret all stay where they are.
  //
  // Spoke 3 is 10.2.0.0/20 (10.2.0.0 - 10.2.15.255):
  //   10.2.0.0/26    snet-runners
  //   10.2.0.64 - 10.2.15.255   free
  {
    name: 'spoke-runners-wu3'
    hubName: 'hub-cus'
    location: 'westus3'
    resourceGroupName: 'RG-RUNNERS-WU3'
    addressPrefixes: [
      '10.2.0.0/20'
    ]
    subnets: [
      {
        name: 'snet-runners'
        // A Container Apps environment cannot have its subnet resized afterwards, and /27 is
        // the documented minimum, so this is sized well past the handful of concurrent
        // runners actually needed.
        addressPrefix: '10.2.0.0/26'
        // Mandatory for a workload profile environment.
        delegation: 'Microsoft.App/environments'
        // Hosts no virtual machines.
        allowBastionAccess: false
        // Priorities start at 200; spoke.bicep generates the Bastion rule at 100.
        securityRules: runnerSecurityRules('10.2.0.0/26')
        // Everything leaves through the hub firewall, including traffic to the Central US
        // private endpoints. Only a workload profile environment supports a route table, which
        // is why container-apps-environment.bicep must keep its Consumption workload profile.
        routes: [
          {
            name: 'default-to-firewall'
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'HubFirewall'
          }
        ]
      }
    ]
  }
]

// Shared platform services. `spokeName` supplies the subscription, resource group and region,
// so none of them is restated. The Key Vault and registry names are left unset: both share one
// namespace across every Azure tenant, so they are derived with a suffix computed from the
// subscription and this stamp name rather than guessed at here.
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
  keyVault: {}
  containerRegistry: {
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

// The Container Apps environment that hosts the runner jobs. `spokeName` supplies the
// subscription, resource group and region, so none of them is restated.
param containerAppsEnvironment = {
  spokeName: 'spoke-runners-wu3'
  subnetName: 'snet-runners'
}

// The GitHub App the runners authenticate as. `applicationId` is the App ID shown on the App
// settings page and `installationId` identifies the App's single installation on the account;
// neither is a secret. The private key is never set here: it lives in the Key Vault secret
// named `github-app-private-key`, seeded once from the jump box. See infra/README.md.
//
// `installationId` does not change when repositories are added to or removed from the
// installation, so onboarding repository N+1 never touches this block.
param githubApp = {
  applicationId: '5026676'
  installationId: '163623366'
}

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
  {
    repositoryOwner: 'christopherhouse'
    repositoryName: 'Secure-Integration-Environment'
    // The derived default would be truncated at 32 characters mid-word.
    name: 'cj-secure-integration-env'
  }
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
