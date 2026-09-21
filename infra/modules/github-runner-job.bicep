targetScope = 'resourceGroup'

import { githubRunnerType } from '../types.bicep'

// One event-driven Container Apps job serving one GitHub repository as a self-hosted runner.
//
// Why one job per repository, rather than one job serving many:
//
// A runner registration targets exactly one repository, and the KEDA `github-runner` scaler
// does not tell a replica which repository queued the work it just scaled for. A single job
// watching several repositories would therefore start a replica that has no way of knowing
// where to register. Organisation-scoped runners avoid this, but a personal GitHub account
// has no organisation scope - runners exist at repository, organisation and enterprise level
// only. So: one job per repository. An idle job has no replicas and costs nothing, so the
// only cost of this shape is a longer parameter file.
//
// Authentication is a GitHub App, not a personal access token. The App private key is read
// from Key Vault by the job's managed identity, so the deployment never handles it, and one
// App covers every repository it is installed on rather than one token per repository.

@description('Required. Name of the Container Apps job.')
@minLength(2)
@maxLength(32)
param name string

@description('Optional. Azure region for the job. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Resource ID of the Container Apps environment that hosts the job.')
@minLength(1)
param environmentResourceId string

@description('Optional. Workload profile the job runs on. Defaults to `Consumption`, the serverless profile, which bills per second of execution and nothing when idle.')
@minLength(1)
param workloadProfileName string = 'Consumption'

@description('Required. Resource ID of the user-assigned managed identity the job runs as. It needs `AcrPull` on the registry and `Key Vault Secrets User` on the vault.')
@minLength(1)
param identityResourceId string

@description('Required. The runner definition: which repository it serves and how much compute it gets.')
param runner githubRunnerType

@description('Required. Fully qualified container image, including the tag.')
@minLength(1)
param image string

@description('Required. Login server of the registry the image is pulled from, for example `crplatformcus.azurecr.io`.')
@minLength(1)
param containerRegistryLoginServer string

@description('Required. Full URI of the Key Vault secret holding the GitHub App private key in PEM form, for example `https://kv-platform-cus.vault.azure.net/secrets/github-app-private-key`. Deliberately versionless, so rotating the secret is picked up without a redeployment.')
@minLength(1)
param githubAppPrivateKeySecretUri string

@description('Required. The GitHub App ID. Not a secret.')
@minLength(1)
param githubApplicationId string

@description('Required. Installation ID of the GitHub App for this repository\'s account. Resolved by the caller, because a GitHub App has one installation per account rather than one per repository.')
@minLength(1)
param githubInstallationId string

@description('Optional. GitHub API base URL. Defaults to `https://api.github.com`.')
@minLength(1)
param githubApiUrl string = 'https://api.github.com'

@description('Optional. Tags applied to the job.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

// Name of the job secret that carries the App private key. The scale rule references it by
// name through `auth`, and the container reads it through `secretRef`, so both sides must
// agree on this one string.
var privateKeySecretName = 'github-app-private-key'

var runnerLabels = runner.?labels ?? []

// GitHub always applies `self-hosted`, `linux` and `x64` regardless of what the runner asks
// for, and the scaler matches on the full set. Leaving `labels` off the scale rule metadata
// entirely means "scale on the defaults", which is what a workflow saying `runs-on:
// self-hosted` needs.
var scaleRuleLabelMetadata = empty(runnerLabels)
  ? {}
  : {
      labels: join(runnerLabels, ',')
    }

module job 'br/public:avm/res/app/job:0.7.2' = {
  name: 'cj-${uniqueString(name)}'
  params: {
    name: name
    location: location
    environmentResourceId: environmentResourceId
    workloadProfileName: workloadProfileName
    triggerType: 'Event'
    managedIdentities: {
      userAssignedResourceIds: [
        identityResourceId
      ]
    }
    // Pulled with the managed identity. The registry has no admin user and no anonymous pull,
    // so there is no registry credential to store anywhere.
    registries: [
      {
        server: containerRegistryLoginServer
        identity: identityResourceId
      }
    ]
    // Resolved by the platform from Key Vault using the job's managed identity. The vault is
    // reachable over its private endpoint from the environment's subnet, and the URI is
    // versionless so a rotated key is picked up automatically.
    secrets: [
      {
        name: privateKeySecretName
        keyVaultUrl: githubAppPrivateKeySecretUri
        identity: identityResourceId
      }
    ]
    // A workflow job that outruns this is killed mid-step. It is the ceiling on one workflow
    // job, not on a whole workflow.
    replicaTimeout: runner.?replicaTimeout ?? 1800
    // Zero retries on purpose. A replica registers an ephemeral runner and exits after one
    // job; retrying it would register a second runner for work that GitHub has already
    // handed out, and the retry would simply idle until it timed out.
    replicaRetryLimit: 0
    eventTriggerConfig: {
      parallelism: 1
      replicaCompletionCount: 1
      scale: {
        minExecutions: 0
        maxExecutions: runner.?maxExecutions ?? 5
        pollingInterval: runner.?pollingInterval ?? 30
        rules: [
          {
            name: 'github-runner'
            type: 'github-runner'
            metadata: union(
              {
                githubAPIURL: githubApiUrl
                owner: runner.repositoryOwner
                // A personal account has no organisation scope; see the note at the top.
                runnerScope: 'repo'
                repos: runner.repositoryName
                applicationID: githubApplicationId
                installationID: githubInstallationId
                targetWorkflowQueueLength: '1'
                // Conditional requests against the GitHub API return 304 when nothing has
                // changed, and a 304 does not count against the rate limit. With a job
                // polling every 30 seconds this is the difference between comfortably inside
                // the limit and exhausting it.
                enableEtags: 'true'
              },
              scaleRuleLabelMetadata
            )
            auth: [
              {
                // The scaler signs a GitHub App JWT with this key to read the workflow queue.
                triggerParameter: 'appKey'
                secretRef: privateKeySecretName
              }
            ]
          }
        ]
      }
    }
    containers: [
      {
        name: 'runner'
        image: image
        resources: {
          // On the Consumption profile these are not free choices: memory in GiB must be
          // exactly twice the CPU count, or the job is rejected at deployment.
          cpu: json(runner.?cpu ?? '1.0')
          memory: runner.?memory ?? '2Gi'
        }
        env: [
          {
            name: 'GITHUB_API_URL'
            value: githubApiUrl
          }
          {
            name: 'GITHUB_APP_ID'
            value: githubApplicationId
          }
          {
            name: 'GITHUB_APP_INSTALLATION_ID'
            value: githubInstallationId
          }
          {
            name: 'GITHUB_REPOSITORY_OWNER'
            value: runner.repositoryOwner
          }
          {
            name: 'GITHUB_REPOSITORY_NAME'
            value: runner.repositoryName
          }
          {
            name: 'RUNNER_LABELS'
            value: join(runnerLabels, ',')
          }
          {
            // The same key the scaler uses. The container exchanges it for an installation
            // token and then for a one-time runner registration token.
            name: 'GITHUB_APP_PRIVATE_KEY'
            secretRef: privateKeySecretName
          }
        ]
      }
    ]
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the Container Apps job.')
output resourceId string = job.outputs.resourceId

@description('Name of the Container Apps job.')
output name string = job.outputs.name

@description('The repository this job serves, as `owner/name`.')
output repository string = '${runner.repositoryOwner}/${runner.repositoryName}'
