locals {
  # Defaults to the provider subscription, but can point anywhere in the tenant because
  # the resource-group module targets via parent_id rather than the provider config.
  dns_subscription_id = coalesce(var.dns_subscription_id, var.subscription_id)
}

module "dns_resource_group" {
  source = "./modules/resource-group"

  subscription_id = local.dns_subscription_id
  name            = var.dns_resource_group_name
  location        = var.dns_resource_group_location
  tags            = var.tags
}

module "private_dns" {
  source = "./modules/private-dns"

  parent_id = module.dns_resource_group.resource_id

  enabled_zone_families  = var.enabled_zone_families
  container_apps_regions = var.container_apps_regions
  additional_zones       = var.additional_private_dns_zones
  virtual_network_links  = var.private_dns_virtual_network_links

  tags             = var.tags
  enable_telemetry = var.enable_telemetry
}
