output "dns_resource_group_id" {
  description = "Resource ID of the resource group holding the shared Private DNS zones."
  value       = module.dns_resource_group.resource_id
}

output "dns_resource_group_name" {
  description = "Name of the resource group holding the shared Private DNS zones."
  value       = module.dns_resource_group.name
}

output "private_dns_zone_ids" {
  description = "Map of Private DNS zone name to resource ID, for consumption by spoke deployments."
  value       = module.private_dns.zone_ids
}

output "private_dns_zone_names" {
  description = "Sorted list of the Private DNS zones that were created."
  value       = module.private_dns.zone_names
}
