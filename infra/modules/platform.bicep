targetScope = 'resourceGroup'

import { platformKeyVaultType, platformContainerRegistryType } from '../types.bicep'

// Shared platform services for one region: the Key Vault holding CI/CD credentials, the
// container registry holding the self-hosted runner image, and the managed identity the
// runner jobs run as.
//
// These are workload-adjacent shared services, not connectivity, so they land in a spoke
// rather than in the hub. The caller resolves which spoke and passes its private endpoint
// subnet in; nothing here restates a location, subscription or address range.
//
// Both resources are reachable over a private endpoint only, so this module has to run after
// the spoke networks and the Private DNS zones exist. The shared Log Analytics workspace is
// deliberately *not* here - it has to exist before the networks, because they send
// diagnostics to it. See modules/log-analytics.bicep.

@description('Required. Short name of the platform stamp. Resource names are derived from it.')
@minLength(1)
@maxLength(40)
param name string

@description('Optional. Azure region for the platform resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Resource ID of the subnet that private endpoints land in. It lives in the spoke that hosts this platform stamp.')
@minLength(1)
param privateEndpointSubnetResourceId string

@description('Optional. Resource ID of the `privatelink.vaultcore.azure.net` Private DNS zone. Required when a Key Vault is deployed, so that the private endpoint resolves.')
param keyVaultPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the `privatelink.azurecr.io` Private DNS zone. Required when a container registry is deployed. Registry data endpoints are records inside this same zone, so no second zone is needed.')
param containerRegistryPrivateDnsZoneResourceId string = ''

@description('Optional. Resource ID of the shared Log Analytics workspace that receives diagnostics. Empty to create no diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Shared Key Vault configuration. Omit to deploy the platform without one.')
param keyVault platformKeyVaultType?

@description('Optional. Shared container registry configuration. Omit to deploy the platform without one.')
param containerRegistry platformContainerRegistryType?

@description('Optional. Name of the user-assigned managed identity the Container Apps runner jobs run as. It is created here rather than in the hub so that its `AcrPull` and `Key Vault Secrets User` assignments are same-resource-group, which is what lets the constrained RBAC grant on the deployment identity stay narrow.')
@minLength(3)
@maxLength(128)
param runnerIdentityName string = 'id-${name}-runner'

@description('Optional. Create the runner identity and grant it read access to the vault secrets and the registry. Defaults to `true`.')
param createRunnerIdentity bool = true

