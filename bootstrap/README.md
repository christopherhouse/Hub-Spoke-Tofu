# State backend bootstrap

This isolated OpenTofu root creates the Azure resources required for future remote state using pinned Azure Verified Modules:

- `Azure/avm-res-resources-resourcegroup/azurerm` version `0.4.0`.
- `Azure/avm-res-storage-storageaccount/azurerm` version `0.8.1`.

The storage account disables Shared Key authorization, defaults portal access to Microsoft Entra authorization, blocks anonymous blob access, requires TLS 1.2, enables infrastructure encryption, and enables blob/container recovery features.

## Prerequisites

- OpenTofu 1.11 or later.
- Azure CLI authenticated with `az login`.
- Permission to create the resource group and storage account.
- `Owner`, `User Access Administrator`, or equivalent permission to create the role assignments.

## Run

From the repository root. `-Location` is required so the region is always an explicit choice:

```powershell
.\bootstrap\Invoke-Bootstrap.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -StorageAccountName 'globallyuniquestatename' `
    -Location 'westeurope'
```

The region is validated against the subscription before anything is deployed. List valid values with:

```powershell
az account list-locations --query '[].name' --output tsv
```

The script grants the signed-in Azure CLI user access to the state container by default. For a service principal, managed identity, GitHub deployment identity, or additional administrator, pass one or more Entra object IDs:

```powershell
.\bootstrap\Invoke-Bootstrap.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -StorageAccountName 'globallyuniquestatename' `
    -Location 'westeurope' `
    -PrincipalObjectId @(
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222'
    )
```

The script runs `tofu fmt -check`, `tofu init`, `tofu validate`, `tofu plan`, and an interactive `tofu apply`. Use `-AutoApprove` only when unattended confirmation is intentional.

## Using an existing resource group

By default the configuration creates the resource group. To deploy the state storage account into a resource group that already exists, pass `-UseExistingResourceGroup`:

```powershell
.\bootstrap\Invoke-Bootstrap.ps1 `
    -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -StorageAccountName 'globallyuniquestatename' `
    -ResourceGroupName 'rg-existing-platform' `
    -UseExistingResourceGroup
```

In that mode the configuration reads the existing group and inherits its location, and does not manage or tag it. `-Location` and `-UseExistingResourceGroup` are mutually exclusive parameter sets, so the region cannot be set here. The equivalent variables are `create_resource_group = false` with `location = null`.

## Outputs

After a successful apply, the script writes ignored local files:

- `bootstrap.auto.tfvars.json`
- `bootstrap.tfplan`
- `backend.generated.hcl`
- `terraform.tfstate`

Use `backend.generated.hcl` with the future workload root:

```powershell
tofu init -backend-config="..\bootstrap\backend.generated.hcl"
```

The workload root must declare an empty backend block:

```hcl
terraform {
  backend "azurerm" {}
}
```

For local Azure CLI authentication, set `use_oidc = false` in a local copy of the generated backend configuration. GitHub Actions should keep `use_oidc = true`, set the Azure client, tenant, and subscription identifiers through environment variables, and use `id-token: write`.

## Lifecycle

This root intentionally uses local state because it creates the remote backend. Keep `bootstrap/terraform.tfstate` secure and backed up.

The storage account has an Azure `CanNotDelete` management lock. Removing it requires an explicit code change and review.
