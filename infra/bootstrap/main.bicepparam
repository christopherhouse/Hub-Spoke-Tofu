using './main.bicep'

param identityResourceGroupName = 'RG-CICD-CUS'

param identityName = 'id-hub-spoke-iac-cicd'

param location = 'centralus'

// Subscriptions the workflow deploys hubs and spokes into, beyond the one this template is
// deployed to, which is always granted. Redeploy this template by hand after adding one; the
// identity cannot grant itself access.
//
//   8043efb5-... ME-MngEnvMCAP758145-chhouse-2, home of the spoke-app-cus spoke.
param targetSubscriptionIds = [
  '8043efb5-d046-4aac-abcd-2c1a00e5ab86'
]

// Federated credential subjects use the immutable prefix GitHub presents, which embeds these
// numeric IDs. Confirm with: gh api repos/<owner>/<repo>/actions/oidc/customization/sub
param githubOwner = 'christopherhouse'

param githubOwnerId = 748998

param githubRepository = 'Hub-Spoke-Tofu'

param githubRepositoryId = 1376095163

// A single environment. There is no dev/test/prod split, and no required reviewers.
param githubEnvironmentName = 'azure'

param githubBranchName = 'main'

param tags = {
  workload: 'cicd'
  'managed-by': 'bicep'
  environment: 'shared'
}
