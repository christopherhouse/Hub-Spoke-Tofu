# infra

Subscription-scope Bicep root for the hub-and-spoke network.

| File | Purpose |
|---|---|
| `main.bicep` | Composition root. `targetScope = 'subscription'`. |
| `main.bicepparam` | Parameter values for the current deployment. |
| `zones.bicep` | Curated Private Link DNS zone catalog, surfaced with `@export()`. |

## Modules

| Module | Version |
|---|---|
| `br/public:avm/res/resources/resource-group` | `0.4.4` |
| `br/public:avm/ptn/network/private-link-private-dns-zones` | `0.7.3` |

## Parameters

| Name | Required | Notes |
|---|---|---|
| `dnsResourceGroupName` | Yes | Resource group that holds the shared zones. |
| `location` | Yes | Resource group location, and the region substituted into regional zone names. |
| `virtualNetworkLinks` | No | Objects with `virtualNetworkResourceId`. Linked to every zone. Empty until hub and spoke VNets exist. |
| `additionalPrivateLinkPrivateDnsZonesToInclude` | No | Extra zones beyond the curated catalog. |
| `tags` | No | Applied to the resource group and every zone. |
| `enableTelemetry` | No | AVM telemetry, default `true`. |

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

## Validation

```powershell
az bicep build --file infra/main.bicep
az bicep build-params --file infra/main.bicepparam
```
