# Azure Hub-and-Spoke OpenTofu

OpenTofu infrastructure as code for an Azure hub-and-spoke network that will support:

- Multiple hubs and spokes configured through variable files.
- Resources across Azure regions, subscriptions, and resource groups.
- Azure Bastion Developer in each hub.
- Shared Private DNS zones for common Azure private endpoint services.
- GitHub Actions deployment from `main`.
- Microsoft Entra authentication for Azure and remote state, with no storage keys.

## Status

| Component | State |
| --- | --- |
| Remote state backend (`bootstrap/`) | Deployable |
| Shared Private DNS zone catalog (`infra/`) | Deployable |
| Hubs, spokes, peering, Bastion | Not yet built |
| GitHub Actions workflows | Not yet built |

## Layout

- [`bootstrap/`](bootstrap/README.md) — one-time, local-state root that creates the Azure
  Storage account for OpenTofu state.
- [`infra/`](infra/README.md) — the single workload root, using the remote backend. Hubs and
  spokes are added here.
- [`infra/modules/private-dns/`](infra/modules/private-dns/README.md) — the verified Private
  Link DNS zone catalog.

All Azure resources are created through pinned Azure Verified Modules.
