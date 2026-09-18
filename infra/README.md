# infra

Subscription-scope Bicep root for the hub-and-spoke network.

| File | Purpose |
|---|---|
| `main.bicep` | Composition root. `targetScope = 'subscription'`. |
| `main.bicepparam` | Parameter values for the current deployment. |
| `types.bicep` | Shared user-defined types (`hubType` and friends), surfaced with `@export()`. |
| `zones.bicep` | Curated Private Link DNS zone catalog, surfaced with `@export()`. |
| `modules/hub.bicep` | Hub virtual network, subnets, NSGs and Azure Bastion. Resource-group scope. |

## Modules

| Module | Version |
|---|---|
| `br/public:avm/res/resources/resource-group` | `0.4.4` |
| `br/public:avm/ptn/network/private-link-private-dns-zones` | `0.7.3` |
| `br/public:avm/res/network/virtual-network` | `0.9.0` |
| `br/public:avm/res/network/network-security-group` | `0.5.3` |
| `br/public:avm/res/network/bastion-host` | `0.8.2` |

`avm/ptn/network/hub-networking` is **not** used. Its README flags the module as orphaned —
only security and bug fixes are handled — and its shape assumes a mesh-peered multi-hub
topology with a firewall and route tables that this design keeps optional. The hub is
composed from AVM resource modules instead.

## Parameters

| Name | Required | Notes |
|---|---|---|
| `dnsResourceGroupName` | Yes | Resource group that holds the shared zones. |
| `location` | Yes | Resource group location, and the region substituted into regional zone names. |
| `hubs` | No | `hubType[]`. One entry per hub. Each gets a resource group, VNet, subnets and Bastion, and is linked to every zone. |
| `virtualNetworkLinks` | No | Extra VNets to link, beyond the hubs, which are linked automatically. |
| `additionalPrivateLinkPrivateDnsZonesToInclude` | No | Extra zones beyond the curated catalog. |
| `tags` | No | Applied to the resource group and every zone. Hubs may override with their own `tags`. |
| `enableTelemetry` | No | AVM telemetry, default `true`. |

## Hubs

A hub is data. Adding one — in another region, resource group, or subscription of the same
tenant — is an entry in `hubs`, not a template change. `subscriptionId` is optional and
defaults to the subscription the deployment targets.

Each hub produces:

- a resource group,
- `vnet-<hub name>` with the subnets below,
- an NSG per subnet,
- an Azure Bastion **Standard** host and its Standard SKU public IP,
- a link from the hub VNet to every Private DNS zone, with registration disabled.

### Address plan

Hub 1 is `10.0.0.0/19` (10.0.0.0 – 10.0.31.255).

| Subnet | Prefix | Notes |
|---|---|---|
| `AzureBastionSubnet` | `10.0.0.0/26` | Name fixed by Azure. /26 is the minimum for Bastion resources created after 2 November 2021. |
| `snet-jumpbox` | `10.0.0.64/27` | |
| *(free)* | `10.0.0.96/27` | Left open so the runners subnet lands on a /26 boundary. |
| `snet-runners` | `10.0.0.128/26` | Delegated to `Microsoft.App/environments`. |
| *(reserved)* | `10.0.0.192` – `10.0.31.255` | Firewall, gateway, DNS resolver, shared services. |

Subsequent hubs take the next /19. Hub and spoke ranges must not overlap; that invariant is
documented, not enforced in code.

### Bastion

**Standard**, not Developer. Developer needs no subnet and no public IP and costs nothing,
but it does not support virtual network peering, so it can only reach virtual machines in its
own VNet and is useless for spoke access. Standard is billed hourly per hub, plus its public
IP.

The NSG on `AzureBastionSubnet` carries the full required rule set from *Configure NSG rules
for Azure Bastion*. Applying an NSG there is optional, but once one exists every rule must be
present or Bastion stops receiving platform updates and connectivity breaks.

