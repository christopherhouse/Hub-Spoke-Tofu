# Copilot instructions

## Repository purpose

This repository manages an Azure hub-and-spoke network with Bicep. Hubs and spokes may span Azure regions, subscriptions, and resource groups. Topology and environment differences must be data-driven rather than implemented through copied templates.

`infra/` holds the single deployable root, `infra/main.bicep`, deployed at subscription scope. It currently deploys the shared Private Link DNS zone catalog; hubs and spokes are added here.

This repository previously used OpenTofu. That implementation was removed because remote state storage could not be reached: `MCAPSGovDeployPolicies`, a `modify` policy assignment at management group scope, forces `publicNetworkAccess: Disabled` on storage accounts. Bicep is stateless, so the problem does not arise. Do not reintroduce Terraform or OpenTofu.

## Required engineering practices

- Generate Bicep and validate with `az bicep build` and `az bicep build-params`.
- Keep `infra/main.bicep` as the single composition root for the network. There is no per-environment root split; environment differences are expressed in parameter values.
- `infra/bootstrap/main.bicep` is the one permitted second root. It creates the deployment identity that GitHub Actions authenticates as, so it must be deployed by a human, once, and never by CI — the identity cannot create itself. Workflows may build it, but must not deploy it. Do not add anything else to it.
- Put shared, reviewed data such as the DNS zone catalog in its own `.bicep` file and surface it with `@export()`.
- Give every parameter and output a `@description`, and mark it `Required.` or `Optional.` in line with AVM conventions.
- Use `@minLength`, `@maxLength`, `@allowed` and typed parameters instead of free-form strings where a constraint exists.
- Prefer user-defined types over untyped `object` and `array` when the shape is known.
- Use `.bicepparam` files with the `using` directive. Do not hand-write ARM parameter JSON.
- Never commit compiled ARM JSON. The `.bicep` sources are the source of truth.
- Do not put deployable resources in example or documentation files.
- Do not silently create or select subscriptions, resource groups, or address ranges.

## Azure Verified Modules

- Use Azure Verified Modules (AVM) for Azure resources and established Azure patterns whenever a published module satisfies the requirement.
- Reference modules from the public registry with an exact version: `br/public:avm/res/<service>/<resource>:<x.y.z>`. Do not use a floating or missing version tag.
- Prefer AVM **pattern** modules (`avm/ptn/...`) when one matches the desired architecture; otherwise compose AVM **resource** modules (`avm/res/...`).
- Check available versions before pinning, for example via `https://mcr.microsoft.com/v2/bicep/avm/res/<path>/tags/list`.
- Read the selected version's parameters, outputs, and examples before using it.
- Expose `enableTelemetry` at the composition root and pass it to AVMs that support it.
- Do not wrap an AVM solely to rename its parameters. Add a local module only when it provides meaningful reusable behaviour.
- Raw `resource` declarations are exceptions. Use them only when no suitable published AVM exists or the AVM cannot meet a required behaviour.
- Document every raw-resource exception beside the code with the AVM catalog search date, the evaluated module, and the concrete capability gap.
- Re-evaluate documented exceptions during AVM upgrades and replace them when an appropriate module becomes available.

## Azure authentication and deployment

