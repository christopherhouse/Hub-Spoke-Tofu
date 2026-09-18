# AVM exception
#
# Evaluated:   Azure/avm-res-resources-resourcegroup/azurerm 0.4.0
# Search date: 2026-09-18
# Gap:         The module builds its target from the provider's identity:
#                parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
#              data.azapi_client_config is provider-scoped, so the module can only create
#              resource groups in the subscription the azapi provider is configured with.
#              Hubs and spokes in this repository span subscriptions, and the alternative
#              is a statically declared provider alias per subscription, which prevents
#              adding a subscription through tfvars alone.
# Resolution:  Use azapi_resource directly so parent_id carries the target subscription.
#              Re-evaluate when the AVM accepts a subscription or parent_id input.
#
# Everything downstream of a resource group takes a fully-qualified parent_id and is
# therefore subscription-agnostic, so this is the only exception required.

resource "azapi_resource" "this" {
  type      = "Microsoft.Resources/resourceGroups@2025-04-01"
  name      = var.name
  location  = var.location
  parent_id = "/subscriptions/${var.subscription_id}"
  tags      = var.tags

  body = {
    properties = {}
  }

  response_export_values = [
    "id",
    "name",
    "location",
  ]
}
