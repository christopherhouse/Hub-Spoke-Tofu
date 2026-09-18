// Curated Private Link DNS zone catalog.
//
// Every name is verified against the Microsoft Learn "Azure Private Endpoint private DNS
// zone values" page for the Azure public cloud:
// https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration
//
// This list is passed to avm/ptn/network/private-link-private-dns-zones, which substitutes
// the {regionName} token with the deployment location and creates one zone per entry.
//
// Treat this as reviewed configuration. Confirm any new name against the page above before
// adding it.

@export()
@description('Curated Private Link private DNS zones for the services this platform supports.')
var curatedPrivateLinkPrivateDnsZones = [
  // Container Apps. Regional: the zone name carries the region, so one zone is required per
  // region hosting a Container Apps environment. {regionName} is replaced by the module
  // using its location parameter, which covers a single region per invocation.
  'privatelink.{regionName}.azurecontainerapps.io'

  // Storage. One zone per subresource actually in use.
  'privatelink.blob.core.windows.net'
  'privatelink.file.core.windows.net'
  'privatelink.queue.core.windows.net'
  'privatelink.table.core.windows.net'
  'privatelink.dfs.core.windows.net'
  'privatelink.web.core.windows.net'

  // Key Vault.
  'privatelink.vaultcore.azure.net'

  // Azure SQL Database.
  'privatelink.database.windows.net'

  // Azure Database for PostgreSQL flexible server. Cosmos DB for PostgreSQL is a different
  // service on privatelink.postgres.cosmos.azure.com and is deliberately not included.
  'privatelink.postgres.database.azure.com'

  // Azure Database for MySQL flexible server.
  'privatelink.mysql.database.azure.com'

  // Cosmos DB, one zone per API.
  'privatelink.documents.azure.com'
  'privatelink.mongo.cosmos.azure.com'
  'privatelink.cassandra.cosmos.azure.com'
  'privatelink.gremlin.cosmos.azure.com'
  'privatelink.table.cosmos.azure.com'

  // Azure Managed Redis. Azure Cache for Redis is a different service and zone
  // (privatelink.redis.cache.windows.net); add it only if that service is adopted.
  'privatelink.redis.azure.net'

  // App Service and Functions. The Kudu/SCM endpoint does NOT get its own zone: it is a
  // record named scm.<app> inside this zone.
  'privatelink.azurewebsites.net'

  // Azure AI Foundry, Azure OpenAI and Cognitive Services. A Foundry resource can expose all
  // three endpoint suffixes, so deploy each zone whose endpoint the workload uses. Foundry IQ
  // has no dedicated zone and is covered by these.
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'

  // Azure AI Search.
  'privatelink.search.windows.net'

  // Azure Container Registry. Data endpoints ({regionName}.data.privatelink.azurecr.io) must
  // NOT be created as separate zones; their records are added to this zone automatically.
  'privatelink.azurecr.io'

  // Service Bus. Also covers Event Hubs and Relay.
  'privatelink.servicebus.windows.net'
]
