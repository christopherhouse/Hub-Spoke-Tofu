output "resource_id" {
  description = "Resource ID of the resource group, suitable for use as a parent_id."
  value       = azapi_resource.this.id
}

output "name" {
  description = "Name of the resource group."
  value       = azapi_resource.this.name
}

output "location" {
  description = "Azure region of the resource group."
  value       = azapi_resource.this.location
}

output "subscription_id" {
  description = "ID of the subscription containing the resource group."
  value       = var.subscription_id
}
