# infra

Subscription-scope Bicep root for the hub-and-spoke network.

| File | Purpose |
|---|---|
| `main.bicep` | Composition root. `targetScope = 'subscription'`. |
| `main.bicepparam` | Parameter values for the current deployment. |
| `types.bicep` | Shared user-defined types (`hubType` and friends), surfaced with `@export()`. |
| `zones.bicep` | Curated Private Link DNS zone catalog, surfaced with `@export()`. |
| `modules/hub.bicep` | Hub virtual network, subnets, NSGs, Azure Bastion and the jump box NAT gateway. Resource-group scope. |
| `modules/spoke.bicep` | Spoke virtual network, subnets, per-subnet NSGs and bidirectional peering to its hub. Resource-group scope. |

## Modules

| Module | Version |
|---|---|
| `br/public:avm/res/resources/resource-group` | `0.4.4` |
| `br/public:avm/ptn/network/private-link-private-dns-zones` | `0.7.3` |
| `br/public:avm/res/network/virtual-network` | `0.9.0` |
| `br/public:avm/res/network/network-security-group` | `0.5.3` |
| `br/public:avm/res/network/bastion-host` | `0.8.2` |

`avm/ptn/network/hub-networking` is **not** used. Its README flags the module as orphaned —
only security and bug fixes are handled — and its shape assumes a mesh-peered multi-hub
topology with a firewall and route tables that this design keeps optional. The hub is
composed from AVM resource modules instead.

## Parameters

| Name | Required | Notes |
|---|---|---|
| `dnsResourceGroupName` | Yes | Resource group that holds the shared zones. |
| `location` | Yes | Resource group location, and the region substituted into regional zone names. |
| `hubs` | No | `hubType[]`. One entry per hub. Each gets a resource group, VNet, subnets and Bastion, and is linked to every zone. |
| `spokes` | No | `spokeType[]`. One entry per spoke. Each gets a resource group, VNet, subnets, a peering to its hub, and links to every zone. |
| `virtualNetworkLinks` | No | Extra VNets to link, beyond the hubs, which are linked automatically. |
| `additionalPrivateLinkPrivateDnsZonesToInclude` | No | Extra zones beyond the curated catalog. |
| `tags` | No | Applied to the resource group and every zone. Hubs may override with their own `tags`. |
| `enableTelemetry` | No | AVM telemetry, default `true`. |

## Hubs

A hub is data. Adding one — in another region, resource group, or subscription of the same
tenant — is an entry in `hubs`, not a template change. `subscriptionId` is optional and
defaults to the subscription the deployment targets.

Each hub produces:

- a resource group,
- `vnet-<hub name>` with the subnets below,
- an NSG per subnet,
- an Azure Bastion **Standard** host and its Standard SKU public IP,
- an optional NAT gateway and its Standard SKU static public IP, attached to the jump box
  subnet,
- a link from the hub VNet to every Private DNS zone, with registration disabled.

### Address plan

`10.0.0.0/16` is reserved for hubs, one `/19` each. `10.1.0.0/16` onward is for spokes, one
`/20` each.

Hub 1 is `10.0.0.0/19` (10.0.0.0 – 10.0.31.255).

| Subnet | Prefix | Notes |
|---|---|---|
| `AzureBastionSubnet` | `10.0.0.0/26` | Name fixed by Azure. /26 is the minimum for Bastion resources created after 2 November 2021. |
| `snet-jumpbox` | `10.0.0.64/27` | NAT gateway attached for outbound SNAT. |
| *(free)* | `10.0.0.96/27` | Left open so the runners subnet lands on a /26 boundary. |
| `snet-runners` | `10.0.0.128/26` | Delegated to `Microsoft.App/environments`. |
| *(reserved)* | `10.0.0.192` – `10.0.31.255` | Firewall, gateway, DNS resolver, shared services. |

Spoke 1 is `10.1.0.0/20` (10.1.0.0 – 10.1.15.255).

| Subnet | Prefix | Notes |
|---|---|---|
| `snet-workload` | `10.1.0.0/24` | |
| `snet-privateendpoints` | `10.1.1.0/24` | `allowBastionAccess: false` — hosts no virtual machines. |
| *(free)* | `10.1.2.0` – `10.1.15.255` | |

Subsequent hubs take the next /19 and subsequent spokes the next /20. Hub and spoke ranges
must not overlap; that invariant is documented, not enforced in code.

### Bastion

**Standard**, not Developer. Developer needs no subnet and no public IP and costs nothing,
but it does not support virtual network peering, so it can only reach virtual machines in its
own VNet and is useless for spoke access. Standard is billed hourly per hub, plus its public
IP.

The NSG on `AzureBastionSubnet` carries the full required rule set from *Configure NSG rules
for Azure Bastion*. Applying an NSG there is optional, but once one exists every rule must be
present or Bastion stops receiving platform updates and connectivity breaks.

The jump box NSG allows RDP and SSH inbound from the `AzureBastionSubnet` prefix only. No
management port is exposed to the internet.

### NAT gateway

