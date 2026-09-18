# Copilot instructions

## Repository purpose

This repository manages an Azure hub-and-spoke network with OpenTofu. Hubs and spokes may span Azure regions, subscriptions, and resource groups. Topology and environment differences must be data-driven rather than implemented through copied root modules.

The only currently deployable HCL is the isolated `bootstrap/` root used to create remote state storage. Hub-and-spoke resources must not be added to that root.

## Required engineering practices

- Generate OpenTofu-compatible HCL and validate with the `tofu` CLI.
- Pin provider versions and commit `.terraform.lock.hcl`.
- Put reusable components under `infra/modules/`.
- Put composition roots and environment values under `infra/environments/`.
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

## Multi-subscription constraint

AzureRM provider configurations and aliases are statically declared. Do not promise an unlimited number of arbitrary subscription contexts solely through `tfvars`.

Before implementing the root design, choose and document one of these patterns:

1. One independently planned state stack per subscription, with explicit cross-stack inputs for shared hub and DNS resources.
2. A bounded set of statically declared AzureRM provider aliases passed into modules.

Prefer per-subscription stacks when the subscription count is open-ended or managed by separate teams.

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
