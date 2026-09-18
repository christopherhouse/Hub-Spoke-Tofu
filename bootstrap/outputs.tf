output "resource_group_name" {
  description = "Resource group containing the OpenTofu state storage account."
  value       = local.resource_group_name
}

output "storage_account_name" {
  description = "Storage account containing OpenTofu state."
  value       = module.storage_account.name
}

output "container_name" {
  description = "Blob container containing OpenTofu state."
  value       = module.storage_account.containers["state"].name
}

output "storage_account_id" {
  description = "Resource ID of the state storage account."
  value       = module.storage_account.resource_id
}

output "container_resource_manager_id" {
  description = "Resource Manager ID of the state blob container."
  value       = module.storage_account.containers["state"].id
}