@description('Optional. Tags applied to every platform resource.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

var keyVaultEnabled = keyVault != null && (keyVault!.?enabled ?? true)
var containerRegistryEnabled = containerRegistry != null && (containerRegistry!.?enabled ?? true)

// Key Vault and container registry names share one namespace across every Azure tenant, so a
// readable name such as `kv-platform-cus` is as likely as not already taken by a stranger.
// Deriving a deterministic suffix keeps the name unique without making it a decision anyone has
// to revisit: it is stable for a given subscription and platform stamp, so a redeployment never
// renames a resource, while a second region or subscription gets its own. That matters more for
// the vault than it looks - purge protection holds a deleted name for the soft-delete window, so
// a collision is not something you can simply rename your way out of.
var uniqueSuffix = take(uniqueString(subscription().id, name), 6)

// Key Vault allows alphanumerics and hyphens, must start with a letter, must not contain two
// consecutive hyphens, and is capped at 24 characters. Truncating a long platform name can leave
// a trailing hyphen that would collide with the separator, so it is trimmed first.
var keyVaultNameStem = take('kv-${name}', 24 - length(uniqueSuffix) - 1)
var keyVaultNamePrefix = endsWith(keyVaultNameStem, '-')
  ? take(keyVaultNameStem, length(keyVaultNameStem) - 1)
  : keyVaultNameStem
var keyVaultName = keyVault.?name ?? '${keyVaultNamePrefix}-${uniqueSuffix}'

// Registry names are lowercase alphanumerics only - no hyphens at all - so the separator the
// vault name uses is not available here and the platform name has its hyphens stripped.
var containerRegistryName = containerRegistry.?name ?? toLower('acr${replace(name, '-', '')}${uniqueSuffix}')

// Built-in role definition GUIDs. Data-plane reader roles only: the runner identity pulls an
// image and reads one secret, and holds nothing that can write to either resource.
var acrPullRoleDefinitionGuid = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var keyVaultSecretsUserRoleDefinitionGuid = '4633458b-17de-408a-b874-0445c86b69e6'

var platformDiagnosticSettings = empty(logAnalyticsWorkspaceResourceId)
  ? null
  : [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]

// The identity the runner jobs run as. It is created before the vault and the registry so that
// both can carry its role assignments directly, rather than needing a separate assignment
// module and a second deployment scope.
module runnerIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = if (createRunnerIdentity) {
  name: 'id-${name}-runner'
  params: {
    name: runnerIdentityName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// RBAC authorization, not access policies: access policies cannot be scoped to a single
// secret, are not visible to Azure RBAC tooling, and are on the way out.
//
// Purge protection is deliberately non-negotiable. It cannot be turned off once on, which is
// the point: it stops a deleted vault name being re-registered by someone else while the soft
// delete is still pending.
module vault 'br/public:avm/res/key-vault/vault:0.14.2' = if (keyVaultEnabled) {
  name: 'kv-${name}'
  params: {
    name: keyVaultName
    location: location
    sku: keyVault!.?skuName ?? 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: keyVault!.?softDeleteRetentionInDays ?? 90
    // No public endpoint at all. The Container Apps Key Vault reference resolves from inside
    // the environment's subnet - the documented firewall requirement for that feature is on
    // the customer's own egress path, not on an Azure-side control plane - so a private
    // endpoint is sufficient for the runner jobs. It does mean the vault is unreachable from
    // a laptop or a Microsoft-hosted GitHub runner; seed secrets from a jump box.
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    privateEndpoints: [
      {
        name: 'pep-${keyVaultName}'
        service: 'vault'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: keyVaultPrivateDnsZoneResourceId
            }
          ]
        }
        tags: tags
      }
    ]
    // Read-only on secrets, nothing else. The runner never writes to the vault.
    roleAssignments: createRunnerIdentity
      ? [
          {
            principalId: runnerIdentity!.outputs.principalId
            roleDefinitionIdOrName: keyVaultSecretsUserRoleDefinitionGuid
            principalType: 'ServicePrincipal'
            description: 'Lets the Container Apps runner jobs read the GitHub App private key.'
          }
        ]
      : null
    diagnosticSettings: platformDiagnosticSettings
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// Premium is not a preference. Private endpoints, IP network rules and the ACR Tasks bypass
// are all Premium-only features.
//
// Public network access stays Enabled with a default action of Deny, rather than Disabled.
// That is not a weaker posture than it looks: with no IP rules matched, nothing on the public
// internet can reach the data plane. It is Enabled because `az acr build` runs on
// Microsoft-managed ACR Tasks compute outside the virtual network, and Azure rejects it
// outright against a registry whose public access is Disabled - there is no runner that can
// build the very image the runners are built from, and jobs cannot run Docker, so ACR Tasks
// is the only way to produce it.
module registry 'br/public:avm/res/container-registry/registry:0.13.1' = if (containerRegistryEnabled) {
  name: 'cr-${name}'
  params: {
    name: containerRegistryName
    location: location
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    networkRuleSetDefaultAction: 'Deny'
    // Lets ACR Tasks through the network rules without naming its addresses. Preferred over
    // the IP list below, which is kept as a fallback because this property is newer than the
    // documentation that tells you to allow-list the service tag.
    networkRuleBypassAllowedForTasks: true
    networkRuleBypassOptions: 'AzureServices'
    networkRuleSetIpRules: [
      for range in (containerRegistry!.?allowedPublicIpRanges ?? []): {
        action: 'Allow'
        value: range
      }
    ]
    // Untagged manifests are what a rebuilt `:latest` leaves behind. Without this they
    // accumulate forever and are billed as storage.
    retentionPolicyStatus: 'enabled'
    retentionPolicyDays: containerRegistry!.?untaggedManifestRetentionDays ?? 7
    softDeletePolicyStatus: 'disabled'
    // Export policy stays enabled, which is not a free choice: Azure rejects
    // `exportPolicyStatus: 'disabled'` with DisableExport_PublicNetworkAccessMustBeDisabled
    // unless public network access is also Disabled. Since ACR Tasks needs that public endpoint
    // to build the very first runner image, the two are mutually exclusive. The network rules
    // above are what actually restrict access; the export policy would only have stopped an
    // already-authorized principal copying artifacts out.
    exportPolicyStatus: 'enabled'
    zoneRedundancy: 'Disabled'
    privateEndpoints: [
      {
        name: 'pep-${containerRegistryName}'
        service: 'registry'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: containerRegistryPrivateDnsZoneResourceId
            }
          ]
        }
        tags: tags
      }
    ]
    // Pull only. The runner identity must never be able to push an image that it then runs.
    roleAssignments: createRunnerIdentity
      ? [
          {
            principalId: runnerIdentity!.outputs.principalId
            roleDefinitionIdOrName: acrPullRoleDefinitionGuid
            principalType: 'ServicePrincipal'
            description: 'Lets the Container Apps runner jobs pull the runner image.'
          }
        ]
      : null
    diagnosticSettings: platformDiagnosticSettings
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the shared Key Vault, or an empty string when it is not deployed.')
output keyVaultResourceId string = keyVaultEnabled ? vault!.outputs.resourceId : ''

@description('Name of the shared Key Vault, or an empty string when it is not deployed.')
output keyVaultName string = keyVaultEnabled ? vault!.outputs.name : ''

@description('Base URI of the shared Key Vault, or an empty string when it is not deployed. Container Apps secrets reference a secret underneath this URI.')
output keyVaultUri string = keyVaultEnabled ? vault!.outputs.uri : ''

@description('Resource ID of the shared container registry, or an empty string when it is not deployed.')
output containerRegistryResourceId string = containerRegistryEnabled ? registry!.outputs.resourceId : ''

@description('Login server of the shared container registry, or an empty string when it is not deployed. This is the image prefix a Container Apps job pulls from.')
output containerRegistryLoginServer string = containerRegistryEnabled ? registry!.outputs.loginServer : ''

@description('Name of the shared container registry, or an empty string when it is not deployed.')
output containerRegistryName string = containerRegistryEnabled ? registry!.outputs.name : ''

@description('Resource ID of the user-assigned managed identity the runner jobs run as, or an empty string when it is not created.')
output runnerIdentityResourceId string = createRunnerIdentity ? runnerIdentity!.outputs.resourceId : ''

@description('Principal ID of the runner identity, or an empty string when it is not created.')
output runnerIdentityPrincipalId string = createRunnerIdentity ? runnerIdentity!.outputs.principalId : ''

@description('Client ID of the runner identity, or an empty string when it is not created.')
output runnerIdentityClientId string = createRunnerIdentity ? runnerIdentity!.outputs.clientId : ''
