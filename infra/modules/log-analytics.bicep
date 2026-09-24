targetScope = 'resourceGroup'

import { platformLogAnalyticsType } from '../types.bicep'

// The shared per-region Log Analytics workspace.
//
// It is a module of its own, separate from the rest of the platform services, purely because
// of ordering. Every hub and spoke resource sends diagnostics here, so the workspace has to
// exist before any of them are created - a diagnostic setting naming a workspace that does
// not yet exist fails the deployment. The Key Vault and the container registry, by contrast,
// need a spoke subnet and a Private DNS zone that only exist *after* the networks are built.
// Splitting the two apart is what lets both orderings hold at once.
//
// The workspace is reachable over its public endpoint. That is deliberate: there is no Azure
// Monitor Private Link Scope in this design, and adding one silently stops ingestion from
// every resource outside the scope rather than failing loudly.

@description('Required. Name of the Log Analytics workspace.')
@minLength(4)
@maxLength(63)
param name string

@description('Optional. Azure region for the workspace. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Optional. Workspace configuration. Omit to take the defaults.')
param logAnalytics platformLogAnalyticsType?

@description('Optional. Tags applied to the workspace.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-${uniqueString(name)}'
  params: {
    name: name
    location: location
    // 30 days is included at no extra charge; beyond that is billed per GB per month.
    dataRetention: logAnalytics.?dataRetention ?? 30
    // A guard rail, not a capacity plan. A misconfigured diagnostic source can otherwise
    // ingest without limit, and the first sign of it is the bill. Raise it deliberately.
    dailyQuotaGb: logAnalytics.?dailyQuotaGb ?? '1'
    // The workspace's own audit and ingestion telemetry goes to itself. There is nowhere else
    // for it to go, and without it there is no view of what is consuming the daily quota.
    diagnosticSettings: [
      {
        name: 'send-to-self'
        workspaceResourceId: resourceId('Microsoft.OperationalInsights/workspaces', name)
      }
    ]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the shared Log Analytics workspace. Pass this into every other module so all diagnostics land in one place.')
output resourceId string = workspace.outputs.resourceId

@description('Name of the shared Log Analytics workspace.')
output name string = workspace.outputs.name

@description('Location the workspace was deployed into.')
output location string = location
