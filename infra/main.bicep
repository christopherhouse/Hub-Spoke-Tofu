targetScope = 'subscription'

import { curatedPrivateLinkPrivateDnsZones } from './zones.bicep'
import {
  containerAppsEnvironmentName
  containerAppsEnvironmentType
  githubAppType
  githubRunnerType
  hubType
  hubVirtualNetworkName
  platformType
  spokeType
  spokeVirtualNetworkName
} from './types.bicep'

@description('Required. Name of the resource group that holds the shared Private DNS zones.')
@minLength(1)
@maxLength(90)
param dnsResourceGroupName string

@description('Required. Azure region for the deployment. Private DNS zones are global, but this sets the resource group location and is substituted into regional zone names such as Container Apps.')
param location string

@description('Required. Subscription that hosts any hub, spoke or platform component which does not name a subscription of its own. Declared rather than inferred from the deployment context on purpose: `az deployment sub create` silently targets whatever subscription the CLI happens to have active, so inferring it lets a stale context deploy a duplicate estate into the wrong subscription without any error. Pass `--subscription` as well, so the deployment and its contents agree.')
@minLength(36)
@maxLength(36)
param defaultSubscriptionId string

@description('Optional. Hubs to deploy. Each entry creates its own resource group, virtual network, subnets and Azure Bastion, and its virtual network is linked to every Private DNS zone. Hubs may target other subscriptions in the same tenant.')
param hubs hubType[] = []

@description('Optional. Spokes to deploy. Each entry creates its own resource group, virtual network and subnets, peers bidirectionally with the hub named in `hubName`, and is linked to every Private DNS zone. Spokes may target other subscriptions in the same tenant, provided the deployment identity holds Contributor there.')
param spokes spokeType[] = []

@description('Optional. Shared platform services for the region: the Log Analytics workspace every resource sends diagnostics to, the Key Vault holding CI/CD credentials, the container registry holding the runner image, and the runner managed identity. They land in the spoke named by `spokeName`. Omit to deploy the network without them.')
param platform platformType?

@description('Optional. Azure Container Apps environment that hosts the self-hosted runner jobs. It lands in the runners subnet of the hub named by `hubName`. Omit to deploy the network without a runner platform.')
param containerAppsEnvironment containerAppsEnvironmentType?

@description('Optional. The GitHub App the runner jobs authenticate as. Required when `githubRunners` is non-empty. Its private key is read from the platform Key Vault and is never set by this deployment.')
param githubApp githubAppType?

@description('Optional. Self-hosted GitHub Actions runners, one event-driven Container Apps job per repository. Onboarding another repository is one more entry here plus installing the GitHub App on it.')
param githubRunners githubRunnerType[] = []

@description('Optional. Additional virtual networks to link to every Private DNS zone, on top of the hub virtual networks, which are linked automatically. Each object needs a virtualNetworkResourceId.')
param virtualNetworkLinks array = []

@description('Optional. Additional Private Link DNS zones to create on top of the curated catalog. Use this for regional zones in regions other than the deployment location, or for services the catalog does not cover.')
param additionalPrivateLinkPrivateDnsZonesToInclude string[] = []