`natGateway` on a hub attaches a NAT gateway to `snet-jumpbox`. Omit it and jump boxes fall
back to Azure **default outbound access**, whose source address is implicit, unpredictable,
and impossible to allow-list — and which Azure is retiring. With the NAT gateway, all
outbound traffic from the subnet leaves through one known static public IP.

- It is only deployed when the jump box subnet is. Outbound SNAT with no subnet attached
  would just be a billed idle resource.
- A NAT gateway is **zonal or non-zonal, never zone-redundant**. `availabilityZone` defaults
  to `-1` (non-zonal); if it is set, the public IP is created in the same zone.
- One Standard SKU static public IP is created by default. Supply `publicIpResourceIds` or
  `publicIpPrefixResourceIds` instead to keep an address that is already allow-listed, or to
  get a contiguous allow-listable range.
- It does not change inbound access. Bastion still handles that, and the jump box NSG still
  admits RDP and SSH only from `AzureBastionSubnet`.
- Attaching a NAT gateway overrides any default route to the internet for the subnet, so it
  takes precedence over a load balancer or instance-level public IP for outbound traffic.

### Runners subnet

`snet-runners` is the landing spot for an Azure Container Apps workload profile environment
hosting self-hosted GitHub Actions runners. The environment, its workload profiles, the jobs,
and the GitHub runner registration are **not** deployed by this repository yet.

- Delegation to `Microsoft.App/environments` is mandatory for a workload profile environment,
  and the subnet is dedicated to it.
- A /26 leaves 50 usable addresses after the 14 Container Apps reserves — up to 25 dedicated
  workload profile nodes or 250 consumption replicas. It is oversized on purpose: **an
  environment's subnet cannot be resized once the environment exists**, so growing later means
  rebuilding the environment.
- Its NSG states the Container Apps outbound requirements explicitly, plus HTTPS to the
  internet for GitHub. No deny rule is added: the platform default rules already block inbound
  from the internet.
- `privatelink.centralus.azurecontainerapps.io` is already in the zone catalog and linked to
  the hub, so an internal environment reached through a private endpoint resolves correctly.

## Spokes

A spoke is data, exactly like a hub. Each entry in `spokes` produces:

- a resource group,
- `vnet-<spoke name>` with the subnets supplied in `subnets`,
- one network security group per subnet,
- a **bidirectional** peering with the hub named in `hubName`,
- a link from the spoke VNet to every Private DNS zone, with registration disabled.

`hubName` must match the `name` of an entry in `hubs`. Each spoke references exactly one hub.
A name that matches nothing fails with a null-reference error rather than a helpful message:
Bicep's `assert` is still experimental, so the invariant is documented rather than enforced.

Spoke subnets are a generic list, not named roles like the hub's. A spoke is a workload
landing zone, so its subnets are not knowable in advance.

### Peering

The AVM virtual network module creates **both** directions when `remotePeeringEnabled` is set,
and derives the remote subscription and resource group by splitting the remote VNet resource
ID. That is what makes cross-subscription peering a parameter change rather than a structural
one — no provider plumbing, only RBAC on both sides.

| Setting | Default | Why |
|---|---|---|
| `allowVirtualNetworkAccess` | `true` | The point of the peering. |
| `allowForwardedTraffic` | `true` | Needed once a hub firewall forwards traffic. Inert until then, and enabling it up front avoids re-peering later. |
| `allowGatewayTransit` | `false` | No hub gateway exists yet. |
| `useRemoteGateways` | `false` | Setting this before the hub has a VPN or ExpressRoute gateway fails the peering outright. |

When a hub gateway is added, set `peering.useRemoteGateways` and `peering.allowHubGatewayTransit`
together on the spoke — one configures each end.

Peering is **not transitive**. Spoke-to-spoke traffic needs a hub firewall or route tables,
both of which this design keeps optional.

### Spokes in another subscription

`subscriptionId` places a spoke in another subscription of the same tenant. The deployment
identity needs Contributor there, and **cannot grant it to itself** — it is deliberately not
User Access Administrator. Add the subscription to `targetSubscriptionIds` in
`bootstrap/main.bicepparam` and redeploy the bootstrap root by hand *before* pushing the
branch, or the pull request `what-if` job fails, not just the deploy.

## Network security groups

**Every subnet gets its own NSG**, hub and spoke, whether or not it carries custom rules.
Adding a rule later is then a parameter change rather than new infrastructure plus a subnet
re-association.

The baseline is deliberately **empty**. The Azure platform default rules already deny inbound
from the internet and allow VNet-to-VNet; restating them would be maintenance with no benefit
and a risk of drifting from the platform.

### Adding rules

Rules are set per subnet in `main.bicepparam`. No template change is needed:

```bicep
subnets: [
  {
    name: 'snet-workload'
    addressPrefix: '10.1.0.0/24'
    securityRules: [
      {
        name: 'AllowHttpsFromHub'
        properties: {
          description: 'Workload API reachable from the hub only.'
          access: 'Allow'
          direction: 'Inbound'
          priority: 200
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/19'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.1.0.0/24'
          destinationPortRange: '443'
        }
      }
    ]
  }
]
```

