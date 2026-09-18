# resource-group

Creates an Azure resource group in an explicitly specified subscription.

## Why this is not an Azure Verified Module

This is a documented exception to the AVM-first policy.

- **Evaluated:** `Azure/avm-res-resources-resourcegroup/azurerm` 0.4.0
- **Search date:** 2026-09-18
- **Gap:** the module hardcodes its target to the provider's identity:

  ```hcl
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  ```

  `data.azapi_client_config` is provider-scoped, so the AVM can only create resource groups
  in the subscription the `azapi` provider is configured with. Hubs and spokes in this
  repository span subscriptions, and the only AVM-compatible workaround is a statically
  declared provider alias per subscription — which defeats adding a subscription through
  `tfvars` alone.
- **Resolution:** call `azapi_resource` directly so `parent_id` carries the target
  subscription.
- **Re-evaluate when:** the AVM accepts a `subscription_id` or `parent_id` input.

This is the **only** exception the multi-subscription design requires. Resource groups are
the sole resource type whose parent is the subscription itself; everything else takes a
fully-qualified resource group `parent_id` and is therefore already subscription-agnostic.

## Usage

```hcl
module "hub_resource_group" {
  source = "./modules/resource-group"

  subscription_id = "00000000-0000-0000-0000-000000000000"
  name            = "RG-HUB-CUS"
  location        = "centralus"
  tags            = var.tags
}

module "hub_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.22.2"

  parent_id = module.hub_resource_group.resource_id # carries the subscription
  # ...
}
```

## Constraints

- All subscriptions must be in the **same Entra tenant**. Cross-tenant management needs
  separate credentials or Azure Lighthouse delegation, not just a different `parent_id`.
- The deployment identity needs rights in every target subscription, including
  `Microsoft.Resources/subscriptions/providers/register/action`, because AzAPI registers
  resource providers in the *target* subscription. Granting at a management group that
  contains the subscriptions covers this in one assignment.
