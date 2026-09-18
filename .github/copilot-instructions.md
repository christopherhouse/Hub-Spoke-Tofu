# Copilot instructions

## Repository purpose

This repository manages an Azure hub-and-spoke network with OpenTofu. Hubs and spokes may span Azure regions, subscriptions, and resource groups. Topology and environment differences must be data-driven rather than implemented through copied root modules.

There are two deployable roots:

- `bootstrap/` creates the remote state storage account. It is isolated and stays on local state. Hub-and-spoke resources must not be added to it.
- `infra/` is the single workload root, using the remote backend with state key `hub-spoke/infra.tfstate`. It currently deploys the shared Private DNS zone catalog; hubs and spokes are added here.

## Required engineering practices

- Generate OpenTofu-compatible HCL and validate with the `tofu` CLI.
- Pin provider versions and commit `.terraform.lock.hcl`.
- Put reusable components under `infra/modules/`.
- Keep a single composition root at `infra/`. There is no per-environment root split; environment differences are expressed in variable values.
- Give every variable and output a useful description and precise type.
- Add validation for CIDRs, required names, assignment references, and incompatible options.
- Prefer maps keyed by stable logical names over position-dependent lists.
- Keep resource names separate from logical map keys.
- Use `for_each` for stable resource addressing.
- Avoid unnecessary `depends_on`; rely on resource references for dependency ordering.
- Do not put deployable resources in example or documentation files.
- Do not silently create or select subscriptions, resource groups, or address ranges.

## Azure Verified Modules

- Use Azure Verified Modules (AVM) for Azure resources and established Azure patterns whenever a published module satisfies the requirement.
- Search the official AVM Terraform resource and pattern module indexes before writing resource code.
- Use official registry sources under the `Azure` namespace, such as `Azure/avm-res-network-virtualnetwork/azurerm`.
- Pin every AVM call to an exact released version. Do not use an unversioned module, a branch, or `latest`.
- Read the selected version's inputs, outputs, examples, dependencies, limitations, and upgrade notes before using it.
- Verify OpenTofu compatibility and run initialization and validation after adding or upgrading an AVM.
- Expose `enable_telemetry` at the composition root and pass it consistently to AVMs that support it.
- Prefer AVM pattern modules when they match the desired architecture; otherwise compose AVM resource modules.
- Do not wrap an AVM solely to rename its inputs or outputs. Add a local composition module only when it provides meaningful reusable behavior.
- Direct `azurerm_*` or `azapi_*` resources are exceptions. Use them only when no suitable published AVM exists or the available AVM cannot meet a required behavior.
- Document every direct-resource exception beside the code with the AVM catalog search date, the evaluated module, and the concrete capability gap.
- Re-evaluate documented exceptions during provider or AVM upgrades and replace them when an appropriate AVM becomes available.

## Azure authentication and state

- Use Microsoft Entra authentication for Azure management and data-plane access.
- Use GitHub Actions workload identity federation with OIDC.
- Do not use client secrets, certificates stored in GitHub, storage account keys, SAS tokens, or Azure CLI key retrieval.
- The Azure Storage backend must use Entra authentication, including `use_azuread_auth = true`; CI must use OIDC rather than an access key.
- The state storage account must disable shared-key authorization.
- Grant the deployment identity only the management-plane and data-plane RBAC roles it needs.
- Treat state infrastructure and workload infrastructure as separate trust and lifecycle boundaries.
- Keep `bootstrap/` on local state; it creates the backend and therefore cannot use that backend during its first deployment.

## Network design invariants

- Hub and spoke CIDR ranges must not overlap.
- Each spoke must reference exactly one defined hub unless a future architecture decision explicitly supports another topology.
- Traditional bidirectional VNet peering is the current design assumption.
- Cross-subscription peerings require the deployment identity to have permissions on both VNets.
- Azure Bastion Developer must be created for each hub. Do not create an `AzureBastionSubnet` or public IP for Developer SKU unless Azure requirements change.
- Bastion Developer connects only to virtual machines in its own VNet; do not claim it provides spoke access through peering.
- Keep future firewall, gateway, route-table, and DNS resolver features optional and composable.

## Private DNS

