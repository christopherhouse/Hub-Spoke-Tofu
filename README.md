# hub-spoke-iac

Bicep infrastructure as code for an Azure hub-and-spoke network.

Hubs and spokes may live in different regions, subscriptions, and resource groups. Adding
either is a parameter change, not a template change.

## Current state

| Capability | Status |
|---|---|
| Shared Private Link DNS zone catalog | Implemented |
| Hub VNet, subnets, NSGs and Azure Bastion Standard | Implemented |
| NAT gateway on the jump box and runners subnets | Implemented |
| Windows jump boxes in the hub, Bastion-only, Entra sign-in | Implemented |
| Spoke VNets and bidirectional peering, across subscriptions | Implemented |
| Dedicated NSG on every subnet, rules set from parameters | Implemented |
| Shared platform spoke: Log Analytics, Key Vault, container registry | Implemented |
| Diagnostics from every supported resource to the shared workspace | Implemented |
| Self-hosted GitHub Actions runners on Container Apps jobs | Implemented |
| Self-hosted Azure DevOps agents | Not started |
| GitHub Actions deploy workflow | Implemented |
| CI/CD deployment identity (OIDC, no secrets) | Implemented |

## Layout

```
infra/
  main.bicep         subscription-scope composition root
  main.bicepparam    parameter values
  types.bicep        shared user-defined types, e.g. hubType (@export)
  zones.bicep        curated Private Link DNS zone catalog (@export)
  bootstrap/
    main.bicep       deployment identity and its RBAC, deployed by hand, never by CI
    main.bicepparam
    modules/
      subscription-role-assignment.bicep   one role for the identity on one subscription
  modules/
    hub.bicep        hub VNet, subnets, NSGs, Azure Bastion and the NAT gateway
    spoke.bicep      spoke VNet, subnets, per-subnet NSGs and peering to its hub
    log-analytics.bicep              shared workspace, deployed before anything reports to it
    platform.bicep                   Key Vault, container registry and the runner identity
    container-apps-environment.bicep runner environment in the hub runners subnet
    github-runner-job.bicep          one event-driven runner job per repository
  README.md
images/
  github-runner/     Dockerfile and entrypoint for the self-hosted runner image
bicepconfig.json     Bicep linter configuration
.github/
  scripts/onboard_runner.py
  workflows/deploy.yml
  workflows/build-runner-image.yml
  workflows/onboard-runner.yml
  copilot-instructions.md
```

## Design principles

- **Azure Verified Modules first.** Every Azure resource comes from a published AVM pinned
  to an exact version. Pattern modules are preferred over hand-composed resource modules.
- **Entra-only authentication.** No storage keys, SAS tokens, or client secrets anywhere.
  GitHub Actions authenticates with workload identity federation over OIDC.
- **Subscriptions are data.** Bicep targets a scope per module, so cross-subscription
  deployment needs no provider plumbing.
- **Stateless.** There is no state file and therefore no state storage account. This was the
  reason for moving off OpenTofu; see `.github/copilot-instructions.md`.

## Deploying

Requires Azure CLI with the Bicep extension.

### Subscription prerequisite: public IP allocation

Bastion and the NAT gateway each need a public IP. Some subscriptions cannot allocate one
until the `AllowBringYourOwnPublicIpAddress` feature is registered, and fail with:

```
SubscriptionNotRegisteredForFeature - Subscription ... is not registered for feature
Microsoft.Network/AllowBringYourOwnPublicIpAddress
```

Despite the name, this gates *all* public IP creation on such a subscription, not just
bring-your-own ranges. It is a subscription capability, not a policy or a template defect —
a bare `az network public-ip create` fails identically. Register it once per subscription:

```powershell
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state
az provider register --namespace Microsoft.Network
```

The provider re-registration is required to propagate the change. `what-if` does **not**
surface this, because the check happens when the resource is actually created.

### Subscription prerequisite: RBAC for a new subscription

The workflow deploys as `id-hub-spoke-iac-cicd`, which holds Contributor only on the
subscriptions listed in `infra/bootstrap/main.bicepparam`. Placing a hub or spoke in a new
subscription therefore needs one manual step first — the identity holds only a narrowly
conditioned **Role Based Access Control Administrator** grant, limited to assigning `AcrPull`
and `Key Vault Secrets User`, so it cannot widen its own access.

1. Add the subscription ID to `targetSubscriptionIds` in `infra/bootstrap/main.bicepparam`.
2. Redeploy the bootstrap root **by hand**, from an account with Owner or User Access
   Administrator on that subscription:

```powershell
az deployment sub create `
  --name bootstrap `
  --location centralus `
  --template-file infra/bootstrap/main.bicep `
  --parameters infra/bootstrap/main.bicepparam
```

Do this **before pushing the branch**. Without it the pull request `what-if` job fails, not
just the deploy. CI must never run this template: the identity cannot create itself, and
granting rights to itself is exactly the permission it does not hold.

