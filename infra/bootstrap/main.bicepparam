using './main.bicep'

param identityResourceGroupName = 'RG-CICD-CUS'

param identityName = 'id-hub-spoke-iac-cicd'

param location = 'centralus'

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
