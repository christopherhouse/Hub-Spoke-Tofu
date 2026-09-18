locals {
  storage_blob_data_contributor_role_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"

  resource_group_id   = var.create_resource_group ? module.resource_group[0].resource_id : data.azapi_resource.existing_resource_group[0].id
  resource_group_name = var.create_resource_group ? module.resource_group[0].name : data.azapi_resource.existing_resource_group[0].name

  # An existing resource group supplies its own location so the storage account
  # is never created in a region that conflicts with its parent.
  location = var.create_resource_group ? var.location : data.azapi_resource.existing_resource_group[0].location
}

data "azapi_resource" "existing_resource_group" {
  count = var.create_resource_group ? 0 : 1

  type      = "Microsoft.Resources/resourceGroups@2025-04-01"
  name      = var.resource_group_name
  parent_id = "/subscriptions/${var.subscription_id}"
}

module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "0.4.0"

  count = var.create_resource_group ? 1 : 0

  location         = var.location
  name             = var.resource_group_name
  tags             = var.tags
  enable_telemetry = var.enable_telemetry
}

module "storage_account" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.8.1"

  location  = local.location
  name      = var.storage_account_name
  parent_id = local.resource_group_id

  account_kind                      = "StorageV2"
  account_sku_name                  = "Standard_${var.replication_type}"
  access_tier                       = "Hot"
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  default_to_oauth_authentication   = true
  https_traffic_only_enabled        = true
  infrastructure_encryption_enabled = true
  local_user_enabled                = false
  min_tls_version                   = "TLS1_2"
  network_rules                     = null
  public_network_access_enabled     = true
  shared_access_key_enabled         = false

  blob_properties = {
    versioning_enabled = true
    delete_retention_policy = {
      allow_permanent_delete = false
      days                   = 30
      enabled                = true
    }
    container_delete_retention_policy = {
      allow_permanent_delete = false
      days                   = 30
      enabled                = true
    }
  }

  containers = {
    state = {
      name          = var.container_name
      public_access = "None"
      role_assignments = {
        for principal_id in var.state_principal_object_ids :
        principal_id => {
          role_definition_id_or_name = local.storage_blob_data_contributor_role_id
          principal_id               = principal_id
        }
      }
    }
  }

  role_assignment_definition_lookup_enabled = false
  lock = {
    kind = "CanNotDelete"
  }

  tags             = var.tags
  enable_telemetry = var.enable_telemetry
}
