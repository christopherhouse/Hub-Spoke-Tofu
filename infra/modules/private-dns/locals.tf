locals {
  # Private Link DNS zone names for the Azure public cloud, verified against
  # https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration
  #
  # Zones listed here are global: one zone serves every region.
  global_zone_catalog = {
    acr = [
      # Data endpoints ({region}.data.privatelink.azurecr.io) must NOT be created
      # as separate zones. Their records are added to this zone automatically.
      "privatelink.azurecr.io",
    ]

    ai_foundry = [
      # A Foundry resource can expose all three endpoints; deploy every zone whose
      # endpoint suffix the workload actually uses. "Foundry IQ" has no dedicated
      # zone and is covered by these.
      "privatelink.cognitiveservices.azure.com",
      "privatelink.openai.azure.com",
      "privatelink.services.ai.azure.com",
    ]

    ai_search = [
      "privatelink.search.windows.net",
    ]

    appservice = [
      # The Kudu/SCM endpoint is an additional record (scm.<app>) inside this zone,
      # not a separate zone.
      "privatelink.azurewebsites.net",
    ]

    cosmos = [
      "privatelink.documents.azure.com",
      "privatelink.mongo.cosmos.azure.com",
      "privatelink.cassandra.cosmos.azure.com",
      "privatelink.gremlin.cosmos.azure.com",
      "privatelink.table.cosmos.azure.com",
    ]

    keyvault = [
      "privatelink.vaultcore.azure.net",
    ]

    mysql = [
      "privatelink.mysql.database.azure.com",
    ]

    postgres = [
      # Azure Database for PostgreSQL flexible server. Cosmos DB for PostgreSQL is
      # a different service on privatelink.postgres.cosmos.azure.com.
      "privatelink.postgres.database.azure.com",
    ]

    redis_cache = [
      # Azure Cache for Redis, the classic service.
      "privatelink.redis.cache.windows.net",
    ]

    redis_managed = [
      # Azure Managed Redis.
      "privatelink.redis.azure.net",
    ]

    servicebus = [
      # Also covers Event Hubs and Relay.
      "privatelink.servicebus.windows.net",
    ]

    sql = [
      "privatelink.database.windows.net",
    ]

    storage = [
      "privatelink.blob.core.windows.net",
      "privatelink.file.core.windows.net",
      "privatelink.queue.core.windows.net",
      "privatelink.table.core.windows.net",
      "privatelink.dfs.core.windows.net",
      "privatelink.web.core.windows.net",
    ]
  }

  # Zones whose name carries the region, so one zone is required per region in use.
  # The format string takes the region short name.
  regional_zone_catalog = {
    containerapps = "privatelink.%s.azurecontainerapps.io"
  }

  # Regions to expand each regional family into.
  regional_zone_regions = {
    containerapps = var.container_apps_regions
  }

  selected_global_zones = flatten([
    for family in var.enabled_zone_families :
    lookup(local.global_zone_catalog, family, [])
  ])

  selected_regional_zones = flatten([
    for family in var.enabled_zone_families : [
      for region in lookup(local.regional_zone_regions, family, []) :
      format(local.regional_zone_catalog[family], region)
    ]
    if contains(keys(local.regional_zone_catalog), family)
  ])

  zones = toset(concat(
    local.selected_global_zones,
    local.selected_regional_zones,
    var.additional_zones,
  ))

  # Virtual network links are fanned out across every zone, so each link name must
  # be unique per zone and VNet while staying under the 80 character API limit. The
  # readable prefix is truncated and a short digest guarantees uniqueness.
  zone_links = {
    for pair in setproduct(local.zones, keys(var.virtual_network_links)) :
    "${pair[0]}|${pair[1]}" => {
      zone     = pair[0]
      link_key = pair[1]
      vnet_id  = var.virtual_network_links[pair[1]].virtual_network_id
      link_name = format(
        "%s-%s-%s",
        substr(pair[1], 0, 20),
        substr(replace(replace(pair[0], "privatelink.", ""), ".", "-"), 0, 40),
        substr(sha1("${pair[0]}|${pair[1]}"), 0, 8),
      )
    }
  }

  links_by_zone = {
    for zone in local.zones : zone => {
      for key, link in local.zone_links :
      link.link_key => {
        name               = link.link_name
        virtual_network_id = link.vnet_id

        # Private endpoint zones resolve records created by the private endpoint
        # itself. Autoregistration would let VNet VMs write competing A records,
        # so it is forced off and deliberately not configurable.
        autoregistration     = false
        registration_enabled = false

        tags = var.tags
      }
      if link.zone == zone
    }
  }
}
