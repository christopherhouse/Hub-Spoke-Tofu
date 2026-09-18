# infra

The workload root for the hub-and-spoke network. This is the only composition root for
Azure resources; `bootstrap/` is separate and only creates the state backend.

Currently deploys:

- a resource group for shared connectivity DNS
- the centrally owned Private Link DNS zone catalog (`modules/private-dns`)

Hubs, spokes, peerings and Bastion are added to this root as they are built.

## Prerequisites

- OpenTofu 1.9 or later
- Azure CLI, signed in with `az login`
- The state backend created by `bootstrap/`, which writes `bootstrap/backend.generated.hcl`
- RBAC on the target subscription sufficient to create resource groups and Private DNS zones,
  plus `Storage Blob Data Contributor` on the state container

## Usage

```powershell
cd infra
Copy-Item infra.tfvars.example infra.tfvars   # then edit it

tofu init -backend-config=..\bootstrap\backend.generated.hcl
tofu fmt -recursive -check
tofu validate
tofu plan -var-file infra.tfvars -out tfplan
tofu apply tfplan
```

`infra.tfvars` is gitignored. Only `infra.tfvars.example` is committed.

## State

State lives in the bootstrapped storage account under the key `hub-spoke/infra.tfstate`,
declared in `terraform.tf`. The rest of the backend configuration comes from
`bootstrap/backend.generated.hcl` at init time.

Authentication is Entra-only: `use_azuread_auth = true` and `use_oidc = true`. The storage
account has shared-key authorization disabled, so there is no key or SAS path available.

## Variables

| Name | Required | Description |
| --- | --- | --- |
| `subscription_id` | yes | Provider home subscription |
| `dns_subscription_id` | no | Subscription owning the zones; defaults to `subscription_id` |
| `dns_resource_group_name` | yes | Resource group created to hold the zones |
| `dns_resource_group_location` | yes | Region for that resource group |
| `enabled_zone_families` | yes | Service families to create zones for |
| `container_apps_regions` | conditional | Required when `containerapps` is enabled |
| `additional_private_dns_zones` | no | Zones outside the built-in catalog |
| `private_dns_virtual_network_links` | no | VNets to link to every zone |
| `tags` | no | Tags applied to all resources |
| `enable_telemetry` | no | AVM telemetry, defaults to `true` |

See `modules/private-dns/README.md` for the zone catalog and the service-specific caveats.

## Notes

- Private DNS zones are global resources. `dns_resource_group_location` only places the
  resource group metadata.
- `private_dns_virtual_network_links` is empty until hub and spoke VNets exist. Links are
  created against every zone, with registration disabled.
- All Azure resources come from pinned Azure Verified Modules, with one documented
  exception: `modules/resource-group`. See that module's README.

## Multi-subscription model

Hubs and spokes may live in different subscriptions within the same Entra tenant. This
needs no provider aliases: in AzAPI the target subscription comes from the resource ID built
from `parent_id`, not from the provider's `subscription_id`. Onboarding a subscription is a
`tfvars` change.

The deployment identity needs rights in every target subscription, including
`Microsoft.Resources/subscriptions/providers/register/action`, since AzAPI registers
resource providers in the target subscription. A single management-group assignment covers
this. Cross-subscription peering additionally needs Network Contributor on **both** VNets.

Cross-*tenant* is out of scope and would require separate credentials or Azure Lighthouse.