The jump box NSG allows RDP and SSH inbound from the `AzureBastionSubnet` prefix only. No
management port is exposed to the internet.

### Runners subnet

`snet-runners` is the landing spot for an Azure Container Apps workload profile environment
hosting self-hosted GitHub Actions runners. The environment, its workload profiles, the jobs,
and the GitHub runner registration are **not** deployed by this repository yet.

- Delegation to `Microsoft.App/environments` is mandatory for a workload profile environment,
  and the subnet is dedicated to it.
- A /26 leaves 50 usable addresses after the 14 Container Apps reserves — up to 25 dedicated
  workload profile nodes or 250 consumption replicas. It is oversized on purpose: **an
  environment's subnet cannot be resized once the environment exists**, so growing later means
  rebuilding the environment.
- Its NSG states the Container Apps outbound requirements explicitly, plus HTTPS to the
  internet for GitHub. No deny rule is added: the platform default rules already block inbound
  from the internet.
- `privatelink.centralus.azurecontainerapps.io` is already in the zone catalog and linked to
  the hub, so an internal environment reached through a private endpoint resolves correctly.

## Zone catalog

`zones.bicep` exports `curatedPrivateLinkPrivateDnsZones`, 24 zones verified against the
Microsoft Learn *Azure Private Endpoint private DNS zone values* page. Public cloud only.

Covered: storage (blob, file, queue, table, dfs, web), Key Vault, Azure SQL, PostgreSQL
flexible server, MySQL flexible server, Cosmos DB (SQL, Mongo, Cassandra, Gremlin, Table),
Azure Managed Redis, App Service, AI Foundry / Azure OpenAI / Cognitive Services, AI Search,
Container Registry, Service Bus, and Container Apps.

The AVM pattern module ships a ~110-zone default catalog. We pass our curated list
explicitly so the zones deployed are a reviewed decision rather than a module default.

### Caveats baked into the catalog

- **Container Apps is regional.** `privatelink.{regionName}.azurecontainerapps.io`. The
  pattern module substitutes `{regionName}` and `{regionCode}` from its own `location`
  parameter, so a single invocation resolves one region. Additional regions must be passed
  as literal zone names through `additionalPrivateLinkPrivateDnsZonesToInclude`, or handled
  by a second module invocation.
- **Azure Managed Redis** (`privatelink.redis.azure.net`) is not Azure Cache for Redis
  (`privatelink.redis.cache.windows.net`). Only the former is in the catalog.
- **Container Registry data endpoints** and **App Service SCM** do not get their own zones.
  They are records inside the parent zone when Azure Private DNS is used.
- **`servicebus`** covers Service Bus, Event Hubs, and Relay.
- **"Foundry IQ"** has no dedicated zone. Foundry resources are served by the three AI
  endpoint zones already present.
- **Cosmos DB for PostgreSQL** (`privatelink.postgres.cosmos.azure.com`) is deliberately
  excluded. It is a different service from PostgreSQL flexible server.
- Autoregistration is never enabled on these zones. Private endpoints own the records.

## Known gaps

The pattern module outputs `combinedPrivateLinkPrivateDnsZonesReplacedWithVnetsToLink`
plus the resource group ID and name. It does **not** emit per-zone resource IDs, which
spokes will need for private endpoint DNS zone groups. Zone resource IDs are deterministic,
so they can be constructed from the subscription, resource group, and zone name when the
spoke work lands.

Hub virtual network links are composed the same way, from the hub definition rather than the
hub module outputs: a variable loop cannot read module outputs (BCP182) and a for-expression
cannot be nested inside `concat` (BCP138). The naming convention lives in one place,
`hubVirtualNetworkName` in `types.bicep`, and the zone module takes an explicit `dependsOn`
on the hubs because the dependency is no longer implied by a reference.

## Validation

```powershell
az bicep build --file infra/main.bicep
az bicep build-params --file infra/main.bicepparam
```
