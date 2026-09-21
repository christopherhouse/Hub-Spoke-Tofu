targetScope = 'resourceGroup'

import { jumpboxImageType, jumpboxAutoShutdownType, jumpboxBootstrapType } from '../types.bicep'

// Management jump box for a hub.
//
// It has no public IP. Inbound reaches it only through Azure Bastion, and the jump box subnet
// NSG - created in hub.bicep - already admits RDP and SSH from `AzureBastionSubnet` alone.
// Outbound leaves through the hub NAT gateway, so downloads come from one static,
// allow-listable address rather than an ephemeral default-outbound one.
//
// The local administrator password is deliberately unknowable. Azure requires one to create a
// Windows virtual machine, so one is generated at deployment time and then discarded: it is
// never a parameter, never stored, and never an output.
//
// A key vault was the obvious home for it and does not work here. The MCAPSGovDeployPolicies
// assignment forces `publicNetworkAccess: Disabled` on every vault, exactly as it does on
// storage accounts - the constraint that removed OpenTofu from this repository. A vault in
// that state is reachable only over a private endpoint, which rules out both seeding a secret
// by hand and resolving a deployment-time secret reference, so the vault would be a
// dependency nobody could populate.
//
// What replaces it:
//   - ordinary sign-in is Entra ID, through the login extension below;
//   - break-glass is a password reset through the VMAccess extension, which needs only the
//     Contributor rights the deployment identity already holds:
//
//       az vm user update -g <hub rg> -n <vm> -u azureadmin -p '<new password>'
//
// That is the documented Azure recovery path, and it means no long-lived credential for this
// virtual machine exists anywhere to be leaked or rotated.

@description('Required. Name of the virtual machine, used verbatim as the Windows computer name too. Capped at the 15-character NetBIOS limit.')
@minLength(1)
@maxLength(15)
param name string

@description('Optional. Azure region for the jump box. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Required. Resource ID of the subnet the network interface attaches to. This is the hub jump box subnet, whose NSG already restricts inbound to Bastion.')
@minLength(1)
param subnetResourceId string

@description('Optional. Name of the local administrator account. Defaults to `azureadmin`. Its password is generated at deployment time and never stored; reset it with `az vm user update` if it is ever needed.')
@minLength(1)
@maxLength(20)
param adminUsername string = 'azureadmin'

@description('Optional. Local administrator password. Do not supply one: the default generates a value that no person or system ever sees, which is the point. Azure requires a password to create a Windows virtual machine, and `newGuid()` is only legal in a parameter default, which is why this is a parameter at all.')
@secure()
@minLength(12)
param adminPassword string = '${toUpper(substring(newGuid(), 0, 6))}${substring(newGuid(), 24, 12)}#7aZ'

@description('Optional. Virtual machine size. Defaults to `Standard_D4as_v7`.')
@minLength(1)
param vmSize string = 'Standard_D4as_v7'

@description('Optional. Availability zone, or `-1` for none. Defaults to `-1`.')
@allowed([
  -1
  1
  2
  3
])
param availabilityZone int = -1

// The SKU is not arbitrary. Two constraints have to hold at once:
//
//   * Trusted Launch needs a Generation 2 image, which rules out `2025-datacenter`.
//   * Automatic guest patching is supported only on an exact publisher/offer/SKU combination
//     from the Microsoft list. `2025-datacenter-g2`, the obvious Generation 2 desktop SKU, is
//     NOT on it, and deploying it with `patchMode: 'AutomaticByPlatform'` fails preflight with
//     `InvalidParameter ... windowsConfiguration.patchSettings.patchMode`. Verified against a
//     real deployment on 2026-09-21.
//
// `2025-datacenter-azure-edition` satisfies both: Generation 2, desktop experience, and on the
// supported patching list. Azure Edition on an Azure VM does not involve Azure Arc — Arc is
// only for hotpatching machines outside Azure — and carries no licence premium. Hotpatching is
// the paid part, and it stays off below.
@description('Optional. Marketplace image. Defaults to Windows Server 2025 Datacenter Azure Edition, Generation 2, desktop experience. A Generation 2 SKU is required for Trusted Launch, and the SKU must also appear on the automatic guest patching supported image list.')
param image jumpboxImageType = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2025-datacenter-azure-edition'
  version: 'latest'
}

@description('Optional. OS disk size in GB. Defaults to the image default.')
@minValue(30)
@maxValue(4095)
param osDiskSizeGB int?

@description('Optional. OS disk storage type. Defaults to `Premium_LRS`.')
param osDiskStorageAccountType string = 'Premium_LRS'

