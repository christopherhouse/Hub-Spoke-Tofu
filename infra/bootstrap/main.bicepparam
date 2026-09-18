using './main.bicep'

param identityResourceGroupName = 'RG-CICD-CUS'

param identityName = 'id-hub-spoke-iac-cicd'

param location = 'centralus'

// Federated credential subjects embed the owner and repository. The repository is still named
// after the removed OpenTofu implementation; renaming it means redeploying this template.
param githubOwner = 'christopherhouse'

param githubRepository = 'Hub-Spoke-Tofu'

// A single environment. There is no dev/test/prod split, and no required reviewers.
param githubEnvironmentName = 'azure'

param githubBranchName = 'main'

param tags = {
  workload: 'cicd'
  'managed-by': 'bicep'
  environment: 'shared'
}