### Subscription prerequisite: encryption at host

Jump boxes set `encryptionAtHost: true`, which requires a one-time feature registration.
Preflight fails without it, and `what-if` does not surface it:

```powershell
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state
az provider register --namespace Microsoft.Compute
```

### Subscription prerequisite: resource providers

The platform spoke and the runner environment need two providers registered. Like the feature
flags above, `what-if` does **not** surface a missing registration:

```powershell
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.ContainerRegistry
```

### Manual step: jump box sign-in

Signing into a jump box with Entra ID needs a role assignment that this deployment cannot
create, because the identity is Contributor and not User Access Administrator:

```powershell
az role assignment create `
  --role "Virtual Machine Administrator Login" `
  --assignee <user-object-id-or-upn> `
  --scope /subscriptions/<sub>/resourceGroups/RG-CONNECTIVITY-HUB-CUS
```

See [`infra/README.md`](infra/README.md) for the jump box design, the break-glass path, and
what the bootstrap installs.

### Commands

```powershell
az bicep build --file infra/main.bicep
az bicep build-params --file infra/main.bicepparam

az deployment sub what-if `
  --name infra-local `
  --location centralus `
  --parameters infra/main.bicepparam

az deployment sub create `
  --name infra-local `
  --location centralus `
  --parameters infra/main.bicepparam
```

## Contributing

All work happens on feature branches; `main` is the deployment branch and takes no direct
commits. Branch from `main`, open a pull request, review the `what-if` output the workflow
posts, then merge to deploy.

## CI/CD

`.github/workflows/deploy.yml` builds and runs `what-if` on pull requests, then deploys on
push to `main` through the `azure` GitHub Environment. There is a single environment — no
dev/test/prod split — and it carries no required reviewers, so a merge to `main` deploys.

Authentication is workload identity federation over OIDC. **No secret of any kind is stored
in GitHub.** The three values the workflow needs are repository **variables**:

| Variable | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | Client ID of the deployment managed identity |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |

### Bootstrap

`infra/bootstrap/main.bicep` creates the identity the workflow authenticates as:

- resource group `RG-CICD-CUS` in `centralus`,
- user-assigned managed identity `id-hub-spoke-iac-cicd` — a managed identity rather than an
  Entra app registration, because it needs no application object, which tenants often restrict,
- three federated credentials, one per OIDC subject the workflow can present,
- `Contributor` on the target subscription. Not `User Access Administrator`: nothing in the
  templates creates role assignments.

It is deployed **once, by hand**. CI never deploys it — the deployment identity cannot create
itself — though the pull request job builds it so it cannot rot.

```powershell
az deployment sub what-if `
  --name bootstrap-cicd `
  --location centralus `
  --template-file infra/bootstrap/main.bicep `
  --parameters infra/bootstrap/main.bicepparam

az deployment sub create `
  --name bootstrap-cicd `
  --location centralus `
  --template-file infra/bootstrap/main.bicep `
  --parameters infra/bootstrap/main.bicepparam
```

Its outputs feed the repository variables above. Re-running it is a no-op: the role assignment
name is a deterministic GUID.

The GitHub Environment and the repository variables are the only parts not expressed in Bicep,
because no Azure template can create them:

```powershell
gh api -X PUT repos/<owner>/<repo>/environments/azure --silent
gh variable set AZURE_CLIENT_ID --body '<deploymentIdentityClientId output>'
gh variable set AZURE_TENANT_ID --body '<tenantId output>'
gh variable set AZURE_SUBSCRIPTION_ID --body '<subscriptionId output>'
```

### Federated credential subjects

The OIDC subject differs by trigger. A job that declares `environment:` presents the
environment subject, **not** the branch subject — which is why there are three.

This repository has GitHub's **immutable subject claims** enabled, so the subject embeds the
numeric owner and repository IDs rather than their names. Confirm the exact prefix with:

```powershell
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
```

A credential built from the names alone is rejected at run time with `AADSTS700213`.

| Credential | Subject | Used by |
|---|---|---|
| `gh-pull-request` | `repo:<owner>@<ownerId>/<repo>@<repoId>:pull_request` | the PR build and `what-if` job |
| `gh-main` | `repo:<owner>@<ownerId>/<repo>@<repoId>:ref:refs/heads/main` | validate on push to `main`, and `workflow_dispatch` |
| `gh-env-azure` | `repo:<owner>@<ownerId>/<repo>@<repoId>:environment:azure` | the deploy job |

Adding a trigger means adding a credential to the bootstrap template and redeploying it.
Because the subjects carry immutable IDs, renaming the account or the repository does **not**
invalidate them.

## Notes

- `RG-TF-STATE-CUS` and the storage account `satfstatecmhcus` were created by the removed
  OpenTofu bootstrap. They are no longer managed by any code in this repository and carry a
  `CanNotDelete` lock. They can be removed manually once nothing depends on them.
- The OpenTofu implementation remains in git history at commits `673e196` and `7f7ccbb`.
