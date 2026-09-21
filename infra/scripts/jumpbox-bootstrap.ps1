<#
.SYNOPSIS
    First-boot tooling for a hub jump box.

.DESCRIPTION
    Run by a Microsoft.Compute/virtualMachines/runCommands resource, as SYSTEM, on every
    deployment of infra/modules/jumpbox.bicep. It is therefore written to be idempotent:
    Chocolatey is only installed when absent, and `choco upgrade` both installs a missing
    package and updates an existing one.

    The package list is data. It arrives as a comma-separated string from the `packages`
    property of the jump box definition, so adding a tool is a .bicepparam change.

    Outbound access is through the hub NAT gateway, which gives every download a single
    static, allow-listable source address.
#>

[CmdletBinding()]
param (
    # Comma-separated Chocolatey package IDs.
    [string] $Packages = '',

    # 'true' to install the Az PowerShell module from the PowerShell Gallery.
    [string] $InstallAzPowerShell = 'true'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param ([string] $Message)
    Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

# Server 2025 negotiates TLS 1.2 by default, but the run command host can start with an older
# default in some images, and every download below is HTTPS.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Step 'Jump box bootstrap starting.'

# ---------------------------------------------------------------------------------------
# Chocolatey
# ---------------------------------------------------------------------------------------
$chocoExe = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'

if (-not (Test-Path -Path $chocoExe)) {
    Write-Step 'Installing Chocolatey.'
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
else {
    Write-Step 'Chocolatey already present.'
}

if (-not (Test-Path -Path $chocoExe)) {
    throw "Chocolatey install did not produce $chocoExe."
}

# ---------------------------------------------------------------------------------------
# Packages
#
# Installed one at a time on purpose. A single `choco upgrade a b c` aborts the whole batch
# on the first failure, which would mean one unavailable package costs every later tool. Here
# a failure is reported and the rest still land; the run command fails at the end if any did.
# ---------------------------------------------------------------------------------------
$packageList = @($Packages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$failed = @()

foreach ($package in $packageList) {
    Write-Step "Installing or upgrading '$package'."

    & $chocoExe upgrade $package --yes --no-progress --limit-output --ignore-checksums

    # 0 = success, 1641 and 3010 = success, reboot required or initiated.
    if ($LASTEXITCODE -notin @(0, 1641, 3010)) {
        Write-Step "Package '$package' failed with exit code $LASTEXITCODE."
        $failed += $package
    }
}

# ---------------------------------------------------------------------------------------
# Bicep
#
# Installed through the Azure CLI rather than as a separate package, so `az bicep` and a bare
# `bicep` call cannot end up on different versions.
# ---------------------------------------------------------------------------------------
$azCli = Join-Path ${env:ProgramFiles} 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'

if (Test-Path -Path $azCli) {
    Write-Step 'Installing or upgrading the Bicep CLI through the Azure CLI.'
    & $azCli bicep install
    if ($LASTEXITCODE -ne 0) {
        & $azCli bicep upgrade
    }
}
else {
    Write-Step 'Azure CLI not found; skipping the Bicep CLI.'
}

# ---------------------------------------------------------------------------------------
# Az PowerShell
#
# From the PowerShell Gallery, which is its first-party source. Installed for all users so it
# is available to whoever signs in, not just to SYSTEM.
# ---------------------------------------------------------------------------------------
if ($InstallAzPowerShell -eq 'true') {
    if (Get-Module -ListAvailable -Name Az.Accounts) {
        Write-Step 'Az PowerShell already present.'
    }
    else {
        Write-Step 'Installing the Az PowerShell module.'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module -Name Az -Scope AllUsers -Repository PSGallery -Force -AllowClobber
    }
}

# ---------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------
if ($failed.Count -gt 0) {
    throw ("Bootstrap finished with failed packages: {0}" -f ($failed -join ', '))
}

Write-Step ("Jump box bootstrap complete. {0} package(s) processed." -f $packageList.Count)
