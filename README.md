# Azure Hub-and-Spoke OpenTofu

OpenTofu infrastructure as code for an Azure hub-and-spoke network that will support:

- Multiple hubs and spokes configured through variable files.
- Resources across Azure regions, subscriptions, and resource groups.
- Azure Bastion Developer in each hub.
- Shared Private DNS zones for common Azure private endpoint services.
- GitHub Actions deployment from `main`.
- Microsoft Entra authentication for Azure and remote state, with no storage keys.

## Status

The repository includes only the one-time local bootstrap needed to create Azure Storage for future OpenTofu state. Hub-and-spoke infrastructure and deployment workflows have not been created.

See [bootstrap/README.md](bootstrap/README.md) to create the state backend.
