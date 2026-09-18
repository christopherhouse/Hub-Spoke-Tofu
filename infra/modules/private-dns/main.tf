terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.1, < 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

# The upstream AVM creates a single zone per call, so the catalog is expanded here.
module "zone" {
  source  = "Azure/avm-res-network-privatednszone/azurerm"
  version = "0.5.0"

  for_each = local.zones

  domain_name           = each.value
  parent_id             = var.parent_id
  virtual_network_links = local.links_by_zone[each.value]
  tags                  = var.tags
  enable_telemetry      = var.enable_telemetry
}
