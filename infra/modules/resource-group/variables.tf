variable "name" {
  type        = string
  description = "Name of the resource group."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.()-]{1,90}$", var.name))
    error_message = "name must be 1-90 characters of letters, digits, underscores, periods, parentheses or hyphens."
  }

  validation {
    condition     = !endswith(var.name, ".")
    error_message = "name cannot end with a period."
  }
}

variable "location" {
  type        = string
  description = "Azure region for the resource group."

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "location must be an Azure region short name such as centralus."
  }
}

variable "subscription_id" {
  type        = string
  description = <<-DESCRIPTION
    ID of the subscription the resource group is created in. This is what makes the module
    subscription-agnostic: the target comes from parent_id rather than from the provider
    configuration, so hubs and spokes in different subscriptions need no provider aliases.
  DESCRIPTION

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "tags" {
  type        = map(string)
  default     = null
  description = "Tags applied to the resource group."
}
