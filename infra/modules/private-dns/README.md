# private-dns

Creates the centrally owned Private Link DNS zone catalog and links virtual networks to
every zone in it.

The upstream module [`Azure/avm-res-network-privatednszone/azurerm`][avm] creates exactly
one zone per call. This module exists to add behavior on top of that, not to rename its
inputs:

- a curated catalog of verified `privatelink.*` zone names, selected by service family
- expansion of regional zone families into one zone per region
- fan-out of each virtual network link across every zone, with unique link names that stay
  inside the 80 character API limit
- registration forced off, since these are private endpoint zones

[avm]: https://registry.terraform.io/modules/Azure/avm-res-network-privatednszone/azurerm/0.5.0

## Usage

```hcl
module "private_dns" {
  source = "./modules/private-dns"

  parent_id = module.dns_resource_group.resource_id

  enabled_zone_families  = ["storage", "keyvault", "sql", "containerapps"]
  container_apps_regions = ["centralus"]

  virtual_network_links = {
    hub-cus = {
      virtual_network_id = module.hub_vnet.resource_id
    }
  }

  tags             = var.tags
  enable_telemetry = var.enable_telemetry
}
```

## Zone catalog

Every name is verified against the Microsoft Learn
[private endpoint DNS zone values][docs] page for the Azure public cloud. The catalog lives
in `locals.tf`.

[docs]: https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration

### Global families

One zone serves every region.

| Family | Zones |
| --- | --- |
| `acr` | `privatelink.azurecr.io` |
| `ai_foundry` | `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com` |
| `ai_search` | `privatelink.search.windows.net` |
| `appservice` | `privatelink.azurewebsites.net` |
| `cosmos` | `privatelink.documents.azure.com`, `privatelink.mongo.cosmos.azure.com`, `privatelink.cassandra.cosmos.azure.com`, `privatelink.gremlin.cosmos.azure.com`, `privatelink.table.cosmos.azure.com` |
| `keyvault` | `privatelink.vaultcore.azure.net` |
| `mysql` | `privatelink.mysql.database.azure.com` |
| `postgres` | `privatelink.postgres.database.azure.com` |
| `redis_cache` | `privatelink.redis.cache.windows.net` |
| `redis_managed` | `privatelink.redis.azure.net` |
| `servicebus` | `privatelink.servicebus.windows.net` |
| `sql` | `privatelink.database.windows.net` |
| `storage` | `privatelink.{blob,file,queue,table,dfs,web}.core.windows.net` |

### Regional families

The zone name carries the region, so one zone is required per region in use.

| Family | Pattern | Regions from |
| --- | --- | --- |
| `containerapps` | `privatelink.<region>.azurecontainerapps.io` | `container_apps_regions` |

Enabling `containerapps` without any regions is a validation error.

## Things that are easy to get wrong

- **Container Registry data endpoints.** `<region>.data.privatelink.azurecr.io` must *not*
  be created as its own zone. Records are added to `privatelink.azurecr.io` automatically.
- **App Service SCM.** The Kudu endpoint needs a second *record* named `scm.<app>` inside
  `privatelink.azurewebsites.net`, not a second zone.
- **Azure Managed Redis vs Azure Cache for Redis.** Different services, different zones.
  `redis_managed` is `privatelink.redis.azure.net`; `redis_cache` is
  `privatelink.redis.cache.windows.net`.
- **Cosmos DB for PostgreSQL** (`privatelink.postgres.cosmos.azure.com`) is not PostgreSQL
  flexible server and is deliberately not in the `cosmos` family. Use `additional_zones`.
- **Foundry IQ** has no dedicated zone. Foundry resources expose the three `ai_foundry`
  endpoints; deploy the zones matching the endpoint suffixes the workload uses.
- **Autoregistration is not configurable.** Private endpoints own the records in these
  zones. Letting VNet VMs autoregister would create competing A records.

## Adding a zone

Prefer extending the catalog in `locals.tf` so every consumer benefits, and add the family
to the validation list in `variables.tf`. Use `additional_zones` only for one-off cases.
Confirm the name against the Microsoft Learn page above before adding it.
