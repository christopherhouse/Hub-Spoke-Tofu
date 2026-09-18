variable "subscription_id" {
  type        = string
  description = <<-DESCRIPTION
    ID of the subscription the azapi provider is configured with. Resources are targeted by
    parent_id, so this is the default home subscription rather than a hard boundary; other
    subscriptions in the same tenant can be targeted without provider aliases.
  DESCRIPTION

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "dns_subscription_id" {
  type        = string
  default     = null
  description = <<-DESCRIPTION
    Subscription that owns the shared Private DNS zones. Defaults to subscription_id. Set
    this when the connectivity subscription differs from the provider's home subscription.
    Must be in the same Entra tenant.
  DESCRIPTION

  validation {
    condition     = var.dns_subscription_id == null || can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.dns_subscription_id))
    error_message = "dns_subscription_id must be a GUID."
  }
}

variable "dns_resource_group_name" {
  type        = string
  description = "Name of the resource group created to hold the shared Private DNS zones."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.()-]{1,90}$", var.dns_resource_group_name))
    error_message = "dns_resource_group_name must be 1-90 characters of letters, digits, underscores, periods, parentheses or hyphens."
  }

  validation {
    condition     = !endswith(var.dns_resource_group_name, ".")
    error_message = "dns_resource_group_name cannot end with a period."
  }
}

variable "dns_resource_group_location" {
  type        = string
  description = <<-DESCRIPTION
    Azure region for the Private DNS zone resource group. Private DNS zones are global
    resources, so this only sets where the resource group metadata lives; keep it close
    to the connectivity footprint.
  DESCRIPTION

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.dns_resource_group_location))
    error_message = "dns_resource_group_location must be an Azure region short name such as centralus."
  }
}

variable "additional_private_dns_zones" {
  type        = list(string)
  default     = []
  description = "Extra Private DNS zone names to create beyond the built-in catalog."
}

variable "container_apps_regions" {
  type        = list(string)
  default     = []
  description = <<-DESCRIPTION
    Regions to create Container Apps Private DNS zones for. Container Apps zones are
    regional, so one zone is needed per region hosting a Container Apps environment.
    Required when the "containerapps" family is enabled.
  DESCRIPTION
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = "Whether to enable Azure Verified Module telemetry."
}

variable "enabled_zone_families" {
  type        = list(string)
  description = <<-DESCRIPTION
    Service families to create Private DNS zones for. See infra/modules/private-dns
    for the zone each family expands to. Valid values:

    acr, ai_foundry, ai_search, appservice, containerapps, cosmos, keyvault, mysql,
    postgres, redis_cache, redis_managed, servicebus, sql, storage
  DESCRIPTION
}

variable "private_dns_virtual_network_links" {
  type = map(object({
    virtual_network_id = string
  }))
  default     = {}
  description = <<-DESCRIPTION
    Virtual networks to link to every Private DNS zone, keyed by a short name. Hub and
    spoke VNets are added here as they are built. Registration is always disabled.
  DESCRIPTION
}

variable "tags" {
  type        = map(string)
  default     = null
  description = "Tags applied to all resources created by this root module."
}
