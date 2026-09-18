variable "subscription_id" {
  description = "Azure subscription ID in which to create the state resources."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a valid GUID."
  }
}

variable "create_resource_group" {
  description = "Whether to create the resource group. Set to false to deploy into an existing resource group named resource_group_name."
  type        = bool
  default     = true
}

variable "location" {
  description = "Azure region for the state resource group and storage account. Required when create_resource_group is true; otherwise the existing resource group's location is used."
  type        = string
  default     = null

  validation {
    condition     = !var.create_resource_group || var.location != null
    error_message = "location must be set when create_resource_group is true."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group that will contain the state storage account. Must already exist when create_resource_group is false."
  type        = string
  default     = "rg-tofu-state"
}

variable "storage_account_name" {
  description = "Globally unique storage account name containing 3-24 lowercase letters and numbers."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must contain 3-24 lowercase letters and numbers."
  }
}

variable "container_name" {
  description = "Blob container name for OpenTofu state."
  type        = string
  default     = "tfstate"

  validation {
    condition = (
      length(var.container_name) >= 3 &&
      length(var.container_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.container_name)) &&
      !strcontains(var.container_name, "--")
    )
    error_message = "container_name must be 3-63 lowercase letters, numbers, or single hyphens and cannot begin or end with a hyphen."
  }
}

variable "replication_type" {
  description = "Storage replication type. ZRS is the default for regional resilience."
  type        = string
  default     = "ZRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS"], var.replication_type)
    error_message = "replication_type must be LRS, ZRS, GRS, or GZRS."
  }
}

variable "state_principal_object_ids" {
  description = "Microsoft Entra object IDs granted Storage Blob Data Contributor on the state container."
  type        = set(string)

  validation {
    condition = alltrue([
      for object_id in var.state_principal_object_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", object_id))
    ])
    error_message = "Every state_principal_object_ids value must be a valid GUID."
  }
}

variable "tags" {
  description = "Tags applied to the storage account, and to the resource group when this configuration creates it."
  type        = map(string)
  default = {
    managed-by = "opentofu"
    purpose    = "opentofu-state"
  }
}

variable "enable_telemetry" {
  description = "Controls telemetry for Azure Verified Modules."
  type        = bool
  default     = true
}