- Use one centrally owned Private DNS zone catalog unless an approved architecture decision changes the ownership model.
- Link required zones to each participating VNet with registration disabled.
- Private endpoints should use private DNS zone groups whenever the service supports them.
- Do not assume every service uses a single zone; storage subresources and some service deployment modes require distinct zones.
- Treat the zone catalog as reviewed configuration. Verify current Azure Private Link zone names and subresource group IDs against Microsoft documentation before adding them.
- Include common storage, Key Vault, relational database, Cosmos DB, cache, App Service, Container Apps, container registry, and Azure AI service families only after validating exact service requirements.
- The verified catalog lives in `infra/modules/private-dns/locals.tf`, keyed by service family. Add zones there rather than inline in a root.
- Not every zone is global. Container Apps uses `privatelink.<region>.azurecontainerapps.io`, so regional families must expand per region.
- Do not create separate zones for Azure Container Registry data endpoints (`<region>.data.privatelink.azurecr.io`) or App Service SCM. Both are records inside the parent zone when Azure Private DNS is used.
- Azure Managed Redis (`privatelink.redis.azure.net`) is a different service and zone from Azure Cache for Redis (`privatelink.redis.cache.windows.net`).

## Multi-subscription constraint

This repository uses the AzAPI provider, not AzureRM. The two behave differently and the AzureRM guidance about statically declared aliases does not apply here.

- In AzAPI 2.x the target subscription is determined by the resource ID, built from `parent_id`. The provider's `subscription_id` is not substituted into the request URL.
- A single `azapi` provider configuration can therefore manage resources in any subscription in the same tenant that the deployment identity can reach. Express hub and spoke subscriptions as data in `tfvars` by passing fully-qualified `parent_id` values.
- Pin `azapi` to at least `2.9.0`. Version 2.7.0 fixed `azapi_client_config` returning the Azure CLI default subscription, and 2.9.0 fixed `auxiliary_tenant_ids` not reaching the ARM client.
- Always set `subscription_id` explicitly. When unset the provider shells out to `az account show`, which is nondeterministic in CI.

Known exceptions that are genuinely bound to the provider's subscription:

- `Azure/avm-res-resources-resourcegroup/azurerm` sets `parent_id` from `data.azapi_client_config.current.subscription_id`, so it can only create resource groups in the provider's own subscription. Creating resource groups in other subscriptions requires a provider alias per subscription, or taking pre-provisioned resource group IDs as input.
- AzAPI registers resource providers in the target subscription, so the identity needs `Microsoft.Resources/subscriptions/providers/register/action` there, or provider registration must be skipped.
- Cross-tenant management is not covered by a single provider configuration. It requires `auxiliary_tenant_ids` for linked authorization, and separate credentials or Azure Lighthouse delegation to actually manage resources.

Prefer per-subscription state stacks only when subscriptions are managed by separate teams with separate approval boundaries, not merely because they are numerous.

## Multi-subscription decision

Decided 2026-09-18. All hub and spoke subscriptions are in a single Entra tenant, there are a small number of them, and they share one state.

- Use a single `azapi` provider configuration and a single state for the whole topology.
- Express every subscription as data in `tfvars`. Never add a provider alias to onboard a subscription.
- Create resource groups through `infra/modules/resource-group`, which sets `parent_id` explicitly. Do not use the resource group AVM, for the reason documented in that module.
- Pass `module.<rg>.resource_id` as `parent_id` to AVMs so the subscription flows through the resource ID.
- Grant the deployment identity at a management group covering the subscriptions, including provider registration rights.
- Revisit this decision if subscriptions ever span tenants, or if separate teams need independent approval boundaries.

## GitHub Actions

- Pull requests should run formatting, initialization without backend access where possible, validation, security checks, and a plan when authorized.
- Merges to `main` may apply only through a protected GitHub Environment with required reviewers.
- Use `permissions: id-token: write` and the minimum required repository permissions.
- Pin third-party actions to immutable commit SHAs.
- Use concurrency controls to prevent simultaneous applies to the same state.
- Persist plans only when the apply job can verify that the plan belongs to the exact commit being deployed.

## Security and quality

- Never commit secrets, credentials, state files, saved plans, or local variable files.
- Do not expose management ports or add broad `0.0.0.0/0` rules by default.
- Use least-privilege RBAC and scope assignments as narrowly as practical.
- Make destructive behavior explicit and protect critical shared resources from accidental deletion.
- Add tests for variable validation, resource addressing stability, and representative topology expansion.
- Update `README.md` and architecture documentation with meaningful behavior changes.