@description('Optional. Install the Entra ID login extension. Defaults to `true`. Sign-in additionally needs a `Virtual Machine Administrator Login` or `Virtual Machine User Login` role assignment, which this deployment cannot create.')
param entraLogin bool = true

@description('Optional. Enable accelerated networking. Defaults to `false`; not every size supports it, and a jump box is not throughput-bound.')
param enableAcceleratedNetworking bool = false

@description('Optional. Auto-shutdown schedule. Defaults to 18:00 Central, daily.')
param autoShutdown jumpboxAutoShutdownType = {}

@description('Optional. First-boot tooling. Defaults to the standard platform-engineering package set.')
param bootstrap jumpboxBootstrapType = {}

@description('Optional. Tags applied to the jump box and its network interface.')
param tags object?

@description('Optional. Enable or disable Azure Verified Module telemetry.')
param enableTelemetry bool = true

var autoShutdownEnabled = autoShutdown.?enabled ?? true
var bootstrapEnabled = bootstrap.?enabled ?? true

// Chocolatey package IDs. Windows Server ships no package manager, and WinGet is not present
// on Server 2025 either, so Chocolatey carries the list. Az PowerShell is deliberately absent:
// it is installed from the PowerShell Gallery, its first-party source.
//
// Docker is deliberately not here. Docker CE is a Linux product, the Windows runtime is
// Mirantis, and Docker Desktop needs Hyper-V with nested virtualisation - which no burstable
// size supports. If containers become a requirement, change `vmSize` to a size that advertises
// `NestedVirtualizationSupported` and add the package; no template change is needed.
var defaultBootstrapPackages = [
  'azure-cli'
  'git'
  'gh'
  'microsoft-windows-terminal'
  'vscode'
  'powershell-core'
  'sqlserver-cmdlineutils'
  'microsoft-edge'
  'googlechrome'
]

var bootstrapPackages = bootstrap.?packages ?? defaultBootstrapPackages

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'deploy-jumpbox-${uniqueString(name)}'
  params: {
    name: name
    computerName: name
    location: location
    tags: tags
    enableTelemetry: enableTelemetry
    vmSize: vmSize
    availabilityZone: availabilityZone
    osType: 'Windows'
    imageReference: image
    adminUsername: adminUsername
    adminPassword: adminPassword

    osDisk: {
      name: 'osdisk-${name}'
      diskSizeGB: osDiskSizeGB
      caching: 'ReadWrite'
      createOption: 'FromImage'
      // The OS disk is worthless without the virtual machine, and a jump box is rebuilt from
      // this template rather than recovered.
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: osDiskStorageAccountType
      }
    }

    // No public IP, by design. Bastion is the only inbound path, and the subnet NSG admits
    // RDP and SSH from `AzureBastionSubnet` alone. The NSG stays on the subnet rather than the
    // NIC so one rule set covers every jump box.
    nicConfigurations: [
      {
        name: 'nic-${name}'
        enableAcceleratedNetworking: enableAcceleratedNetworking
        deleteOption: 'Delete'
        tags: tags
        enableTelemetry: enableTelemetry
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetResourceId
            privateIPAllocationMethod: 'Dynamic'
          }
        ]
      }
    ]

    // Trusted Launch. Secure boot and vTPM need `securityType` set, and both require a
    // Generation 2 image, which is why the default image SKU carries the `-g2` suffix.
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true

    // Encrypts the OS disk, the temp disk and the caches at the host rather than in the guest.
    // The subscription needs the `EncryptionAtHost` feature registered on Microsoft.Compute;
    // preflight fails without it, and `what-if` does not surface that.
    encryptionAtHost: true

    // Managed boot diagnostics: `bootDiagnostics` with no storage account name uses the
    // platform-managed account. A customer storage account would be forced to
    // `publicNetworkAccess: Disabled` by the MCAPSGovDeployPolicies assignment, which breaks
    // the serial console and screenshot that boot diagnostics exist to provide.
    bootDiagnostics: true

    // Fully automatic patching. `bypassPlatformSafetyChecksOnUserSchedule` has to be false:
    // when it is true, Azure treats patching as customer-scheduled and installs nothing on its
    // own, which looks identical to automatic patching right up until nothing is patched.
    patchMode: 'AutomaticByPlatform'
    patchAssessmentMode: 'AutomaticByPlatform'
    enableAutomaticUpdates: true
    bypassPlatformSafetyChecksOnUserSchedule: false
    rebootSetting: 'IfRequired'
    // Hotpatching on Windows Server 2025 Azure Edition is a paid per-core subscription that has
    // to be enrolled in separately, so it stays off; ordinary patching reboots instead. The
    // Azure Edition image is used for its patching support, not for hotpatch.
    enableHotpatching: false

    // Required for Entra ID sign-in. The module's documentation claims the system-assigned
    // identity "will automatically be enabled if extensionAadJoinConfig.enabled", but in
    // 0.22.3 the whole `identity` block is emitted only when `managedIdentities` is non-empty,
    // so without this the VM deploys with no identity at all and the AAD Login extension
    // reports Succeeded while Entra sign-in silently does not work. Verified on a real
    // deployment, 2026-09-21.
    managedIdentities: {
      systemAssigned: true
    }

    // Entra ID sign-in. It removes the need to hand out the local account, but a
    // `Virtual Machine Administrator Login` or `Virtual Machine User Login` role assignment is
    // still required per user, and this deployment cannot create role assignments.
    extensionAadJoinConfig: {
      enabled: entraLogin
      typeHandlerVersion: '2.2'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: false
    }

    // Deallocates on a schedule, so a jump box costs compute only while it is in use. The time
    // zone is a Windows ID and covers daylight saving, so 18:00 stays 18:00 local all year.
    autoShutdownConfig: autoShutdownEnabled
      ? {
          status: 'Enabled'
          dailyRecurrenceTime: autoShutdown.?time ?? '1800'
          timeZone: autoShutdown.?timeZone ?? 'Central Standard Time'
          // `notificationSettings` is deliberately omitted rather than set to
          // `{ status: 'Disabled' }`. In AVM virtual-machine 0.22.3 the module builds
          // `notificationSettings.status` from the *schedule* status, not from the
          // notification status, so supplying the property at all sets notifications to
          // 'Enabled' with an empty recipient and the deployment fails with
          // `MissingRequiredProperties: One of the following properties must be specified:
          // webhookUrl, emailRecipient.` Leaving it out makes the module emit a null, which
          // is what "no shutdown notification" actually means.
        }
      : {
          status: 'Disabled'
        }
  }
}

