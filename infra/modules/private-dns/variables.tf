variable "parent_id" {
  type        = string
  description = "Resource ID of the resource group that will contain the Private DNS zones."

  validation {
    condition     = can(regex("^/subscriptions/[a-fA-F0-9-]+/resourceGroups/[a-zA-Z0-9_.()-]+$", var.parent_id))
    error_message = "parent_id must be a resource group resource ID, for example /subscriptions/<guid>/resourceGroups/<name>."
  }
}

variable "additional_zones" {
  type        = list(string)
  default     = []
  description = <<-DESCRIPTION
    Extra Private DNS zone names to create that are not in the built-in catalog.
    Use this for services the catalog does not cover yet, or for regional zones of
    services other than Container Apps. Names must be fully qualified, for example
    "privatelink.azure-devices.net".
  DESCRIPTION

  validation {
    condition     = alltrue([for zone in var.additional_zones : can(regex("^[a-z0-9.-]+$", zone))])
    error_message = "Each additional zone must be a lowercase DNS name containing only letters, digits, dots and hyphens."
  }
}

variable "container_apps_regions" {
  type        = list(string)
  default     = []
  description = <<-DESCRIPTION
    Regions to create Container Apps Private DNS zones for. Container Apps zones are
    regional (privatelink.<region>.azurecontainerapps.io), unlike most Private Link
    zones, so one zone is required per region hosting a Container Apps environment.
    Only used when the "containerapps" family is enabled.
  DESCRIPTION

  validation {
    condition     = alltrue([for region in var.container_apps_regions : can(regex("^[a-z0-9]+$", region))])
    error_message = "Each region must be an Azure region short name such as centralus or westeurope."
  }
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Whether to enable Azure Verified Module telemetry."
}

variable "enabled_zone_families" {
  type        = list(string)
  default     = []
  description = <<-DESCRIPTION
    Service families to create Private DNS zones for. Each family expands to one or
    more zones from the catalog in locals.tf. Valid values:

    acr, ai_foundry, ai_search, appservice, containerapps, cosmos, keyvault, mysql,
    postgres, redis_cache, redis_managed, servicebus, sql, storage
  DESCRIPTION

  # Kept in sync with the catalog keys in locals.tf. Validation blocks cannot read
  # locals, so the list is repeated here.
  validation {
    condition = alltrue([
      for family in var.enabled_zone_families : contains([
        "acr", "ai_foundry", "ai_search", "appservice", "containerapps", "cosmos",
        "keyvault", "mysql", "postgres", "redis_cache", "redis_managed",
        "servicebus", "sql", "storage",
      ], family)
    ])
    error_message = "Unknown zone family. Valid values are acr, ai_foundry, ai_search, appservice, containerapps, cosmos, keyvault, mysql, postgres, redis_cache, redis_managed, servicebus, sql, storage."
  }

  validation {
    condition     = !contains(var.enabled_zone_families, "containerapps") || length(var.container_apps_regions) > 0
    error_message = "The containerapps family produces regional zones, so container_apps_regions must list at least one region."
  }
}

variable "tags" {
  type        = map(string)
  default     = null
  description = "Tags applied to every Private DNS zone and virtual network link."
}

variable "virtual_network_links" {
  type = map(object({
    virtual_network_id = string
  }))
  default     = {}
  description = <<-DESCRIPTION
    Virtual networks to link to every zone in the catalog, keyed by a short name used
    to build the link name. Registration is always disabled: these are private
    endpoint zones, so records are owned by the private endpoints themselves.
  DESCRIPTION

  validation {
    condition     = alltrue([for key in keys(var.virtual_network_links) : can(regex("^[a-zA-Z0-9-]{1,20}$", key))])
    error_message = "Each virtual network link key must be 1-20 characters of letters, digits or hyphens, because it is used as the link name prefix."
  }

  validation {
    condition = alltrue([
      for link in var.virtual_network_links :
      can(regex("^/subscriptions/[a-fA-F0-9-]+/resourceGroups/[a-zA-Z0-9_.()-]+/providers/Microsoft.Network/virtualNetworks/[a-zA-Z0-9_.-]+$", link.virtual_network_id))
    ])
    error_message = "Each virtual_network_id must be a full virtual network resource ID."
  }
}
