terraform {
  required_version = ">= 1.9, < 2.0"

  # Partial configuration. The remaining values come from the bootstrap output:
  #   tofu init -backend-config=../bootstrap/backend.generated.hcl
  # Authentication is Entra-only; no storage account keys are ever used.
  backend "azurerm" {
    key = "hub-spoke/infra.tfstate"
  }

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.1, < 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