// Referenced rather than created: the virtual machine belongs to the AVM module above, and a
// run command has to be its child.
resource virtualMachineResource 'Microsoft.Compute/virtualMachines@2024-11-01' existing = {
  name: name
  dependsOn: [
    virtualMachine
  ]
}

// Raw resource exception.
//
// AVM catalog checked 2026-09-21. avm/res/compute/virtual-machine:0.9.0 exposes first-boot
// scripting only through `extensionCustomScriptConfig`, whose `fileData` expects the script to
// be staged in a storage account or at a public URI. Staging it would mean a storage account
// that the MCAPSGovDeployPolicies assignment forces to `publicNetworkAccess: Disabled` - the
// same constraint that removed OpenTofu from this repository - and the run command extension
// exists precisely to avoid that. There is no avm/res/compute/virtual-machine/run-command
// module in the public registry.
//
// Re-evaluate on the next AVM upgrade: replace this if the module gains inline script support
// or a run command child module is published.
//
// The script is embedded at build time with loadTextContent, so what deploys is exactly what
// is reviewed in the repository. It re-runs on every deployment and is written to be
// idempotent.
resource bootstrapRunCommand 'Microsoft.Compute/virtualMachines/runCommands@2024-11-01' = if (bootstrapEnabled) {
  name: 'bootstrap'
  parent: virtualMachineResource
  location: location
  tags: tags
  properties: {
    source: {
      script: loadTextContent('../scripts/jumpbox-bootstrap.ps1')
    }
    parameters: [
      {
        name: 'Packages'
        value: join(bootstrapPackages, ',')
      }
      {
        name: 'InstallAzPowerShell'
        value: string(bootstrap.?installAzPowerShell ?? true)
      }
    ]
    // Synchronous, so a failed bootstrap fails the deployment instead of leaving a jump box
    // that looks healthy and has no tooling on it.
    asyncExecution: false
    timeoutInSeconds: bootstrap.?timeoutInSeconds ?? 3600
    treatFailureAsDeploymentFailure: true
  }
}

@description('Resource ID of the jump box virtual machine.')
output resourceId string = virtualMachine.outputs.resourceId

@description('Name of the jump box virtual machine, which is also its Windows computer name.')
output name string = virtualMachine.outputs.name

@description('Object ID of the system-assigned managed identity, which the Entra ID login extension requires.')
output systemAssignedMIPrincipalId string = virtualMachine.outputs.?systemAssignedMIPrincipalId ?? ''

@description('Private IP address of the jump box. This is the address to connect to through Bastion.')
output privateIPAddress string = virtualMachine.outputs.nicConfigurations[0].ipConfigurations[0].?privateIP ?? ''
