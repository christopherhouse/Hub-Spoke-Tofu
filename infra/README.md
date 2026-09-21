# infra

Subscription-scope Bicep root for the hub-and-spoke network.

| File | Purpose |
|---|---|
| `main.bicep` | Composition root. `targetScope = 'subscription'`. |
| `main.bicepparam` | Parameter values for the current deployment. |
| `types.bicep` | Shared user-defined types (`hubType` and friends), surfaced with `@export()`. |
| `zones.bicep` | Curated Private Link DNS zone catalog, surfaced with `@export()`. |
| `modules/hub.bicep` | Hub virtual network, subnets, NSGs, Azure Bastion and the NAT gateway. Resource-group scope. |
| `modules/spoke.bicep` | Spoke virtual network, subnets, per-subnet NSGs and bidirectional peering to its hub. Resource-group scope. |
| `modules/log-analytics.bicep` | Shared Log Analytics workspace. Separate from `platform.bicep` purely for ordering. |
| `modules/platform.bicep` | Shared Key Vault, container registry and the runner managed identity, with private endpoints. |
| `modules/container-apps-environment.bicep` | Workload profile Container Apps environment in the hub runners subnet. |
| `modules/github-runner-job.bicep` | One event-driven self-hosted runner job, per repository. |

## Modules

| Module | Version |
|---|---|
| `br/public:avm/res/resources/resource-group` | `0.4.4` |
| `br/public:avm/ptn/network/private-link-private-dns-zones` | `0.7.3` |
| `br/public:avm/res/network/virtual-network` | `0.9.0` |
| `br/public:avm/res/network/network-security-group` | `0.5.3` |
| `br/public:avm/res/network/bastion-host` | `0.8.2` |
| `br/public:avm/res/network/nat-gateway` | `2.1.1` |
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
| `hubs` | No | `hubType[]`. One entry per hub. Each gets a resource group, VNet, subnets and Bastion, and is linked to every zone. |
| `spokes` | No | `spokeType[]`. One entry per spoke. Each gets a resource group, VNet, subnets, a peering to its hub, and links to every zone. |
| `virtualNetworkLinks` | No | Extra VNets to link, beyond the hubs, which are linked automatically. |
| `additionalPrivateLinkPrivateDnsZonesToInclude` | No | Extra zones beyond the curated catalog. |
| `platform` | No | `platformType`. Shared Log Analytics, Key Vault, container registry and the runner identity, landing in the spoke named by `spokeName`. |
| `containerAppsEnvironment` | No | `containerAppsEnvironmentType`. Runner environment in the runners subnet of the hub named by `hubName`. |
| `githubApp` | No | `githubAppType`. The App the runners authenticate as. Required when `githubRunners` is non-empty. |
| `githubRunners` | No | `githubRunnerType[]`. One entry per repository. Onboarding is an entry here. |
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
| `snet-runners` | `10.0.0.128/26` | Delegated to `Microsoft.App/environments`. NAT gateway attached. |
| *(reserved)* | `10.0.0.192` – `10.0.31.255` | Firewall, gateway, DNS resolver, shared services. |

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

`natGateway` on a hub attaches a NAT gateway to `snet-jumpbox` and `snet-runners`. Omit it and
those subnets fall back to Azure **default outbound access**, whose source address is implicit,
unpredictable, and impossible to allow-list — and which Azure is retiring. With the NAT
gateway, all outbound traffic from both subnets leaves through one known static public IP.

- It is only deployed when at least one of those subnets is. Outbound SNAT with no subnet
  attached would just be a billed idle resource.
- A NAT gateway is **zonal or non-zonal, never zone-redundant**. `availabilityZone` defaults
  to `-1` (non-zonal); if it is set, the public IP is created in the same zone.
- One Standard SKU static public IP is created by default. Supply `publicIpResourceIds` or
  `publicIpPrefixResourceIds` instead to keep an address that is already allow-listed, or to
  get a contiguous allow-listable range.
- It does not change inbound access. Bastion still handles that, and the jump box NSG still
  admits RDP and SSH only from `AzureBastionSubnet`.
- Attaching a NAT gateway overrides any default route to the internet for the subnet, so it
  takes precedence over a load balancer or instance-level public IP for outbound traffic.

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

`snet-runners` hosts the Azure Container Apps workload profile environment that runs the
self-hosted GitHub Actions runners. See [Self-hosted runners](#self-hosted-runners) below.

- Delegation to `Microsoft.App/environments` is mandatory for a workload profile environment,
  and the subnet is dedicated to it.
- A /26 leaves 50 usable addresses after the 14 Container Apps reserves — up to 25 dedicated
  workload profile nodes or 250 consumption replicas. It is oversized on purpose: **an
  environment's subnet cannot be resized once the environment exists**, so growing later means
  rebuilding the environment.
- Its NSG states the Container Apps outbound requirements explicitly, plus HTTPS to the
  internet for GitHub. No deny rule is added: the platform default rules already block inbound
  from the internet.
- The hub NAT gateway serves this subnet as well as the jump box subnet, so every runner's
  outbound traffic leaves from one static, allow-listable address. That is what makes it
  possible to put these runners in front of an IP-restricted endpoint later.
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

**Hardening follow-up:** a dedicated VNet-injected ACR Tasks agent pool would remove the public
allow list entirely. It is a Premium feature and a separate piece of work.

## Diagnostics

Every AVM module that exposes `diagnosticSettings` is pointed at the shared workspace:
NSGs, virtual networks, the Bastion host, every public IP, Key Vault, the container registry
and the Container Apps environment. Turning it on or off is one decision — omit `platform`, or
set `platform.logAnalytics.enabled` to `false`, and every diagnostic setting disappears rather
than pointing at nothing.

Two resources are **not** covered:

- **NAT gateway.** `avm/res/network/nat-gateway:2.1.1` has no `diagnosticSettings` parameter.
  The diagnostics are attached to its public IP instead, which is where SNAT port exhaustion
  would actually show up.
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
Consumption workload profile, in the hub's `snet-runners`. A KEDA `github-runner` scale rule
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
network, behind your NAT gateway. Never list a public repository in `githubRunners`.

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

Two, once:

1. **Create the GitHub App** on the account, with repository permissions *Actions: read*,
   *Administration: read and write* and *Metadata: read*, webhooks disabled. Install it on the
   private repositories that should get runners. Put the App ID and the installation ID into
   `githubApp` in `main.bicepparam`; neither is a secret.
2. **Paste the private key into Key Vault**, from the jump box over Bastion. The vault is
   private-endpoint-only, so neither a laptop nor the `ubuntu-latest` CD runner can reach it:

   ```powershell
   az keyvault secret set `
     --vault-name kv-platform-cus-hsiac `
     --name github-app-private-key `
     --file .\app-private-key.pem
   ```

Once a runner exists, rotation can run on a `runs-on: self-hosted` workflow instead.

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