The rule shape is not a free-form object. `types.bicep` re-exports `securityRuleType` from the
AVM network security group module, so a malformed rule fails at `az bicep build-params` rather
than at deployment.

### Reserved priorities

Caller rules are **appended** to the generated ones, never substituted for them — a rule that
displaced the Bastion set or the Container Apps outbound set would break connectivity
silently. A priority collision is an Azure deployment error, not a build error, so keep to
these ranges:

| Subnet | Generated | Use for caller rules |
|---|---|---|
| Spoke subnets | 100 (Bastion RDP/SSH, unless `allowBastionAccess: false`) | 200+ |
| `snet-jumpbox` | 100 (Bastion RDP/SSH) | 200+ |
| `snet-runners` | 100–200 (Container Apps outbound) | 300+ |
| `AzureBastionSubnet` | 120–150 (required Bastion set) | 300+ |

A rule `description` must be **140 characters or fewer**. `az bicep build` does not catch
this; Azure rejects it at preflight with `SecurityRuleDescriptionTooLong`.

### Private endpoint network policies

`privateEndpointNetworkPolicies` controls whether a subnet's NSG and route table apply to
private endpoints *in that subnet*. Every subnet sends it **explicitly**, defaulting to
`Disabled` via `defaultPrivateEndpointNetworkPolicies` in `types.bicep`.

Leaving it unset is what causes drift. Recent subnet API versions changed the Azure Resource
Manager default from `Disabled` to `Enabled`, while the documented default and every subnet
created before the change are `Disabled`. A template that omits the property therefore reports
a permanent `Disabled => Enabled` difference in `what-if` against existing subnets, and the
value a new subnet lands on depends on which AVM version happens to be pinned. The AVM virtual
network module passes the property straight through as `null` when it is not supplied, so it
does not shield callers from this. Sending a value explicitly removes both problems.

Set `privateEndpointNetworkPolicies: 'Enabled'` on a subnet that hosts private endpoints and
whose NSG or route table must filter or redirect traffic to them — for example to force
private endpoint traffic through a firewall. This is not a policy-driven setting; no Azure
Policy in this tenant modifies it.

## Zone catalog

`zones.bicep` exports `curatedPrivateLinkPrivateDnsZones`, 24 zones verified against the
Microsoft Learn *Azure Private Endpoint private DNS zone values* page. Public cloud only.

Covered: storage (blob, file, queue, table, dfs, web), Key Vault, Azure SQL, PostgreSQL
flexible server, MySQL flexible server, Cosmos DB (SQL, Mongo, Cassandra, Gremlin, Table),
Azure Managed Redis, App Service, AI Foundry / Azure OpenAI / Cognitive Services, AI Search,
Container Registry, Service Bus, and Container Apps.

The AVM pattern module ships a ~110-zone default catalog. We pass our curated list
explicitly so the zones deployed are a reviewed decision rather than a module default.

### Caveats baked into the catalog

- **Container Apps is regional.** `privatelink.{regionName}.azurecontainerapps.io`. The
  pattern module substitutes `{regionName}` and `{regionCode}` from its own `location`
  parameter, so a single invocation resolves one region. Additional regions must be passed
  as literal zone names through `additionalPrivateLinkPrivateDnsZonesToInclude`, or handled
  by a second module invocation.
- **Azure Managed Redis** (`privatelink.redis.azure.net`) is not Azure Cache for Redis
  (`privatelink.redis.cache.windows.net`). Only the former is in the catalog.
- **Container Registry data endpoints** and **App Service SCM** do not get their own zones.
  They are records inside the parent zone when Azure Private DNS is used.
- **`servicebus`** covers Service Bus, Event Hubs, and Relay.
- **"Foundry IQ"** has no dedicated zone. Foundry resources are served by the three AI
  endpoint zones already present.
- **Cosmos DB for PostgreSQL** (`privatelink.postgres.cosmos.azure.com`) is deliberately
  excluded. It is a different service from PostgreSQL flexible server.
- Autoregistration is never enabled on these zones. Private endpoints own the records.

## Known gaps

The pattern module outputs `combinedPrivateLinkPrivateDnsZonesReplacedWithVnetsToLink`
plus the resource group ID and name. It does **not** emit per-zone resource IDs, which
spokes will need for private endpoint DNS zone groups. Zone resource IDs are deterministic,
so they can be constructed from the subscription, resource group, and zone name when the
spoke work lands.

Hub virtual network links are composed the same way, from the hub definition rather than the
hub module outputs: a variable loop cannot read module outputs (BCP182) and a for-expression
cannot be nested inside `concat` (BCP138). The naming convention lives in one place,
`hubVirtualNetworkName` in `types.bicep`, and the zone module takes an explicit `dependsOn`
on the hubs because the dependency is no longer implied by a reference.

## Validation

```powershell
az bicep build --file infra/main.bicep
az bicep build-params --file infra/main.bicepparam
```
