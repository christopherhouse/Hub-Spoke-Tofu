# infra

Subscription-scope Bicep root for the hub-and-spoke network.

| File | Purpose |
|---|---|
| `main.bicep` | Composition root. `targetScope = 'subscription'`. |
| `main.bicepparam` | Parameter values for the current deployment. |
| `types.bicep` | Shared user-defined types (`hubType` and friends), surfaced with `@export()`. |
| `zones.bicep` | Curated Private Link DNS zone catalog, surfaced with `@export()`. |
| `runner-nsg-rules.bicep` | Reviewed NSG rule set for the Container Apps runners subnet, surfaced with `@export()`. |
| `modules/hub.bicep` | Hub virtual network, subnets, NSGs, route tables, Azure Bastion and the Azure Firewall. Resource-group scope. |
| `modules/spoke.bicep` | Spoke virtual network, subnets, per-subnet NSGs and route tables, and bidirectional peering to its hub. Resource-group scope. |
| `modules/firewall.bicep` | Azure Firewall and its policy, including the always-SNAT setting that makes hub transit work. Resource-group scope. |
| `modules/log-analytics.bicep` | Shared Log Analytics workspace. Separate from `platform.bicep` purely for ordering. |
| `modules/platform.bicep` | Shared Key Vault, container registry and the runner managed identity, with private endpoints. |
| `modules/container-apps-environment.bicep` | Workload profile Container Apps environment in the runners spoke. |
| `modules/github-runner-job.bicep` | One event-driven self-hosted runner job, per repository. |

## Modules

| Module | Version |
|---|---|
| `br/public:avm/res/resources/resource-group` | `0.4.4` |
| `br/public:avm/ptn/network/private-link-private-dns-zones` | `0.7.3` |
| `br/public:avm/res/network/virtual-network` | `0.9.0` |
| `br/public:avm/res/network/network-security-group` | `0.5.3` |
| `br/public:avm/res/network/bastion-host` | `0.8.2` |
| `br/public:avm/res/network/azure-firewall` | `0.9.2` |
| `br/public:avm/res/network/firewall-policy` | `0.3.6` |
| `br/public:avm/res/network/route-table` | `0.5.0` |
| `br/public:avm/res/network/private-endpoint` | `0.12.1` |
| `br/public:avm/res/compute/virtual-machine` | `0.22.3` |
| `br/public:avm/res/managed-identity/user-assigned-identity` | `0.6.0` |
| `br/public:avm/res/operational-insights/workspace` | `0.16.1` |
| `br/public:avm/res/key-vault/vault` | `0.14.2` |
| `br/public:avm/res/container-registry/registry` | `0.13.1` |
| `br/public:avm/res/app/managed-environment` | `0.16.0` |
| `br/public:avm/res/app/job` | `0.7.2` |

`avm/ptn/network/hub-networking` is **not** used. Its README flags the module as orphaned —
only security and bug fixes are handled — and its shape assumes a mesh-peered multi-hub
topology with a firewall and route tables that this design keeps optional. The hub is
composed from AVM resource modules instead.

## Parameters