@description('Optional. Tags applied to the resource group and every Private DNS zone.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

// Scoped explicitly to the declared subscription rather than defaulting to the deployment's
// own subscription, which is whatever the CLI had active.
module dnsResourceGroup 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'deploy-dns-rg'
  scope: subscription(defaultSubscriptionId)
  params: {
    name: dnsResourceGroupName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// One resource group per hub. `subscriptionId` makes onboarding another subscription a
// parameter change: Bicep targets a scope per module, so no provider plumbing is needed.
module hubResourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for hub in hubs: {
    name: 'deploy-rg-${hub.name}'
    scope: subscription(hub.?subscriptionId ?? defaultSubscriptionId)
    params: {
      name: hub.resourceGroupName
      location: hub.location
      tags: hub.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

module hubNetworks 'modules/hub.bicep' = [
  for (hub, index) in hubs: {
    name: 'deploy-hub-${hub.name}'
    scope: resourceGroup(hub.?subscriptionId ?? defaultSubscriptionId, hub.resourceGroupName)
    dependsOn: [
      hubResourceGroups[index]
    ]
    params: {
      name: hub.name
      location: hub.location
      addressPrefixes: hub.addressPrefixes
      bastion: hub.?bastion
      jumpboxSubnet: hub.?jumpboxSubnet
      firewall: hub.?firewall
      jumpboxes: hub.?jumpboxes ?? []
      logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
      tags: hub.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

// ---------------------------------------------------------------------------------------
// Shared platform services
//
// These land in an ordinary spoke rather than in the hub, so the hub stays connectivity-only.
// The spoke supplies the subscription, resource group and location, which is why the platform
// parameter restates none of them.
//
// The workspace is deployed separately from the rest of the platform, and earlier, because the
// two have opposite ordering constraints. Every hub and spoke wants to send diagnostics to the
// workspace, so the workspace must exist before they do. Key Vault and the registry need a
// subnet to put a private endpoint in and a Private DNS zone to register in, so they must come
// after them. One module could not satisfy both.
// ---------------------------------------------------------------------------------------

// Null when no platform is requested, or when its `spokeName` matches no spoke. The latter
// surfaces as a null-reference error rather than a helpful message, the same way `hubName`
// does on a spoke; the invariant is documented in infra/README.md.
var platformSpoke = platform == null ? null : first(filter(spokes, spoke => spoke.name == platform!.spokeName))

var platformSubscriptionId = platform == null
  ? defaultSubscriptionId
  : (platformSpoke!.?subscriptionId ?? defaultSubscriptionId)

var platformResourceGroupName = platform == null ? '' : platformSpoke!.resourceGroupName

var platformLocation = platform == null ? location : platformSpoke!.location

var logAnalyticsEnabled = platform != null && (platform!.?logAnalytics.?enabled ?? true)

module logAnalyticsWorkspace 'modules/log-analytics.bicep' = if (logAnalyticsEnabled) {
  name: 'deploy-log-analytics'
  scope: resourceGroup(platformSubscriptionId, platformResourceGroupName)
  dependsOn: [
    spokeResourceGroups
  ]
  params: {
    name: platform!.?logAnalytics.?name ?? 'log-${platform!.name}'
    location: platformLocation
    logAnalytics: platform!.?logAnalytics
    tags: platform!.?tags ?? tags
    enableTelemetry: enableTelemetry
  }
}

// Empty when no workspace is deployed, which suppresses every diagnostic setting rather than
// emitting one that points at nothing.
var logAnalyticsWorkspaceResourceId = logAnalyticsEnabled ? logAnalyticsWorkspace!.outputs.resourceId : ''

// Each spoke references exactly one hub, by name. Resolved here rather than passed as a
// resource ID, so no hub virtual network ID is ever hand-copied into a .bicepparam file.
//
// A `hubName` that matches no hub yields null and fails with a null-reference error rather
// than a helpful message: Bicep's `assert` is still an experimental feature, so the invariant
// is documented in infra/README.md rather than enforced here.
var spokeHubs = [
  for spoke in spokes: first(filter(hubs, hub => hub.name == spoke.hubName))
]

// The position of each spoke's hub in the `hubs` array, so a spoke can read that hub module's
// outputs. `spokeHubs` holds the hub definition but a module output has to be indexed by
// position, and a filter does not give one back.
var hubNames = map(hubs, hub => hub.name)

var spokeHubIndexes = [
  for spoke in spokes: indexOf(hubNames, spoke.hubName)
]

// Empty when the hub has no Bastion, which suppresses the generated RDP and SSH rule in the
// spoke rather than emitting one with an empty source prefix.
var spokeHubBastionSubnetPrefixes = [
  for (spoke, index) in spokes: (spokeHubs[index]!.?bastion != null && (spokeHubs[index]!.bastion!.?enabled ?? true))
    ? spokeHubs[index]!.bastion!.subnetAddressPrefix
    : ''
]

module spokeResourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for spoke in spokes: {
    name: 'deploy-rg-${spoke.name}'
    scope: subscription(spoke.?subscriptionId ?? defaultSubscriptionId)
    params: {
      name: spoke.resourceGroupName
      location: spoke.location
      tags: spoke.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

// The hub virtual network must exist before the peering can reference it, and the peering is
// created in both directions from here, so the dependency is explicit.
module spokeNetworks 'modules/spoke.bicep' = [
  for (spoke, index) in spokes: {
    name: 'deploy-spoke-${spoke.name}'
    scope: resourceGroup(spoke.?subscriptionId ?? defaultSubscriptionId, spoke.resourceGroupName)
    dependsOn: [
      spokeResourceGroups[index]
      hubNetworks
    ]
    params: {
      name: spoke.name
      location: spoke.location
      addressPrefixes: spoke.addressPrefixes
      subnets: spoke.?subnets ?? []
      hubVirtualNetworkResourceId: resourceId(
        spokeHubs[index]!.?subscriptionId ?? defaultSubscriptionId,
        spokeHubs[index]!.resourceGroupName,
        'Microsoft.Network/virtualNetworks',
        hubVirtualNetworkName(spokeHubs[index]!.name)
      )
      hubBastionSubnetAddressPrefix: spokeHubBastionSubnetPrefixes[index]
      // Read back from the hub module rather than computed, because spokes deploy after hubs
      // and can therefore see the firewall's real private IP.
      hubFirewallPrivateIpAddress: hubNetworks[spokeHubIndexes[index]].outputs.firewallPrivateIp
      allowForwardedTraffic: spoke.?peering.?allowForwardedTraffic ?? true
      useRemoteGateways: spoke.?peering.?useRemoteGateways ?? false
      allowHubGatewayTransit: spoke.?peering.?allowHubGatewayTransit ?? false
      logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
      tags: spoke.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

// Derived rather than supplied as a parameter, so no hub virtual network resource ID is ever
// hand-copied into a .bicepparam file. The IDs are composed from the hub definitions instead
// of read from the hub module outputs, because a variable loop cannot reference module
// outputs (BCP182) and a for-expression cannot be nested inside concat (BCP138). The hub
// virtual network naming convention lives in types.bicep so it is stated once.
// Registration stays off everywhere: private endpoints own the records in these zones.
var hubVirtualNetworkLinks = [
  for hub in hubs: {
    virtualNetworkResourceId: resourceId(
      hub.?subscriptionId ?? defaultSubscriptionId,
      hub.resourceGroupName,
      'Microsoft.Network/virtualNetworks',
      hubVirtualNetworkName(hub.name)
    )
    registrationEnabled: false
  }
]

// Spokes are linked on the same terms as hubs, so a private endpoint in a spoke resolves
// without waiting for a DNS private resolver in the hub.
var spokeVirtualNetworkLinks = [
  for spoke in spokes: {
    virtualNetworkResourceId: resourceId(
      spoke.?subscriptionId ?? defaultSubscriptionId,
      spoke.resourceGroupName,
      'Microsoft.Network/virtualNetworks',
      spokeVirtualNetworkName(spoke.name)
    )
    registrationEnabled: false
  }
]

// Deployed into the resource group above. Cross-subscription placement for future hubs and
// spokes uses resourceGroup(<subscriptionId>, <name>) here; no provider plumbing is needed.
module privateDnsZones 'br/public:avm/ptn/network/private-link-private-dns-zones:0.7.3' = {
  name: 'deploy-private-dns-zones'
  scope: resourceGroup(defaultSubscriptionId, dnsResourceGroupName)
  // The hub virtual networks must exist before they can be linked; the resource IDs above
  // are composed, not referenced, so the dependency has to be explicit.
  dependsOn: [
    dnsResourceGroup
    hubNetworks
    spokeNetworks
  ]
  params: {
    location: location
    privateLinkPrivateDnsZones: curatedPrivateLinkPrivateDnsZones
    additionalPrivateLinkPrivateDnsZonesToInclude: additionalPrivateLinkPrivateDnsZonesToInclude
    virtualNetworkLinks: concat(hubVirtualNetworkLinks, spokeVirtualNetworkLinks, virtualNetworkLinks)
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------------------
// Key Vault, container registry and the runner identity
//
// Deployed after the zones because each private endpoint registers itself in one, and after
// the spokes because each needs a subnet. The zone resource IDs are composed rather than read
// from the pattern module's output, because that output is a shaped array rather than a map
// and indexing it would couple this file to the catalog's ordering.
// ---------------------------------------------------------------------------------------

var platformEnabled = platform != null

var platformPrivateEndpointSubnetResourceId = platformEnabled
  ? resourceId(
      platformSubscriptionId,
      platformResourceGroupName,
      'Microsoft.Network/virtualNetworks/subnets',
      spokeVirtualNetworkName(platformSpoke!.name),
      platform!.privateEndpointSubnetName
    )
  : ''

module platformServices 'modules/platform.bicep' = if (platformEnabled) {
  name: 'deploy-platform'
  scope: resourceGroup(platformSubscriptionId, platformResourceGroupName)
  dependsOn: [
    spokeNetworks
    privateDnsZones
  ]
  params: {
    name: platform!.name
    location: platformLocation
    privateEndpointSubnetResourceId: platformPrivateEndpointSubnetResourceId
    // The subscription is passed explicitly. The three-argument `resourceId(group, type, name)`
    // overload is ambiguous in ARM - it reads the first argument as a subscription ID and fails
    // with "is not valid subscription identifier" - and Bicep does not catch it at build time.
    keyVaultPrivateDnsZoneResourceId: resourceId(
      defaultSubscriptionId,
      dnsResourceGroupName,
      'Microsoft.Network/privateDnsZones',
      'privatelink.vaultcore.azure.net'
    )
    containerRegistryPrivateDnsZoneResourceId: resourceId(
      defaultSubscriptionId,
      dnsResourceGroupName,
      'Microsoft.Network/privateDnsZones',
      'privatelink.azurecr.io'
    )
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    keyVault: platform!.?keyVault
    containerRegistry: platform!.?containerRegistry
    tags: platform!.?tags ?? tags
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------------------
// Self-hosted runners
// ---------------------------------------------------------------------------------------

// The environment lands in a spoke, not in the hub: a hub is a connectivity landing zone and
// should not host workload compute. The spoke supplies the subscription, resource group and
// region, which is why `containerAppsEnvironmentType` restates none of them.
var runnerSpoke = containerAppsEnvironment == null
  ? null
  : first(filter(spokes, spoke => spoke.name == containerAppsEnvironment!.spokeName))

var containerAppsEnvironmentEnabled = containerAppsEnvironment != null && (containerAppsEnvironment!.?enabled ?? true)

var runnerSpokeSubscriptionId = containerAppsEnvironmentEnabled
  ? (runnerSpoke!.?subscriptionId ?? defaultSubscriptionId)
  : defaultSubscriptionId

var runnerSpokeResourceGroupName = containerAppsEnvironmentEnabled ? runnerSpoke!.resourceGroupName : ''

var resolvedContainerAppsEnvironmentName = containerAppsEnvironmentEnabled
  ? (containerAppsEnvironment!.?name ?? containerAppsEnvironmentName(runnerSpoke!.name))
  : ''

// The runners subnet resource ID is composed from the spoke definition rather than read from
// the spoke module outputs, because a module deployed at a different scope cannot take a
// conditional module's output as a scope argument.
module runnerEnvironment 'modules/container-apps-environment.bicep' = if (containerAppsEnvironmentEnabled) {
  name: 'deploy-aca-environment'
  scope: resourceGroup(runnerSpokeSubscriptionId, runnerSpokeResourceGroupName)
  dependsOn: [
    spokeNetworks
  ]
  params: {
    name: resolvedContainerAppsEnvironmentName
    location: runnerSpoke!.location
    infrastructureSubnetResourceId: resourceId(
      runnerSpokeSubscriptionId,
      runnerSpokeResourceGroupName,
      'Microsoft.Network/virtualNetworks/subnets',
      spokeVirtualNetworkName(runnerSpoke!.name),
      containerAppsEnvironment!.?subnetName ?? 'snet-runners'
    )
    internal: containerAppsEnvironment!.?internal ?? true
    zoneRedundant: containerAppsEnvironment!.?zoneRedundant ?? false
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
    tags: runnerSpoke!.?tags ?? tags
    enableTelemetry: enableTelemetry
  }
}

// One job per repository. A runner registration targets exactly one repository and the KEDA
// scaler does not tell a replica which repository queued the work, so a shared job cannot be
// made correct. Idle jobs scale to zero and cost nothing, so this scales to as many
// repositories as the account has.
//
// The private key is passed as a versionless Key Vault URI. The job resolves it with the runner
// identity at start-up, so rotating the secret needs no redeployment.
// Azure caps a Container Apps job name at 32 characters, which is shorter than a GitHub
// repository name may be, so the derived default is truncated rather than left to fail at
// preflight. Supply `name` explicitly when two repositories would truncate to the same value.
var runnerJobNames = [
  for runner in githubRunners: runner.?name ?? take('cj-${toLower(replace(runner.repositoryName, '.', '-'))}', 32)
]

module runnerJobs 'modules/github-runner-job.bicep' = [
  for (runner, index) in githubRunners: if (containerAppsEnvironmentEnabled && platformEnabled && (runner.?enabled ?? true)) {
    name: take('deploy-runner-${toLower(runner.repositoryOwner)}-${runnerJobNames[index]}', 64)
    scope: resourceGroup(runnerSpokeSubscriptionId, runnerSpokeResourceGroupName)
    dependsOn: [
      runnerEnvironment
    ]
    params: {
      name: runnerJobNames[index]
      location: runnerSpoke!.location
      environmentResourceId: resourceId(
        runnerSpokeSubscriptionId,
        runnerSpokeResourceGroupName,
        'Microsoft.App/managedEnvironments',
        resolvedContainerAppsEnvironmentName
      )
      identityResourceId: platformServices!.outputs.runnerIdentityResourceId
      runner: runner
      image: runner.?image ?? '${platformServices!.outputs.containerRegistryLoginServer}/github-runner:latest'
      containerRegistryLoginServer: platformServices!.outputs.containerRegistryLoginServer
      githubAppPrivateKeySecretUri: '${platformServices!.outputs.keyVaultUri}secrets/${githubApp!.?privateKeySecretName ?? 'github-app-private-key'}'
      githubApplicationId: githubApp!.applicationId
      githubInstallationId: runner.?installationId ?? githubApp!.installationId
      githubApiUrl: githubApp!.?apiUrl ?? 'https://api.github.com'
      tags: runner.?tags ?? tags
      enableTelemetry: enableTelemetry
    }
  }
]

@description('Resource ID of the resource group holding the shared Private DNS zones.')
output dnsResourceGroupResourceId string = dnsResourceGroup.outputs.resourceId

@description('Name of the resource group holding the shared Private DNS zones.')
output dnsResourceGroupName string = dnsResourceGroup.outputs.name

@description('The Private DNS zones that were deployed, with region tokens resolved and virtual network links applied.')
output privateDnsZones array = privateDnsZones.outputs.combinedPrivateLinkPrivateDnsZonesReplacedWithVnetsToLink

@description('The hubs that were deployed, with the resource IDs a spoke or a Container Apps environment needs to attach to one.')
output hubs array = [
  for (hub, index) in hubs: {
    name: hub.name
    location: hub.location
    subscriptionId: hub.?subscriptionId ?? defaultSubscriptionId
    resourceGroupName: hub.resourceGroupName
    virtualNetworkResourceId: hubNetworks[index].outputs.virtualNetworkResourceId
    virtualNetworkName: hubNetworks[index].outputs.virtualNetworkName
    addressPrefixes: hubNetworks[index].outputs.addressPrefixes
    bastionResourceId: hubNetworks[index].outputs.bastionResourceId
    bastionSubnetResourceId: hubNetworks[index].outputs.bastionSubnetResourceId
    jumpboxSubnetResourceId: hubNetworks[index].outputs.jumpboxSubnetResourceId
    firewallResourceId: hubNetworks[index].outputs.firewallResourceId
    firewallPrivateIp: hubNetworks[index].outputs.firewallPrivateIp
    jumpboxes: hubNetworks[index].outputs.jumpboxes
  }
]

@description('The spokes that were deployed, with their virtual network and subnet resource IDs and the hub each is peered to.')
output spokes array = [
  for (spoke, index) in spokes: {
    name: spoke.name
    hubName: spoke.hubName
    location: spoke.location
    subscriptionId: spoke.?subscriptionId ?? defaultSubscriptionId
    resourceGroupName: spoke.resourceGroupName
    virtualNetworkResourceId: spokeNetworks[index].outputs.virtualNetworkResourceId
    virtualNetworkName: spokeNetworks[index].outputs.virtualNetworkName
    addressPrefixes: spokeNetworks[index].outputs.addressPrefixes
    subnets: spokeNetworks[index].outputs.subnets
  }
]

@description('The shared platform services, with the resource IDs an operator needs to seed the GitHub App private key and publish the runner image.')
output platform object = platformEnabled
  ? {
      name: platform!.name
      spokeName: platform!.spokeName
      subscriptionId: platformSubscriptionId
      resourceGroupName: platformResourceGroupName
      location: platformLocation
      logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
      keyVaultName: platformServices!.outputs.keyVaultName
      keyVaultUri: platformServices!.outputs.keyVaultUri
      containerRegistryName: platformServices!.outputs.containerRegistryName
      containerRegistryLoginServer: platformServices!.outputs.containerRegistryLoginServer
      runnerIdentityResourceId: platformServices!.outputs.runnerIdentityResourceId
      runnerIdentityClientId: platformServices!.outputs.runnerIdentityClientId
    }
  : {}

@description('The Container Apps environment hosting the self-hosted runner jobs, or an empty object when none is deployed.')
output containerAppsEnvironment object = containerAppsEnvironmentEnabled
  ? {
      name: runnerEnvironment!.outputs.name
      resourceId: runnerEnvironment!.outputs.resourceId
      spokeName: runnerSpoke!.name
      subscriptionId: runnerSpokeSubscriptionId
      resourceGroupName: runnerSpokeResourceGroupName
      workloadProfileName: runnerEnvironment!.outputs.workloadProfileName
    }
  : {}

@description('The self-hosted runner jobs that were deployed, one per repository.')
output githubRunners array = [
  for (runner, index) in githubRunners: {
    repository: '${runner.repositoryOwner}/${runner.repositoryName}'
    enabled: containerAppsEnvironmentEnabled && platformEnabled && (runner.?enabled ?? true)
    jobName: runner.?name ?? take('cj-${toLower(replace(runner.repositoryName, '.', '-'))}', 32)
  }
]
