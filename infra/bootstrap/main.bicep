targetScope = 'subscription'

// Bootstrap root. Creates the identity that GitHub Actions uses to deploy infra/main.bicep.
//
// This is deployed ONCE, BY HAND. CI must never deploy it: the deployment identity cannot
// create itself. The pull request workflow builds this template so it cannot rot, but only
// infra/main.bicepparam is ever deployed by the workflow.
//
//   az deployment sub create \
//     --name bootstrap \
//     --location centralus \
//     --template-file infra/bootstrap/main.bicep \
//     --parameters infra/bootstrap/main.bicepparam

@description('Required. Name of the resource group that holds the deployment identity.')
@minLength(1)
@maxLength(90)
param identityResourceGroupName string

@description('Required. Name of the user-assigned managed identity GitHub Actions authenticates as. A managed identity is used rather than an Entra app registration: it needs no application object, which tenants often restrict, and it carries ordinary Azure RBAC.')
@minLength(3)
@maxLength(128)
param identityName string

@description('Required. Azure region for the resource group and the managed identity.')
@minLength(1)
param location string

@description('Required. GitHub account or organisation that owns the repository.')
@minLength(1)
param githubOwner string

@description('Required. GitHub repository name. Federated credential subjects embed this, so renaming the repository means redeploying this template.')
@minLength(1)
param githubRepository string

@description('Optional. Name of the GitHub Environment the deploy job gates on. There is a single environment; the repository has no dev/test/prod split.')
@minLength(1)
param githubEnvironmentName string = 'azure'

@description('Optional. Branch that is allowed to deploy. This is the deployment branch, so it should match the default branch.')
@minLength(1)
param githubBranchName string = 'main'

@description('Optional. Tags applied to the resource group and the managed identity.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

// Contributor. Sufficient for everything infra/main.bicep creates: resource groups, virtual
// networks, NSGs, Bastion, public IPs, and Private DNS zones with links. The templates create
// no role assignments, so User Access Administrator is deliberately NOT granted.
var contributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)

var githubRepositorySubjectPrefix = 'repo:${githubOwner}/${githubRepository}'

// Composed rather than read from the module output: a role assignment name must be
// calculable at the start of the deployment (BCP120), and `principalId` is only known once
// the identity exists. The identity resource ID is just as unique and is derived from the
// same parameters that create it.
var deploymentIdentityResourceIdValue = resourceId(
  subscription().subscriptionId,
  identityResourceGroupName,
  'Microsoft.ManagedIdentity/userAssignedIdentities',
  identityName
)

module cicdResourceGroup 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'deploy-cicd-rg'
  params: {
    name: identityResourceGroupName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// One federated credential per OIDC subject the workflow can present. The subject differs by
// trigger, and a missing one fails at run time rather than here, so all three are declared:
//   - pull_request              the build and what-if job on a pull request
//   - ref:refs/heads/<branch>   the validate job on push to the deployment branch, and
//                               workflow_dispatch
//   - environment:<name>        the deploy job, because it declares `environment:`
module deploymentIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'deploy-cicd-identity'
  scope: resourceGroup(identityResourceGroupName)
  dependsOn: [
    cicdResourceGroup
  ]
  params: {
    name: identityName
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
    federatedIdentityCredentials: [
      {
        name: 'gh-pull-request'
        issuer: 'https://token.actions.githubusercontent.com'
        audiences: [
          'api://AzureADTokenExchange'
        ]
        subject: '${githubRepositorySubjectPrefix}:pull_request'
      }
      {
        name: 'gh-${githubBranchName}'
        issuer: 'https://token.actions.githubusercontent.com'
        audiences: [
          'api://AzureADTokenExchange'
        ]
        subject: '${githubRepositorySubjectPrefix}:ref:refs/heads/${githubBranchName}'
      }
      {
        name: 'gh-env-${githubEnvironmentName}'
        issuer: 'https://token.actions.githubusercontent.com'
        audiences: [
          'api://AzureADTokenExchange'
        ]
        subject: '${githubRepositorySubjectPrefix}:environment:${githubEnvironmentName}'
      }
    ]
  }
}

// Raw resource exception.
//
// AVM catalog checked 2026-09-18. The only published role assignment module,
// br/public:avm/ptn/authorization/role-assignment:0.2.4, declares targetScope =
// 'managementGroup'. It therefore cannot be invoked from this subscription-scope root, and
// using it would demand management group write permission that a subscription-scope
// assignment does not require. There is no avm/res/authorization/role-assignment in the
// public registry.
//
// Re-evaluate on the next AVM upgrade: replace this if a subscription-scope role assignment
// module is published.
//
// The name is a deterministic guid of scope, identity and role definition, so redeploying
// this template is a no-op rather than a duplicate assignment.
resource deploymentIdentityContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, deploymentIdentityResourceIdValue, contributorRoleDefinitionId)
  properties: {
    roleDefinitionId: contributorRoleDefinitionId
    principalId: deploymentIdentity.outputs.principalId
    // Required. Without it the assignment fails while the new identity's service principal is
    // still replicating, because Azure falls back to a directory lookup to infer the type.
    principalType: 'ServicePrincipal'
    description: 'Lets GitHub Actions deploy infra/main.bicep into this subscription.'
  }
}

@description('Value for the AZURE_CLIENT_ID GitHub repository variable. This is the client ID, not the principal ID.')
output deploymentIdentityClientId string = deploymentIdentity.outputs.clientId

@description('Object ID of the identity service principal, as used in role assignments.')
output deploymentIdentityPrincipalId string = deploymentIdentity.outputs.principalId

@description('Resource ID of the user-assigned managed identity.')
output deploymentIdentityResourceId string = deploymentIdentity.outputs.resourceId

@description('Value for the AZURE_TENANT_ID GitHub repository variable.')
output tenantId string = tenant().tenantId

@description('Value for the AZURE_SUBSCRIPTION_ID GitHub repository variable.')
output subscriptionId string = subscription().subscriptionId

@description('The OIDC subjects trusted by the identity. Useful for confirming what the workflow can present.')
output federatedCredentialSubjects string[] = [
  '${githubRepositorySubjectPrefix}:pull_request'
  '${githubRepositorySubjectPrefix}:ref:refs/heads/${githubBranchName}'
  '${githubRepositorySubjectPrefix}:environment:${githubEnvironmentName}'
]
