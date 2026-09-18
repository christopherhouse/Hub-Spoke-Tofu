# hub-spoke-iac

Bicep infrastructure as code for an Azure hub-and-spoke network.

Hubs and spokes may live in different regions, subscriptions, and resource groups. Adding
either is a parameter change, not a template change.

## Current state

| Capability | Status |
|---|---|
| Shared Private Link DNS zone catalog | Implemented |
| Hub VNet and Bastion Developer | Planned |
| Spoke VNets and peering | Planned |
| GitHub Actions deploy workflow | Implemented |

## Layout

```
infra/
  main.bicep         subscription-scope composition root
  main.bicepparam    parameter values
  zones.bicep        curated Private Link DNS zone catalog (@export)
  README.md
bicepconfig.json     Bicep linter configuration
.github/
  workflows/deploy.yml
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

## CI/CD

`.github/workflows/deploy.yml` builds and runs `what-if` on pull requests, then deploys on
push to `main` through a protected `production` environment.

Configure these **repository variables** (not secrets — OIDC needs no secret):

| Variable | Purpose |
|---|---|
| `AZURE_CLIENT_ID` | Application ID of the deployment identity |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |

The deployment identity needs a federated credential for this repository, and RBAC
sufficient to create resource groups and networking resources in every target subscription.

## Notes

- `RG-TF-STATE-CUS` and the storage account `satfstatecmhcus` were created by the removed
  OpenTofu bootstrap. They are no longer managed by any code in this repository and carry a
  `CanNotDelete` lock. They can be removed manually once nothing depends on them.
- The OpenTofu implementation remains in git history at commits `673e196` and `7f7ccbb`.
