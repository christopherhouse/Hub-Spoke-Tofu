output "zone_ids" {
  description = "Map of Private DNS zone name to resource ID."
  value       = { for name, zone in module.zone : name => zone.resource_id }
}

output "zone_names" {
  description = "Sorted list of the Private DNS zone names that were created."
  value       = sort(tolist(local.zones))
}

output "zones" {
  description = "Map of Private DNS zone name to its resource ID and virtual network links."
  value = {
    for name, zone in module.zone : name => {
      resource_id           = zone.resource_id
      virtual_network_links = zone.virtual_network_link_outputs
    }
  }
}
