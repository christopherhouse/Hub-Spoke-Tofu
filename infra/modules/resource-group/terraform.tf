terraform {
  required_version = ">= 1.9, < 2.0"

  required_providers {
    azapi = {
      # 2.7.0 fixed azapi_client_config returning the Azure CLI default subscription and
      # 2.9.0 fixed auxiliary_tenant_ids not reaching the ARM client. Both matter for
      # multi-subscription work.
      source  = "Azure/azapi"
      version = ">= 2.9, < 3.0"
    }
  }
}