- Use Microsoft Entra authentication for all Azure access.
- Use GitHub Actions workload identity federation with OIDC.
- The deployment identity is the user-assigned managed identity `id-hub-spoke-iac-cicd` in `RG-CICD-CUS`, created by `infra/bootstrap/main.bicep`. A managed identity is used rather than an Entra app registration because it needs no application object, which tenants often restrict.
- Federated credentials trust one subject per workflow trigger: `pull_request`, `ref:refs/heads/main`, and `environment:azure`. A job that declares `environment:` presents the environment subject, not the branch subject. Adding a trigger means adding a credential in the bootstrap template.
- Do not use client secrets, certificates stored in GitHub, storage account keys, or SAS tokens. GitHub holds only repository variables — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` — and no secrets.
- Deploy with `az deployment sub create` at subscription scope.
- Grant the deployment identity only the RBAC roles it needs, assigned at a management group covering the target subscriptions where practical. It currently holds `Contributor` at the target subscription. It is deliberately not `User Access Administrator`; if a template starts creating role assignments, that has to be revisited rather than worked around.

## Multi-subscription model

Bicep targets a scope per module, so subscriptions are data rather than configuration.

- Deploy resource groups from the subscription-scope root, and target other subscriptions with `scope: resourceGroup(<subscriptionId>, <name>)`.
- Onboarding a subscription must be a parameter change, never a structural template change.
- All subscriptions are expected to be in a single Entra tenant. Cross-tenant deployment is out of scope and would need separate credentials or Azure Lighthouse.
- Cross-subscription peering requires the deployment identity to have permissions on both virtual networks.

## Network design invariants

- Hub and spoke CIDR ranges must not overlap.
- Each spoke must reference exactly one defined hub unless a future architecture decision explicitly supports another topology.
- Traditional bidirectional VNet peering is the current design assumption.
- Azure Bastion Standard is created for each hub. The Developer SKU was evaluated and rejected: it does not support virtual network peering, so it can only reach virtual machines in its own VNet and cannot serve spokes.
- A Bastion of any SKU other than Developer requires a dedicated subnet named exactly `AzureBastionSubnet`, sized /26 or larger, plus a Standard SKU public IP. The AVM bastion module creates the public IP from `publicIPAddressObject`.
- Applying an NSG to `AzureBastionSubnet` is optional, but if one is present it must carry every rule from the Azure Bastion NSG guidance. A missing rule breaks connectivity and blocks platform updates.
- Jump box and other target subnets allow RDP and SSH only from the `AzureBastionSubnet` prefix, never from the internet.
- An NSG security rule `description` must be 140 characters or fewer. Azure rejects longer ones at preflight with `SecurityRuleDescriptionTooLong`, which `az bicep build` does not catch.
- Subnets delegated to `Microsoft.App/environments` for Azure Container Apps must be /27 or larger and are dedicated to that environment. The prefix cannot be changed once an environment exists in it, so size for growth.
- Keep future firewall, gateway, route-table, and DNS resolver features optional and composable.

## Private DNS

- Use one centrally owned Private DNS zone catalog unless an approved architecture decision changes the ownership model.
- The curated catalog lives in `infra/zones.bicep`. Add zones there rather than inline in the root.
- Link required zones to each participating VNet with registration disabled. Private endpoints own the records in these zones; autoregistration would create competing A records.
- Private endpoints should use private DNS zone groups whenever the service supports them.
- Do not assume every service uses a single zone; storage subresources and some service deployment modes require distinct zones.
- Treat the zone catalog as reviewed configuration. Verify current Azure Private Link zone names and subresource group IDs against Microsoft documentation before adding them.
- Not every zone is global. Container Apps uses `privatelink.{regionName}.azurecontainerapps.io`. The AVM pattern module substitutes `{regionName}` and `{regionCode}` from its `location` parameter, so it resolves one region per invocation. Zones for additional regions must be passed explicitly.
- Do not create separate zones for Azure Container Registry data endpoints or App Service SCM. Both are records inside the parent zone when Azure Private DNS is used.
- Azure Managed Redis (`privatelink.redis.azure.net`) is a different service and zone from Azure Cache for Redis (`privatelink.redis.cache.windows.net`).

## Source control

- All work happens on feature branches. Do not commit directly to `main`.
- Branch from the latest `main` and use a short descriptive name, for example `feat/hub-vnet`, `fix/dns-zone-links`, or `chore/bump-avm-versions`.
- Land changes through a pull request. `main` is the deployment branch, so anything merged there is expected to deploy.
- Keep a branch scoped to one logical change so its `what-if` output is reviewable.
- Never rewrite published history on `main`.

## GitHub Actions

- Pull requests run `az bicep build`, parameter build, and `az deployment sub what-if`. The bootstrap root is built but never deployed by a workflow.
- There is a single GitHub Environment, `azure`. There is no dev/test/prod split and no required reviewers, so a merge to `main` deploys. Renaming it means updating both the workflow and the federated credential in the bootstrap template.
- Use `permissions: id-token: write` and the minimum required repository permissions.
- Federated credential subjects must match GitHub's **immutable subject claim** form, `repo:<owner>@<ownerId>/<repo>@<repoId>:<trigger>`. Verify against `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` before changing them; the name-only form fails with `AADSTS700213`.
- Pin third-party actions to immutable commit SHAs with the version in a trailing comment.
- Use concurrency controls to prevent simultaneous deployments to the same scope.

## Security and quality

- Never commit secrets, credentials, or compiled deployment artifacts.
- Do not expose management ports or add broad `0.0.0.0/0` rules by default.
- Use least-privilege RBAC and scope assignments as narrowly as practical.
- Make destructive behaviour explicit and protect critical shared resources from accidental deletion.
- Plain deployments do not remove resources deleted from a template. If that becomes a problem, evaluate Azure Deployment Stacks rather than adding manual cleanup steps.
- Update `README.md` and architecture documentation with meaningful behaviour changes.