| Name | Required | Notes |
|---|---|---|
| `dnsResourceGroupName` | Yes | Resource group that holds the shared zones. |
| `location` | Yes | Resource group location, and the region substituted into regional zone names. |
| `defaultSubscriptionId` | Yes | Subscription hosting everything that does not name a subscription of its own. See [Subscription targeting](#subscription-targeting). |
| `hubs` | No | `hubType[]`. One entry per hub. Each gets a resource group, VNet, subnets and Bastion, and is linked to every zone. |
| `spokes` | No | `spokeType[]`. One entry per spoke. Each gets a resource group, VNet, subnets, a peering to its hub, and links to every zone. |
| `virtualNetworkLinks` | No | Extra VNets to link, beyond the hubs, which are linked automatically. |
| `additionalPrivateLinkPrivateDnsZonesToInclude` | No | Extra zones beyond the curated catalog. |
| `platform` | No | `platformType`. Shared Log Analytics, Key Vault, container registry and the runner identity, landing in the spoke named by `spokeName`. |
| `containerAppsEnvironment` | No | `containerAppsEnvironmentType`. Runner environment in the subnet named by `subnetName` of the spoke named by `spokeName`. |
| `githubApp` | No | `githubAppType`. The App the runners authenticate as. Required when `githubRunners` is non-empty. |
| `githubRunners` | No | `githubRunnerType[]`. One entry per repository. Onboarding is an entry here. |
| `tags` | No | Applied to the resource group and every zone. Hubs may override with their own `tags`. |
| `enableTelemetry` | No | AVM telemetry, default `true`. |

## Subscription targeting

Every resource this template deploys lands in a subscription chosen by **data**, never by the
ambient CLI context.

`defaultSubscriptionId` is a required parameter. Each hub, spoke and platform component may
override it with its own `subscriptionId`; anything that does not names `defaultSubscriptionId`
instead. Cross-subscription placement works because every module declares an explicit
`scope: subscription(...)` or `scope: resourceGroup(<subscriptionId>, <name>)`.

This is deliberate, and it is worth understanding why before "simplifying" it back to
`subscription().subscriptionId`:

> `az deployment sub create` targets whichever subscription the CLI has active. `az account set`
> does not persist across shells or CI steps. A subscription-scoped template that infers its
> own subscription will therefore deploy a **complete duplicate estate into the wrong
> subscription and report success** — no error, no warning. That happened in this repository:
> a full hub, firewall and a 125-zone DNS catalog were built in the wrong subscription and had
> to be deleted by hand.

Two rules follow, and both matter:

1. **No module may rely on the deployment's own subscription.** A module with no `scope`, or one
   using the single-argument `resourceGroup(name)`, silently inherits the ambient subscription.
   The DNS resource group and zone catalog were the last two doing this. If you add a module,
   give it an explicit scope.
2. **Always pass `--subscription` as well**, matching `defaultSubscriptionId`. The parameter
   controls where *resources* are created; `--subscription` controls where the *deployment
   record* is written. `deploy.yml` passes `--subscription ${{ vars.AZURE_SUBSCRIPTION_ID }}` on
   both `what-if` and `create`.

To verify the guard holds, point the CLI somewhere harmless and confirm the plan is unchanged:

```pwsh
az account set -s <some-other-subscription>
az deployment sub what-if --location centralus --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

Every resource ID in the output must name `defaultSubscriptionId` (or a `subscriptionId`
explicitly declared on a hub or spoke). Any `Create` against the active subscription is the bug
resurfacing.

## Hubs

A hub is data. Adding one — in another region, resource group, or subscription of the same
tenant — is an entry in `hubs`, not a template change. `subscriptionId` is optional and
defaults to the subscription the deployment targets.

Each hub produces:

- a resource group,
- `vnet-<hub name>` with the subnets below,
- an NSG per subnet,
- an Azure Bastion **Standard** host and its Standard SKU public IP,
- an optional Azure Firewall, its policy, and its two Standard SKU public IPs,
- a route table per hub subnet that declares routes, used to send outbound traffic through
  the firewall,
- a link from the hub VNet to every Private DNS zone, with registration disabled.

### Address plan

`10.0.0.0/16` is reserved for hubs, one `/19` each. `10.1.0.0/16` onward is for spokes, one
`/20` each.

Hub 1 is `10.0.0.0/19` (10.0.0.0 – 10.0.31.255).

| Subnet | Prefix | Notes |
|---|---|---|
| `AzureBastionSubnet` | `10.0.0.0/26` | Name fixed by Azure. /26 is the minimum for Bastion resources created after 2 November 2021. **Never give this subnet a route table.** |
| `snet-jumpbox` | `10.0.0.64/27` | Route table sends `0.0.0.0/0` to the firewall. |
| *(free)* | `10.0.0.96/27` | |
| *(free)* | `10.0.0.128/26` | The former `snet-runners`, deleted with its Container Apps environment. |
| `AzureFirewallSubnet` | `10.0.0.192/26` | Name fixed by Azure, /26 minimum. No NSG, no route table. |
| `AzureFirewallManagementSubnet` | `10.0.1.0/26` | Name fixed by Azure. Required by the Basic SKU. |
| *(reserved)* | `10.0.1.64` – `10.0.31.255` | Gateway, DNS resolver, shared services. |

Spoke 1, `spoke-app-cus`, is `10.1.0.0/20` (10.1.0.0 – 10.1.15.255).

| Subnet | Prefix | Notes |
|---|---|---|
| `snet-workload` | `10.1.0.0/24` | |
| `snet-privateendpoints` | `10.1.1.0/24` | `allowBastionAccess: false` — hosts no virtual machines. |
| *(free)* | `10.1.2.0` – `10.1.15.255` | |

Spoke 2, `spoke-platform-cus`, is `10.1.16.0/20` (10.1.16.0 – 10.1.31.255). It holds the shared
platform services — see [Shared platform services](#shared-platform-services).

| Subnet | Prefix | Notes |
|---|---|---|
| `snet-privateendpoints` | `10.1.16.0/24` | Key Vault and container registry private endpoints. |
| *(free)* | `10.1.17.0` – `10.1.31.255` | |

Spoke 3, `spoke-runners-wu3`, is `10.2.0.0/20` (10.2.0.0 – 10.2.15.255), in **West US 3**. It
hosts the self-hosted runners — see [Self-hosted runners](#self-hosted-github-actions-runners).

| Subnet | Prefix | Notes |
|---|---|---|
| `snet-runners` | `10.2.0.0/26` | Delegated to `Microsoft.App/environments`. Route table sends `0.0.0.0/0` to the hub firewall. |
| *(free)* | `10.2.0.64` – `10.2.15.255` | |

Subsequent hubs take the next /19 and subsequent spokes the next /20. Hub and spoke ranges
must not overlap; that invariant is documented, not enforced in code.

### Orphans after a removal

ARM incremental mode **does not delete**. Anything removed from a template stays in Azure
until someone removes it by hand, so every removal owes a cleanup step.

Removing `snet-runners` from the hub template was safe and did not fail the deployment even
while the failed `cae-hub-cus` still occupied it. `avm/res/network/virtual-network` deploys
subnets as a serial copy loop of nested deployments rather than inline on the virtual network's
`properties`, so dropping an entry from the `subnets` array simply stops declaring that child.

The orphans left by the move of the runners out of the hub — `cae-hub-cus` and its managed
infrastructure resource group, `snet-runners` (`10.0.0.128/26`), `nsg-vnet-hub-cus-runners`,
and `ng-hub-cus` with its public IP — **have been deleted**. Delete order matters: the
environment holds the subnet, and the subnet holds the NSG.

Note the one thing incremental mode *does* remove: a property of a re-declared resource. The
NAT gateway association was a property of `snet-jumpbox`, which is re-declared every run, so
the deployment disassociated it even though it could not delete the gateway.

If this kind of cleanup becomes routine, evaluate **Azure Deployment Stacks** rather than
bolting on cleanup scripts.

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

### Hub firewall and transit routing

Virtual network peering is **not transitive**. A spoke peered to the hub cannot reach another
spoke, and there is no switch on a peering to change that. A user-defined route's next hop must
be an *IP address*, not a virtual network, so hub transit always means putting a next-hop
appliance in the hub. That appliance is an Azure Firewall.

`firewall` on a hub deploys `avm/res/network/azure-firewall` plus
`avm/res/network/firewall-policy` through `infra/modules/firewall.bicep`. Every subnet that
needs egress — the jump box in the hub, the runners in West US 3 — carries a route table with
`0.0.0.0/0` pointing at it. There are **no NAT gateways anywhere**: one appliance, one egress
address, one set of logs.

Traffic from a West US 3 runner to the Central US container registry:

```
runner 10.2.0.x
  → UDR 0.0.0.0/0 → firewall 10.0.0.196     (WU3 spoke peered to hub)
  → application rule matches the registry FQDN
  → firewall SNATs the source to 10.0.0.196
  → registry private endpoint 10.1.16.x sees source 10.0.0.196
  → the platform spoke's existing hub peering carries the reply back
```

#### `snat.privateRanges` is load-bearing

The policy sets `snat.privateRanges` to `['255.255.255.255/32']`. This is the single least
obvious setting in the repository and it must not be "simplified".

Azure Firewall does **not** SNAT when the destination is an RFC 1918 address. Left at that
default, the runner above would arrive at the private endpoint with its own `10.2.x.x` source
address and the endpoint would have no route back, because the two spokes are not peered to
each other. `255.255.255.255/32` is the documented *always SNAT* value: the endpoint then sees
the firewall's private IP, which its own hub peering already routes to.

The consequence is that **`spoke-platform-cus` needs no route table and no change to
`privateEndpointNetworkPolicies`**. No working infrastructure was modified to make transit
work.

Setting `0.0.0.0/0` here is the *opposite* setting — never SNAT — and would stop the firewall
reaching the internet. See
[SNAT private IP ranges](https://learn.microsoft.com/azure/firewall/snat-private-range).

Application rules always SNAT, which is why the policy prefers them over network rules
wherever a destination can be named by FQDN.

#### Basic SKU

Basic is roughly $288/month against $1,015 for Standard, and supports application rules, which
is what the design depends on. Its 250 Mbps ceiling is ample for CI image pulls. Basic requires
a management NIC and an `AzureFirewallManagementSubnet` unconditionally, so both are always
deployed.

#### Two subnets that must never get a route table

- **`AzureBastionSubnet`.** Bastion requires direct outbound internet access and breaks under
  forced tunnelling. A `0.0.0.0/0` route here is the fastest way to lock yourself out of the
  jump box.
- **`AzureFirewallSubnet`.** A default route here *is* forced tunnelling, and would blackhole
  the firewall's own egress.

Neither subnet accepts routes from the parameter file. The guard is structural in
`hub.bicep`, not a convention someone has to remember.

#### The allow-list

Every egress path now depends on one policy, including the jump box's.

The policy in `main.bicepparam` is deliberately permissive: **HTTP and HTTPS to any
destination**, from the hub and the runners spoke. This is a lab trade-off. A curated FQDN list
— the documented Container Apps requirements
([use Azure Firewall with Container Apps](https://learn.microsoft.com/azure/container-apps/use-azure-firewall)),
GitHub, the platform registry and vault, Windows Update — is tighter, but a missing entry shows
up as a runner that never registers or a jump box with no internet, and every new tool means
another rule.

It is still an allow-list rather than an open firewall: outbound only, ports 80 and 443 only,
and every request logged. Inbound is untouched.

**Tighten it if these runners ever build untrusted code.** A runner with unrestricted egress is
an exfiltration path for anything it can read, including the GitHub App private key in Key
Vault — see [Only private repositories](#only-private-repositories).

The service-tag network rules are kept alongside it. An application rule only matches traffic
the firewall can attribute to an FQDN, from SNI or the Host header, so Container Apps platform
traffic that is not plain HTTP would not match the permissive rule.

If a runner never registers or the jump box loses internet access, **check the firewall logs
first** — they go to `log-platform-cus`. A bad rule set costs a fix-up deploy, not a lock-out:
the jump box stays reachable over Bastion regardless, because Bastion does not depend on the
jump box's egress path.

### Route tables

Both `hub.bicep` and `spoke.bicep` create a route table for any subnet that declares `routes`,
and only for such a subnet. An empty route table is not inert — it is one more resource to
reason about — and a subnet with no user-defined routes behaves correctly on the system routes
alone.

Routes are declared symbolically so no IP address is hand-copied into the parameter file:

```bicep
routes: [
  {
    name: 'default-to-firewall'
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'HubFirewall'
  }
]
```

`HubFirewall` is resolved to `VirtualAppliance` plus the firewall's private IP by the module.

Hub and spoke resolve that address differently, and the difference is deliberate:

- **Spokes** read the address from the hub module's `firewallPrivateIp` output. Spokes deploy
  after hubs, so the real value is available.
- **The hub** *computes* it, as `cidrHost(firewallSubnetPrefix, 3)`. It has to: a route table
  must exist before the virtual network that references it, and the firewall cannot exist
  before its subnet does, so reading the output inside the hub would be a cycle. Azure reserves
  the first four addresses of a subnet and the firewall takes the first assignable one, which
  is the subnet base + 4 — `10.0.0.196` for `10.0.0.192/26`.

### Jump boxes

`jumpboxes` on a hub is an array, so a hub can carry none, one, or several. Each entry
deploys one Windows virtual machine into `snet-jumpbox` through
`infra/modules/jumpbox.bicep`. A jump box has **no public IP**; the only way in is Bastion,
and the jump box NSG admits RDP and SSH only from `AzureBastionSubnet`.

Only `name` is required. It is used verbatim as both the Azure resource name and the Windows
computer name, so it is capped at 15 characters.

```bicep
jumpboxes: [
  {
    name: 'vm-jb-cus-01'
  }
]
```

#### Defaults, and why

| Setting | Default | Reason |
|---|---|---|
| `vmSize` | `Standard_D4as_v7` | `Standard_B4as_v2` **does not exist in `centralus`**; the only B-series there is Arm64, and automatic guest patching is x64-only. There is no v5 D-series either. Check with `az vm list-skus -l <region> --resource-type virtualMachines` before assuming a size exists. |
| `image` | `MicrosoftWindowsServer/WindowsServer/2025-datacenter-azure-edition` | Has to satisfy two constraints at once: Generation 2 for Trusted Launch, **and** an exact publisher/offer/SKU from the [automatic guest patching supported image list](https://learn.microsoft.com/azure/virtual-machines/automatic-vm-guest-patching#supported-os-images). `2025-datacenter-g2` is Generation 2 but is **not** on that list, and deploying it with `AutomaticByPlatform` fails preflight with `InvalidParameter ... patchSettings.patchMode`. Azure Edition on an Azure VM involves **no Azure Arc** — Arc is only for hotpatching machines outside Azure — and carries no licence premium. |
| `availabilityZone` | `-1` (none) | A jump box is cattle; zone pinning buys nothing. |
| `osDiskStorageAccountType` | `Premium_LRS` | |
| `adminUsername` | `azureadmin` | |
| `entraLogin` | `true` | |
| `autoShutdown` | Enabled, `1800`, `Central Standard Time` | Windows time-zone ID, so Azure handles daylight saving and 18:00 stays 18:00 local all year. |
| `bootstrap` | Enabled, the default package list | See below. |

Hardening is not optional and not parameterised: Trusted Launch (secure boot + vTPM),
`encryptionAtHost`, managed boot diagnostics, and `AutomaticByPlatform` patching and
assessment. Hotpatching stays off — on Windows Server 2025 it is a separately-enrolled paid
per-core subscription, and the Azure Edition image is used here for its patching support, not
for hotpatch.

`bypassPlatformSafetyChecksOnUserSchedule` is pinned to `false`. AVM defaults it to `true`,
and when it is `true` Azure treats patching as customer-scheduled and installs nothing on its
own. That is indistinguishable from working automatic patching right up until nothing has been
patched.

#### Signing in

Entra ID, through Bastion. The AAD Login extension is installed and the VM gets a
system-assigned managed identity.

One manual step is required per person, because the deployment identity holds **Contributor
only** and deliberately not `User Access Administrator`, so the template cannot create role
assignments:

```bash
az role assignment create \
  --role "Virtual Machine Administrator Login" \
  --assignee <user-object-id-or-upn> \
  --scope /subscriptions/<sub>/resourceGroups/RG-CONNECTIVITY-HUB-CUS
```

`Virtual Machine User Login` is the non-administrator equivalent.

#### The local account, and break-glass

There is a local administrator account, and **nobody knows its password, by design.** The
password parameter defaults to a value built from `newGuid()`, so it is generated at
deployment time, never printed, and never stored.

This is a deliberate retreat from the original design, which kept the password in Key Vault.
That is not possible here: the `MCAPSGovDeployPolicies` assignment forces
`publicNetworkAccess: Disabled` on a vault and nulls its `networkAcls`, which breaks both
hand-seeding a secret and ARM's deployment-time `getSecret()` reference. It is the same class
of failure that removed OpenTofu from this repository. A vault was created, tested, and purged
before this was settled — do not re-propose it without solving the policy problem first.

If Entra sign-in is unavailable, reset the local account instead. This needs only Contributor:

```bash
az vm user update \
  --resource-group RG-CONNECTIVITY-HUB-CUS \
  --name vm-jb-cus-01 \
  --username azureadmin \
  --password '<a new strong password>'
```

Every deployment generates a **different** password and sends it in the VM PUT. This was
verified against a real redeployment: Azure ignores the changed `adminPassword` on an existing
VM, the deployment succeeds, and the account's actual password is unchanged. Practically, that
means a redeploy does not quietly rotate the break-glass password out from under a reset.

#### Bootstrap

`infra/scripts/jumpbox-bootstrap.ps1` is embedded with `loadTextContent()` and run by a
`Microsoft.Compute/virtualMachines/runCommands` child resource. It is a **documented
raw-resource exception**: the AVM VM module exposes `extensionCustomScriptConfig` only, which
wants the script staged in a storage account — blocked by the same policy that killed the
vault. The run command takes the script inline, so nothing has to be staged anywhere.

It installs Chocolatey, then the `packages` list, then the Bicep CLI via `az bicep install`
and the Az PowerShell module from the PowerShell Gallery. Defaults: `azure-cli`, `git`, `gh`,
`microsoft-windows-terminal`, `vscode`, `powershell-core`, `sqlserver-cmdlineutils`,
`microsoft-edge`, `googlechrome`. Override `bootstrap.packages` to change the list.

The script re-runs on every deployment and is written to be idempotent — Chocolatey is
installed only when absent, and `choco upgrade` both installs a missing package and updates an
existing one. Packages are installed one at a time on purpose: a single batched `choco upgrade`
aborts on the first failure, which would mean one unavailable package costs every later tool.

**Docker is deliberately absent.** Docker CE is a Linux product, the Windows Server runtime is
Mirantis, and Docker Desktop needs Hyper-V with nested virtualisation. If Docker turns out to
matter, the fix is a `vmSize` change in the parameter file to a size that supports nested
virtualisation, not a template change.

### Runners subnet

`snet-runners` in `spoke-runners-wu3` hosts the Azure Container Apps workload profile
environment that runs the self-hosted GitHub Actions runners. See
[Self-hosted runners](#self-hosted-runners) below.

It is in **West US 3, not Central US**. Container Apps repeatedly failed to get capacity in
`centralus` — `ManagedEnvironmentCapacityHeavyUsageError` — which is what forced the spoke to
exist. It is also the correct placement on its own merits: a hub is a connectivity landing
zone and should not host workload compute.

- Delegation to `Microsoft.App/environments` is mandatory for a workload profile environment,
  and the subnet is dedicated to it.
- A /26 leaves 50 usable addresses after the 14 Container Apps reserves — up to 25 dedicated
  workload profile nodes or 250 consumption replicas. It is oversized on purpose: **an
  environment's subnet cannot be resized once the environment exists**, so growing later means
  rebuilding the environment.
- Its NSG rules come from `infra/runner-nsg-rules.bicep`, imported by `main.bicepparam`. They
  state the Container Apps outbound requirements explicitly, plus HTTPS to the internet for
  GitHub, at priorities 200–280. No deny rule is added: the platform default rules already
  block inbound from the internet.
- A route table sends `0.0.0.0/0` to the hub firewall, so every runner's outbound traffic
  leaves from one static, allow-listable address, and traffic to the Central US private
  endpoints transits the hub. **Only a workload profile environment honours a user-defined
  route**, which is why `container-apps-environment.bicep` must keep its Consumption workload
  profile.
- `privatelink.westus3.azurecontainerapps.io` is in
  `additionalPrivateLinkPrivateDnsZonesToInclude`, because the zone catalog resolves
  `{regionName}` from the root `location` parameter only.

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

## Shared platform services

`main.bicepparam` defines a `platform` block that lands in an ordinary spoke —
`spoke-platform-cus` — rather than in the hub, so the hub stays connectivity-only. It holds
the three things everything else in the repository depends on:

| Resource | Network posture |
|---|---|
| Log Analytics workspace | Public endpoint. There is no Azure Monitor Private Link Scope. |
| Key Vault | Private endpoint only, RBAC authorization, purge protection on. |
| Container registry (Premium) | Private endpoint, plus a narrow public allow list. |

`platform.spokeName` supplies the subscription, resource group and region, so none of them is
restated. A name that matches no spoke fails with a null-reference error, the same way
`spoke.hubName` does.

### Why the vault and registry names are derived

Key Vault and container registry names share **one namespace across every Azure tenant**, so a
readable name like `kv-platform-cus` is as likely as not already taken by a stranger — when this
was written, that exact vault name was free and `acrplatformcus` was not.

Both names are therefore derived rather than chosen:

| Resource | Pattern | Constraint being satisfied |
|---|---|---|
| Key Vault | `kv-<platform name>-<suffix>` | ≤ 24 chars, alphanumerics and hyphens, no `--` |
| Registry | `acr<platform name><suffix>` | ≤ 50 chars, lowercase alphanumerics only, no hyphens |

The suffix is `take(uniqueString(subscription().id, platform.name), 6)`. It is stable for a given
subscription and platform stamp, so redeploying never renames a resource, while a second region
or subscription gets its own name with no parameter change. This matters more for the vault than
it first appears: purge protection holds a deleted name for the whole soft-delete window, so a
collision is not something a rename gets you out of.

Setting `keyVault.name` or `containerRegistry.name` overrides the derivation, which is there for
adopting a resource that already exists. Read the names Azure actually assigned from the
`platform` deployment output rather than reconstructing them by hand.

### Why the workspace is a separate module

`modules/log-analytics.bicep` exists only because of deployment ordering, and splitting it out
is what makes the rest possible. Every hub and spoke resource sends diagnostics to the
workspace, so the workspace must exist **before** they are created — a diagnostic setting
naming a workspace that does not yet exist fails the deployment. The Key Vault and the
registry need a spoke subnet and a Private DNS zone, which only exist **after** the networks
are built. One module could not satisfy both orderings.

### Why the workspace is public

There is no AMPLS. Adding one does not simply "lock down" ingestion: an Azure Monitor Private
Link Scope silently stops accepting data from every resource outside the scope rather than
failing loudly, which is a much worse failure mode than a public ingestion endpoint that still
requires Entra authentication.

### Registry network posture

The registry is Premium with a private endpoint, and its public endpoint is set to *Selected
networks* with `networkRuleBypassAllowedForTasks` on and the `AzureContainerRegistry.CentralUS`
service tag prefixes allowed.

That is not an oversight. `az acr build` runs on Microsoft-managed ACR Tasks compute outside
the virtual network, and a registry with `publicNetworkAccess: Disabled` rejects it outright.
Since the runner image has to be built before any runner exists to build it, ACR Tasks is the
only way to produce the first image — the allow list is what lets it push. Runners themselves
always pull over the private endpoint.

Refresh the prefixes when Azure changes them:

```powershell
az network list-service-tags --location centralus `
  --query "values[?name=='AzureContainerRegistry.CentralUS'].properties.addressPrefixes | [0]"
```

That allow list is load-bearing rather than belt-and-braces. `networkRuleBypassAllowedForTasks`
is set by the template, but the platform **silently drops it** — it reads back as `null` after a
successful deployment, with no error. The IP prefixes are what actually admit ACR Tasks today.
Verify with:

```powershell
az resource show --ids <registry resource ID> --api-version 2025-04-01 `
  --query "properties.networkRuleBypassAllowedForTasks"
```

### Why exports are not disabled

`exportPolicyStatus` stays `enabled`. Azure rejects disabling it with
`DisableExport_PublicNetworkAccessMustBeDisabled` unless `publicNetworkAccess` is also
`Disabled`, and the section above is the reason that is not an option. The two settings are
mutually exclusive, so the choice is between disabled exports and a buildable first image.

This is a narrow loss. The network rules are what restrict who can reach the registry at all;
the export policy would only have stopped an already-authorized principal copying artifacts out.
The VNet-injected agent pool follow-up below would let both be tightened together.

**Hardening follow-up:** a dedicated VNet-injected ACR Tasks agent pool would remove the public
allow list entirely, and with it the export-policy compromise. It is a Premium feature and a
separate piece of work.

## Diagnostics

Every AVM module that exposes `diagnosticSettings` is pointed at the shared workspace:
NSGs, virtual networks, the Bastion host, every public IP, Key Vault, the container registry
and the Container Apps environment. Turning it on or off is one decision — omit `platform`, or
set `platform.logAnalytics.enabled` to `false`, and every diagnostic setting disappears rather
than pointing at nothing.

Two resources are **not** covered:

- **Firewall public IPs.** Diagnostics are attached to the firewall itself, which is where
  rule hits and denials show up. Its public IPs carry no separate diagnostic setting.
- **Jump box guest logs.** A diagnostic setting carries platform logs only. Windows event logs
  and performance counters need the Azure Monitor Agent plus a Data Collection Rule, which this
  repository does not deploy. `avm/res/compute/virtual-machine` exposes
  `extensionMonitoringAgentConfig` with `dataCollectionRuleAssociations`, so it is a contained
  addition when it is wanted.

The Container Apps environment uses `appLogsConfiguration: { destination: 'azure-monitor' }`
rather than `log-analytics`. The `log-analytics` variant needs the workspace customer ID and
its **shared key**, which the AVM retrieves with `listKeys` — that is exactly the kind of
key-based access this repository does not use anywhere else. The `azure-monitor` destination
carries no credential and routes through an ordinary diagnostic setting instead.

## Self-hosted runners

Self-hosted GitHub Actions runners run as **event-driven Container Apps jobs** on the
Consumption workload profile, in `snet-runners` in `spoke-runners-wu3` (West US 3). A KEDA `github-runner` scale rule
polls GitHub for queued workflow jobs and starts a replica per job; idle jobs scale to zero and
cost nothing.

### One job per repository

This is forced, not chosen. GitHub self-hosted runners exist at repository, organisation and
enterprise scope. On a personal account there is no organisation scope, so a runner
registration targets exactly one repository — and the KEDA scaler does not tell a replica which
repository queued the work, so a shared job cannot be made correct.

Onboarding repository N+1 is therefore:

1. Select the repository in the GitHub App installation.
2. Add one entry to `githubRunners` in `main.bicepparam`, or run the **Onboard runner
   repository** workflow, which writes that entry and opens a pull request.

Nothing else changes. `installationId` is not repeated per repository, because a GitHub App
has one installation per account covering every repository selected in it.

> A free GitHub organisation would collapse this to a single org-scoped job for all
> repositories. It is a reasonable future change and needs no redesign — the job module would
> take an org scope instead of a repo scope.

### Authentication

A GitHub App, not personal access tokens. One credential to rotate rather than one per
repository, and the key never leaves Azure:

1. The KEDA scaler signs an App JWT with the key to read the workflow queue.
2. The container entrypoint signs its own JWT, exchanges it for an installation token, then
   for a **single-use runner registration token**.

The key is a Key Vault secret reference on the job, resolved with the runner's user-assigned
managed identity. Resolution happens from the environment's subnet, so the private-endpoint-only
vault is reachable. The URI is versionless, so rotating the secret needs no redeployment.

### Ephemeral is not optional

Runners register with `--ephemeral`: GitHub deregisters them after a single job and the
container exits. A reused runner keeps the previous job's working directory, environment and
credentials, so one workflow could read another's secrets. The entrypoint also removes the
registration on exit, because Azure stopping a replica at `replicaTimeout` would otherwise
leave offline runners to accumulate.

### Only private repositories

A self-hosted runner attached to a public repository executes code from any fork, on your
network, behind your hub firewall. The container holds the runner managed identity, which can
read the GitHub App private key from Key Vault — and that key controls every runner, not just
the one that leaked it. Never list a public repository in `githubRunners`.

"Nobody contributes to my repositories" is not a mitigation. Anyone can fork a public
repository and open a pull request without your involvement. GitHub's first-time-contributor
approval gate helps, but it is a human decision repeated forever, not a boundary.

`onboard-runner.yml` enforces this: it reads the target repository with the workflow token and
fails outright if it proves to be public. A private repository on the same account returns 404
to that token, so it cannot be positively confirmed and is reported rather than approved.

Note that needing a virtual network runner is a separate question from being allowed one. A
repository whose deployments only reach public Azure control-plane endpoints — this one, for
instance — runs perfectly well on `ubuntu-latest`. Virtual network runners earn their cost on
repositories that have to reach private endpoints.

### Prerequisite: your own access to the vault

The vault uses Azure RBAC, so **Owner or Contributor on the subscription grants no access to
secrets**. Seeding the App key fails with a 403 until the human doing it holds a data-plane
role. Grant it once:

```powershell
az role assignment create `
  --assignee-object-id (az ad signed-in-user show --query id -o tsv) `
  --assignee-principal-type User `
  --role "Key Vault Secrets Officer" `
  --scope <vault resource ID>
```

This cannot be done by the deployment: the identity's constrained RBAC grant permits only
`AcrPull` and `Key Vault Secrets User`, and deliberately not an officer role that could write
secrets. It is a one-time human step, like the bootstrap itself.

### What the image can and cannot do

`images/github-runner/` builds the image with ACR Tasks. It carries git and git-lfs, the Azure
CLI with Bicep, the GitHub CLI, Node.js, Python, jq, openssl and shellcheck, and gives the
`runner` account passwordless sudo.

It **cannot run Docker**. A Container Apps job cannot run a container inside the container, so
workflows on these runners must not use `docker build`, any action declaring `runs: docker`, or
`jobs.<id>.services` service containers. Image builds go through ACR Tasks.

The image pins a runner version and runs with `--disableupdate`, and GitHub refuses connections
from runners roughly 30 days behind. `build-runner-image.yml` therefore rebuilds weekly; that
schedule is load-bearing, not housekeeping.

### Manual steps

One click, once.

1. **Create the GitHub App** by running `.github/scripts/create_github_app.py`. It uses GitHub's
   [App manifest flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest):
   it serves a local page that posts a prefilled manifest to GitHub, so the permissions
   (*Actions: read*, *Administration: write*, *Metadata: read*) and the disabled webhook are
   already set and there is no form to fill in. The only interaction is clicking **Create
   GitHub App**.

   Do not register the App by hand through *Settings → Developer settings → New GitHub App*.
   That form demands a callback URL and does not expose the webhook *Active* checkbox in the
   same way, and it makes you download and handle the private key yourself.

   The script catches GitHub's redirect and exchanges the temporary code at
   `POST /app-manifests/{code}/conversions`, which returns the App ID **and** the generated
   private key. Pass `--key-vault` to write the key straight into Key Vault; otherwise it is
   written to a local file that must be seeded into the vault and then deleted.

2. **Install the App** on the private repositories that should get runners, via
   `https://github.com/apps/<app-slug>/installations/new`. Choose *Only select repositories*,
   never *All repositories*: the App holds `Administration: write`.

Put the App ID and the installation ID into `githubApp` in `main.bicepparam`; neither is a
secret.

#### Seeding the private key into the vault

The vault is private-endpoint-only, so neither a laptop nor the `ubuntu-latest` CD runner can
reach it. The jump box can, and it does not need an interactive Bastion session to be used: its
system-assigned identity plus `az vm run-command` reaches it through the Azure control plane.
Grant that identity `Key Vault Secrets Officer` on the vault once, then run a script on the VM
that takes a token from IMDS and `PUT`s the secret over the Key Vault REST API.

Set the secret metadata at the same time, because it does not default to anything useful:

| Attribute | Value | Why |
|---|---|---|
| `contentType` | `application/x-pem-file` | The key is PKCS#1 PEM, not an opaque string. |
| `exp` | one year out | Drives `SecretNearExpiry` Event Grid events and shows the rotation date in the portal. |
| tags | `purpose`, `app`, `appId`, `rotateBy` | Ties the secret back to the App that issued it. |

An expiry is safe to set here. Key Vault documents that `exp` is informational for secrets and
that a **get** "works for not-yet-valid and expired secrets, outside the *nbf* / *exp* window",
so an expired key still resolves rather than silently breaking every runner. It is a rotation
signal, not an enforcement mechanism. Do not set `enabled: false`, which *does* block reads.

Delete any local copy of the PEM afterwards, and verify the round-trip first — compare a
SHA256 of the local file against a hash computed on the value read back out of the vault.

Once a runner exists, rotation can run on a `runs-on: self-hosted` workflow instead.

### Onboarding the next repository

Adding repository N+1 does not mean a new App, a new key, or a new installation.

A GitHub App has **one installation per account**, and that installation's repository access is
editable at any time: *Settings → Applications → Installed GitHub Apps → Configure → Repository
access*. The installation ID is a property of the installation, not of the repositories inside
it, so it does not change when the repository list does.

So onboarding is:

1. Tick the new repository in the App installation's repository access list.
2. Add an entry to `githubRunners` in `main.bicepparam` between the `// BEGIN runners` and
   `// END runners` markers, or run the `onboard-runner.yml` workflow, which edits that block
   for you and refuses public repositories.

`githubApp.applicationId`, `githubApp.installationId` and the vault secret all stay as they
are. One key covers every repository the App is installed on, which is the reason this uses an
App rather than N personal access tokens.

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

Two quirks in `avm/res/compute/virtual-machine` `0.22.3` are worked around in
`infra/modules/jumpbox.bicep`, both verified against real deployments:

- The `managedIdentities` documentation claims the system-assigned identity is enabled
  automatically when `extensionAadJoinConfig.enabled` is true. It is not. The whole `identity`
  block is emitted only when `managedIdentities` is non-empty, so without it the VM deploys
  with no identity at all while the AAD Login extension still reports `Succeeded` — Entra
  sign-in then silently does not work. `managedIdentities: { systemAssigned: true }` is passed
  explicitly.
- `autoShutdownConfig.notificationSettings.status` is built from the **schedule** status, not
  the notification status. Passing `notificationSettings: { status: 'Disabled' }` therefore
  enables notifications with an empty recipient, and the deployment fails with
  `MissingRequiredProperties: One of the following properties must be specified: webhookUrl,
  emailRecipient.` The property is omitted entirely instead.

## Validation

```powershell
az bicep build --file infra/main.bicep
az bicep build-params --file infra/main.bicepparam
```

Both are compile-time checks. Two classes of defect survive them, so neither is sufficient on
its own:

- **Preflight rejections.** `SecurityRuleDescriptionTooLong`, `FirewallPolicyHigherTierOnly
  Properties` and AVM parameter type mismatches all build cleanly and fail at deploy time.
- **`what-if` short-circuits nested deployments past a batch of ten**
  (`NestedDeploymentShortCircuited`), and this template exceeds that. The Container Apps
  environment and the runner jobs are routinely skipped, so **`what-if` cannot see the part of
  the template most likely to break.**

### Subscription targeting

Point the CLI at a different subscription and confirm the plan is unchanged — see
[Subscription targeting](#subscription-targeting). Any `Create` against the active subscription
means a module has lost its explicit scope.

### Runner smoke test

Nothing in the build validates that traffic actually reaches anything. The runner platform is
verified by
[`runner-smoke-test.yml`](https://github.com/christopherhouse/Secure-Integration-Environment/blob/main/.github/workflows/runner-smoke-test.yml)
in the onboarded repository, which asserts rather than prints:

| Assertion | What it proves |
|---|---|
| Egress IP equals the hub firewall's public IP | The spoke UDR, cross-region peering, the firewall and its allow-list all work. Only traffic routed through the firewall can leave with that address. |
| ACR and Key Vault FQDNs resolve to `10.1.16.x` | Private DNS zone links and the hub peering resolve the Central US private endpoints from West US 3. |
| `actions/checkout`, `az`, `gh`, `node`, `bicep` run | The image is usable for real work. |

The container's own IP is **not** asserted. Container Apps places containers on an internal pod
overlay (`100.100.0.0/16`), not on the runner subnet — the subnet backs the environment's nodes.
An assertion on `10.2.0.x` fails against healthy infrastructure.

Run it by pushing to its branch, or with `workflow_dispatch`. A cold start is roughly a minute:
KEDA polls for the queued job, then the node pulls the image before the runner registers.
