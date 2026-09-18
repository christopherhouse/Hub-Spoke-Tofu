[CmdletBinding(DefaultParameterSetName = 'CreateResourceGroup')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]$StorageAccountName,

    # Mandatory so the region is always a deliberate choice rather than a silent default.
    [Parameter(Mandatory = $true, ParameterSetName = 'CreateResourceGroup')]
    [string]$Location,

    # The existing resource group supplies the region, so -Location does not apply.
    [Parameter(Mandatory = $true, ParameterSetName = 'ExistingResourceGroup')]
    [switch]$UseExistingResourceGroup,

    # Constrained to Azure's resource group charset, which also keeps generated HCL safe.
    [ValidatePattern('^[a-zA-Z0-9_().-]{1,89}[a-zA-Z0-9_()-]$')]
    [string]$ResourceGroupName = 'rg-tofu-state',

    [ValidateScript({
        $_.Length -ge 3 -and
        $_.Length -le 63 -and
        $_ -match '^[a-z0-9][a-z0-9-]*[a-z0-9]$' -and
        $_ -notmatch '--'
    })]
    [string]$ContainerName = 'tfstate',

    [ValidateSet('LRS', 'ZRS', 'GRS', 'GZRS')]
    [string]$ReplicationType = 'ZRS',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string[]]$PrincipalObjectId,

    [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name exited with code $LASTEXITCODE."
    }
}

function ConvertTo-HclValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return '[]'
        }

        $items = $Value | ForEach-Object { ConvertTo-HclValue -Value $_ }
        return '[' + ($items -join ', ') + ']'
    }

    # Every string input is validated by the parameter block, but escape defensively
    # so a value can never break out of the quoted HCL string.
    $escaped = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function ConvertTo-HclVarsFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Variables
    )

    $width = ($Variables.Keys | Measure-Object -Property Length -Maximum).Maximum
    $lines = foreach ($key in $Variables.Keys) {
        '{0} = {1}' -f $key.PadRight($width), (ConvertTo-HclValue -Value $Variables[$key])
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    # Windows PowerShell 5.1 `Set-Content -Encoding UTF8` emits a BOM, which the
    # OpenTofu JSON and HCL parsers reject. Write UTF-8 without a BOM instead.
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

foreach ($command in @('az', 'tofu')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found on PATH."
    }
}

Invoke-NativeCommand -Name 'az' -Arguments @('account', 'show', '--output', 'none')
Invoke-NativeCommand -Name 'az' -Arguments @('account', 'set', '--subscription', $SubscriptionId)

# Validate the region against the subscription so a typo fails before anything is deployed.
if ($PSCmdlet.ParameterSetName -eq 'CreateResourceGroup') {
    $availableLocations = @(
        & az account list-locations --query '[].name' --output tsv |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    if ($LASTEXITCODE -ne 0 -or $availableLocations.Count -eq 0) {
        throw 'Unable to list available Azure regions for the subscription.'
    }

    if ($availableLocations -notcontains $Location) {
        throw "Location '$Location' is not available in subscription $SubscriptionId. List valid regions with: az account list-locations --query '[].name' --output tsv"
    }
}

if (-not $PrincipalObjectId -or $PrincipalObjectId.Count -eq 0) {
    $resolvedObjectId = & az ad signed-in-user show --query id --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedObjectId)) {
        throw 'Unable to resolve the signed-in user object ID. Supply -PrincipalObjectId explicitly.'
    }

    $PrincipalObjectId = @($resolvedObjectId.Trim())
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$variablesPath = Join-Path $scriptRoot 'bootstrap.tfvars'
$planPath = Join-Path $scriptRoot 'bootstrap.tfplan'
$backendPath = Join-Path $scriptRoot 'backend.generated.hcl'

$variables = [ordered]@{
    subscription_id            = $SubscriptionId
    create_resource_group      = -not $UseExistingResourceGroup.IsPresent
    location                   = if ($UseExistingResourceGroup) { $null } else { $Location }
    resource_group_name        = $ResourceGroupName
    storage_account_name       = $StorageAccountName
    container_name             = $ContainerName
    replication_type           = $ReplicationType
    state_principal_object_ids = @($PrincipalObjectId)
}

Write-Utf8NoBom -Path $variablesPath -Content (ConvertTo-HclVarsFile -Variables $variables)

Push-Location $scriptRoot
try {
    Invoke-NativeCommand -Name 'tofu' -Arguments @('fmt', '-check', '-recursive')
    Invoke-NativeCommand -Name 'tofu' -Arguments @('init')
    Invoke-NativeCommand -Name 'tofu' -Arguments @('validate')
    Invoke-NativeCommand -Name 'tofu' -Arguments @('plan', '-var-file', 'bootstrap.tfvars', '-out', $planPath)

    if ($AutoApprove) {
        Invoke-NativeCommand -Name 'tofu' -Arguments @('apply', '-auto-approve', $planPath)
    }
    else {
        Invoke-NativeCommand -Name 'tofu' -Arguments @('apply', $planPath)
    }

    $backend = @"
resource_group_name  = "$ResourceGroupName"
storage_account_name = "$StorageAccountName"
container_name       = "$ContainerName"
use_azuread_auth     = true
use_oidc             = true
"@

    Write-Utf8NoBom -Path $backendPath -Content $backend

    Write-Host ''
    Write-Host "State storage bootstrap completed."
    Write-Host "Backend configuration: $backendPath"
    Write-Host 'Keep bootstrap/terraform.tfstate secure; it remains the source of truth for these bootstrap resources.'
}
finally {
    Pop-Location
}
