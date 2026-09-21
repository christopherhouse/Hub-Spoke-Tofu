targetScope = 'resourceGroup'


// Azure Container Apps environment that hosts the self-hosted CI/CD runner jobs.
//
// It is deployed into the hub's `snet-runners`, which is delegated to
// `Microsoft.App/environments` and sized /26. That subnet cannot be resized once an
// environment exists in it, so the environment is created against the subnet as-is and the
// address plan must not be narrowed afterwards.
//
// Only the Consumption workload profile is configured. That is the serverless one: replicas
// are billed per second while a job execution runs and nothing is billed when the queue is
// empty, which is the entire economic argument for running runners this way. A dedicated
// profile would reserve nodes and bill continuously.

@description('Required. Name of the Container Apps environment.')
@minLength(1)
@maxLength(60)
param name string

@description('Optional. Azure region for the environment. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Resource ID of the subnet the environment is injected into. It must be delegated to `Microsoft.App/environments` and be /27 or larger.')
@minLength(1)
param infrastructureSubnetResourceId string

@description('Optional. Give the environment an internal load balancer only, with no public static IP. Defaults to `true`.')
param internal bool = true

@description('Optional. Spread the environment across availability zones. Defaults to `false`, and cannot be changed after creation.')
param zoneRedundant bool = false

@description('Optional. Resource ID of the Log Analytics workspace that receives console and system logs, plus the environment\'s own diagnostic settings. Empty to send nothing, in which case job output is only visible through the live log stream.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Optional. Name of the resource group Azure creates for the environment\'s own infrastructure. It is managed by the platform, not by this deployment. Defaults to `<resource group>-<name>-infra`, truncated to the 90-character limit.')
@maxLength(63)
param infrastructureResourceGroupName string = ''

@description('Optional. Tags applied to the environment.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

var logsEnabled = !empty(logAnalyticsWorkspaceResourceId)

// Azure requires this to be distinct from the resource group the environment itself lives in,
// and it must not already exist. The uniqueString keeps it stable across deployments while
// staying inside the length limit.
var resolvedInfrastructureResourceGroupName = !empty(infrastructureResourceGroupName)
  ? infrastructureResourceGroupName
  : take('${name}-infra-${uniqueString(resourceGroup().id, name)}', 63)

// Logs go to the `azure-monitor` destination, not `log-analytics`, and are then routed to the
// shared workspace by the diagnostic setting below.
//
// This is deliberate. The `log-analytics` destination is configured with the workspace
// customer ID and a **shared key**, which the AVM module obtains with `listKeys`. That is
// exactly the class of credential this repository does not use anywhere else - see the
// Entra-only principle in README.md. The `azure-monitor` destination carries no credential at
// all: the environment emits to Azure Monitor and an ordinary diagnostic setting decides
// where it lands, authorised by ARM rather than by a key. The data ends up in the same
// workspace either way.
module managedEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'cae-${uniqueString(name)}'
  params: {
    name: name
    location: location
    infrastructureSubnetResourceId: infrastructureSubnetResourceId
    internal: internal
    // Nothing in this environment serves inbound traffic; the runner jobs poll outbound.
    publicNetworkAccess: 'Disabled'
    // Cannot be changed after creation. Runner replicas are ephemeral and stateless, so a
    // zonal outage costs a retried workflow rather than data.
    zoneRedundant: zoneRedundant
    // The serverless profile. Billed per second of execution, nothing when idle.
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    infrastructureResourceGroupName: resolvedInfrastructureResourceGroupName
    appLogsConfiguration: logsEnabled
      ? {
          destination: 'azure-monitor'
        }
      : null
    // Carries the container console and system logs to the shared workspace. Without this the
    // `azure-monitor` destination above has nowhere to deliver to and job output is only
    // visible in the live log stream.
    diagnosticSettings: logsEnabled
      ? [
          {
            name: 'send-to-log-analytics'
            workspaceResourceId: logAnalyticsWorkspaceResourceId
          }
        ]
      : null
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the Container Apps environment.')
output resourceId string = managedEnvironment.outputs.resourceId

@description('Name of the Container Apps environment.')
output name string = managedEnvironment.outputs.name

@description('Static IP of the environment, or an empty string when the platform has not assigned one yet. It is a private address, because the environment is internal.')
output staticIp string = managedEnvironment.outputs.?staticIp ?? ''

@description('Name of the workload profile the runner jobs should run on.')
output workloadProfileName string = 'Consumption'
