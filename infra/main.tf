module "dns_resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  location         = var.dns_resource_group_location
  name             = var.dns_resource_group_name
  tags             = var.tags
  enable_telemetry = var.enable_telemetry
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
