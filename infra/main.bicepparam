using './main.bicep'

// The runner NSG rule set lives in its own file rather than inline here because it is a
// reviewed security artifact, the same way the Private DNS zone catalog is. The API
// Management rule set is there for the same reason, and for an additional one: without it a
// classic injected instance silently degrades.
import { runnerSecurityRules } from './runner-nsg-rules.bicep'
import { apimSecurityRules } from './apim-nsg-rules.bicep'

param dnsResourceGroupName = 'RG-CONNECTIVITY-DNS-CUS'

// Also substituted into regional zone names, e.g. privatelink.centralus.azurecontainerapps.io
param location = 'centralus'

// Every hub, spoke and platform component that does not name a subscription of its own lands
// here. This is declared rather than inferred from the CLI context because `az deployment sub
// create` silently targets whatever subscription happens to be active, and a stale context
// will happily build a second copy of the whole estate in the wrong subscription without
// erroring. Deploy with `--subscription` set to the same value.
param defaultSubscriptionId = '04769e32-22a3-4978-b533-1d6ee0c9620a'

// Hubs. Each entry gets its own resource group, virtual network, subnets and Bastion, and is
// linked to every Private DNS zone automatically. Add `subscriptionId` to place a hub in
// another subscription of the same tenant.
//
// Hub 1 address plan, inside 10.0.0.0/19 (10.0.0.0 - 10.0.31.255):
//   10.0.0.0/26    AzureBastionSubnet   Azure minimum is /26
//   10.0.0.64/27   snet-jumpbox
//   10.0.0.96/27   free
//   10.0.0.128/26  free                 the former snet-runners, deleted with its environment
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
      // Deliberately permissive: HTTP and HTTPS to anywhere, for the whole estate.
      //
      // The alternative is a curated FQDN list covering the documented Container Apps
      // requirements, GitHub, the platform registry and vault, and Windows Update for the
      // jump box. That is tighter but brittle - a missing entry shows up as a runner that
      // never registers or a jump box with no internet, and every tool added to either means
      // another rule. Not worth the debugging tax on a lab.
      //
      // This is still an allow-list rather than an open firewall: outbound only, ports 80 and
      // 443 only, and every request logged to log-platform-cus. Inbound is untouched.
      //
      // Worth tightening if these runners ever build untrusted code. A runner with
      // unrestricted egress is an exfiltration path for anything it can read, including the
      // GitHub App private key in Key Vault. See "Only private repositories" in
      // infra/README.md.
      //
      // Application rules, not network rules, on purpose: Azure Firewall always SNATs traffic
      // matched by an application rule, which is what makes a private endpoint in another
      // spoke reachable.
      applicationRules: [
        {
          name: 'allow-web-outbound'
          sourceAddresses: [
            '10.0.0.0/19'
            '10.1.34.32/28'
            '10.2.0.0/20'
          ]
          targetFqdns: [
            '*'
          ]
          protocols: [
            {
              protocolType: 'Http'
              port: 80
            }
            {
              protocolType: 'Https'
              port: 443
            }
          ]
        }
      ]
      // Retained even though the rule above is permissive. An application rule only matches
      // traffic the firewall can attribute to an FQDN, from SNI or the Host header, so
      // Container Apps platform traffic that is not plain HTTP would not match it.
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
        // The force-tunnelled API Management subnet. The application rule above already
        // covers its plain HTTP and HTTPS egress, but two things it depends on would not
        // match an application rule: Azure Monitor's ingestion port 1886, which is not HTTP
        // the firewall can attribute to an FQDN, and Entra ID token and Microsoft Graph
        // traffic, which an instance uses for identity-backed features. Both are stated as
        // network rules so they match on service tag rather than on an FQDN the firewall has
        // to infer.
        //
        // The remaining dependencies - SQL, Storage, Event Hubs and Key Vault - are absent on
        // purpose: `snet-apim` reaches those over service endpoints, which bypass the default
        // route and never arrive here.
        {
          name: 'allow-apim-dependencies'
          sourceAddresses: [
            '10.1.34.32/28'
          ]
          destinationAddresses: [
            'AzureMonitor'
            'AzureActiveDirectory'
          ]
          destinationPorts: [
            '443'
            '1886'
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
  // The privately networked Azure AI Foundry lab: a Foundry resource with network injection
  // for the Agent Service, its dependency private endpoints, and API Management in front of
  // the model endpoints.
  //
  // Spoke 4 takes the next /20 slot, 10.1.32.0/20, but only declares a /22 of it. The slot is
  // reserved so the next spoke starts at 10.1.48.0/20 and the lab can grow into 10.1.36.0 -
  // 10.1.47.255 without renumbering.
  //
  // Spoke 4 is 10.1.32.0/22 (10.1.32.0 - 10.1.35.255):
  //   10.1.32.0/23    snet-foundry-agents
  //   10.1.34.0/27    snet-privateendpoints
  //   10.1.34.32/28   snet-apim
  //   10.1.34.48/28   free
  //   10.1.34.64/26   free, earmarked for an Application Gateway if public ingress is added
  //   10.1.34.128 - 10.1.35.255   free
  {
    name: 'spoke-foundry-cus'
    hubName: 'hub-cus'
    location: 'centralus'
    resourceGroupName: 'RG-WORKLOAD-FOUNDRY-CUS'
    addressPrefixes: [
      '10.1.32.0/22'
    ]
    subnets: [
      {
        // Foundry Agent Service network injection. The agents run on managed compute that
        // Azure places in this subnet, so it is dedicated to the Foundry account and hosts
        // nothing else.
        name: 'snet-foundry-agents'
        addressPrefix: '10.1.32.0/23'
        // Required by Foundry network injection, which runs the agents on the Container Apps
        // platform. Documented minimum is /27; a /23 leaves room for the agent fleet to
        // scale, and like a Container Apps environment subnet it cannot be resized once the
        // injected account exists.
        delegation: 'Microsoft.App/environments'
        // Hosts no virtual machines.
        allowBastionAccess: false
      }
      {
        // Private endpoints for the Foundry account and its bring-your-own dependencies:
        // Azure AI Search, Storage and Cosmos DB. Those three are not auto-created by a
        // Foundry deployment, so they land here explicitly.
        name: 'snet-privateendpoints'
        addressPrefix: '10.1.34.0/27'
        allowBastionAccess: false
        privateEndpointNetworkPolicies: 'Disabled'
      }
      {
        // API Management, classic Premium tier, injected in internal mode. Dedicated by
        // convention rather than by Azure rule: the classic tier permits other resources in
        // its subnet, but sharing one with a service that scales independently is a good way
        // to run out of addresses mid scale-out.
        //
        // /28: the classic minimum is /29, which leaves no room to scale at all. A /28 gives
        // 16 addresses - 5 reserved by Azure, 2 for the instance, 1 for the internal load
        // balancer - which is 4 scale-out units, 5 total. Consider /26 or /25 if this ever
        // approaches the 31-unit Premium ceiling.
        name: 'snet-apim'
        addressPrefix: '10.1.34.32/28'
        // Deliberately no `delegation`. Classic injection requires the subnet be delegated to
        // nothing at all; delegation to Microsoft.Web/serverFarms is a v2-tier requirement and
        // would make the classic deployment fail.
        //
        // Not optional, unlike every other NSG in this file. The load balancer API Management
        // uses internally rejects all inbound traffic by default, so without the port 3443
        // rule in this set the instance deploys green and then degrades hours later.
        securityRules: apimSecurityRules()
        // Dependency traffic takes the Azure backbone from this subnet rather than the
        // general egress path. Microsoft strongly recommends these for a classic injected
        // instance, and they are what keeps the dependencies working if this subnet is ever
        // force-tunnelled through the hub firewall - service endpoint traffic bypasses a
        // 0.0.0.0/0 route, so SQL and Storage keep working while everything else is inspected.
        serviceEndpoints: [
          'Microsoft.Sql'
          'Microsoft.Storage'
          'Microsoft.EventHub'
          'Microsoft.KeyVault'
        ]
        // Hosts no virtual machines.
        allowBastionAccess: false
        // Forced tunnelling. Everything leaves through the hub firewall so the lab has one
        // auditable egress address, with one deliberate exception.
        //
        // The ApiManagement service tag route is not optional, and omitting it is the single
        // most common way a force-tunnelled API Management instance breaks. Control plane
        // traffic arrives from the internet on port 3443 from the set of addresses that tag
        // covers. If the default route sends the response back through the firewall, it is
        // SNATed to the firewall's address and no longer maps symmetrically to the inbound
        // flow, so the control plane never sees the reply and the management endpoint is
        // lost - the same degradation the port 3443 NSG rule exists to prevent, reached from
        // the other direction. Sending that tag straight to the internet restores the
        // symmetric return path.
        //
        // Routing it around the firewall is not a meaningful hole: it is return traffic only,
        // on one port, to a published Microsoft-managed set of addresses that the NSG already
        // restricts inbound to.
        //
        // The dependencies reached over the service endpoints above - SQL, Storage, Event
        // Hubs and Key Vault - need no route of their own. Service endpoint traffic takes the
        // Azure backbone and ignores the 0.0.0.0/0 route entirely, which is most of why those
        // endpoints are enabled.
        routes: [
          {
            name: 'apim-control-plane-to-internet'
            addressPrefix: 'ApiManagement'
            nextHopType: 'Internet'
          }
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
