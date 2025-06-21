<#
.SYNOPSIS
  Erstellt und konfiguriert eine Hyper-V-VM (Generation 2) rein mit
  PowerShell-Cmdlets.  Alle Parameter (CPU, RAM, VLAN usw.) kommen aus
  profiles.yaml und <Customer>.yml.  Unattended-ISO wird on-the-fly
  erzeugt.

.EXAMPLE
  pwsh scripts\Apply-Lab.ps1 -CustomerYaml OBS.yml -Role DC -Verbose
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $CustomerYaml,

    [Parameter(Mandatory)]
    [ValidateSet('DC','RDS')]
    [string] $Role
)

#──────────────────────────────────────── Resolve Pfade ────────────────────────────────────────
if (-not (Test-Path $CustomerYaml)) {
    $alt = Join-Path $PSScriptRoot "..\src\data\customers\$CustomerYaml"
    if (Test-Path $alt) { $CustomerYaml = (Resolve-Path $alt).Path }
    else { throw "Kundendatei '$CustomerYaml' nicht gefunden." }
}
if ($CustomerYaml -like '*template.yml') {
    throw "Bitte erst 'template.yml' kopieren und anpassen!"
}

#──────────────────────────────────────── Imports / Daten ──────────────────────────────────────
Import-Module powershell-yaml -ErrorAction Stop
Import-Module Hyper-V            -ErrorAction Stop

$customer   = (Get-Content $CustomerYaml -Raw)                       | ConvertFrom-Yaml
$profiles   = (Get-Content "$PSScriptRoot\..\src\data\profiles.yaml" -Raw) | ConvertFrom-Yaml
$isoIndex   =  Get-Content "$PSScriptRoot\..\src\data\iso-index.json"      | ConvertFrom-Json

$roleInfo   =  $customer.roles.$Role
$profileKey =  ($Role -eq 'DC') ? 'DomainController' : 'RdsSessionHost'
$profile    =  $profiles.$profileKey

#──────────────────────────────────────── Hostname & Pfade ────────────────────────────────────
$hostname   = '{0}{1:D3}{2}' -f $customer.prefix, $roleInfo.number, $Role
$vmRoot     = Join-Path 'C:\VMs' $hostname
$vhdPath    = "$vmRoot\$hostname.vhdx"
$installIso = $isoIndex.WindowsServer2025.$($roleInfo.lang)
$unattIso   = "$vmRoot\Unattend.iso"

if (-not (Test-Path $installIso)) { throw "ISO '$installIso' nicht gefunden." }
New-Item $vmRoot -ItemType Directory -Force | Out-Null

#────────────────────────────────── Unattend.xml → Mini-ISO ───────────────────────────────────
$template = (Get-Content "$PSScriptRoot\..\src\templates\Unattend.xml" -Raw)
@{Lang=$roleInfo.lang; Prefix=$customer.prefix; Hostname=$hostname; AdminPassword='Passw0rd!'} |
    ForEach-Object { $template = $template -replace "\$\{$_\.Key\}", $_.Value }

function New-MinIso ($Xml, $IsoPath) {
    $tmp = Join-Path $env:TEMP "unatt_$(New-Guid)"
    New-Item $tmp -ItemType Directory | Out-Null
    $Xml | Set-Content "$tmp\Autounattend.xml" -Encoding UTF8
    $oscd = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Filter oscdimg.exe -Recurse |
            Select-Object -First 1 -Expand FullName
    if (-not $oscd) { throw "oscdimg.exe (Windows ADK) fehlt." }
    & $oscd -o -u2 -udfver102 $tmp $IsoPath | Out-Null
    Remove-Item $tmp -Recurse -Force
}
New-MinIso -Xml $template -IsoPath $unattIso

#────────────────────────────────── VM erstellen (Cmdlets) ────────────────────────────────────
if ($PSCmdlet.ShouldProcess($hostname, 'Create Hyper-V VM')) {

    # Basis-VM
    New-VM -Name $hostname -Generation 2 -MemoryStartupBytes ($profile.memoryMB*1MB) `
           -Path $vmRoot -NewVHDPath $vhdPath -NewVHDSizeBytes ($profile.disks[0].sizeGB*1GB) `
           -SwitchName 'S2DSwitch' | Out-Null

    # CPU + Nested
    Set-VMProcessor -VMName $hostname -Count $profile.cpu `
        -ExposeVirtualizationExtensions ($profile.nested)

    # Memory-Modus
    if ($profile.dynamicMemory) {
        Set-VMMemory -VMName $hostname -DynamicMemoryEnabled $true `
           -MinimumBytes ($profile.memoryMinMB*1MB) `
           -MaximumBytes ($profile.memoryMaxMB*1MB)
    } else {
        Set-VMMemory -VMName $hostname -DynamicMemoryEnabled $false
    }

    # Secure Boot & TPM
    Set-VMFirmware -VMName $hostname `
        -EnableSecureBoot ($profile.secureBoot ? 'On' : 'Off')
    if ($profile.tpm) { Enable-VMTPM -VMName $hostname }

    # DVD-Laufwerke
    Add-VMDvdDrive -VMName $hostname -Path $installIso  -ControllerLocation 0
    Add-VMDvdDrive -VMName $hostname -Path $unattIso    -ControllerLocation 1

    # Boot-Reihenfolge (optional)
    if ($customer.bootFromIsoFirst) {
        $dvd0 = Get-VMDvdDrive -VMName $hostname | Where-Object ControllerLocation -eq 0
        Set-VMFirmware -VMName $hostname -FirstBootDevice $dvd0
    }

    # VLAN
    if ($customer.vlanEnable) {
        Set-VMNetworkAdapterVlan -VMName $hostname -Access -VlanId $customer.vlanId
    }

    # Integration-Services
    foreach ($svc in $profile.integrationServices.GetEnumerator()) {
        $is = Get-VMIntegrationService -VMName $hostname -Name $svc.Key
        if ($is) {
            if ($svc.Value -and -not $is.Enabled) { Enable-VMIntegrationService $is }
            elseif (-not $svc.Value -and $is.Enabled) { Disable-VMIntegrationService $is }
        }
    }

    # AutoStart/Stop
    Set-VM -VMName $hostname `
       -AutomaticStartAction $profile.autoStartAction `
       -AutomaticStartDelay  $profile.autoStartDelay `
       -AutomaticStopAction  $profile.autoStopAction

    # Start
    Start-VM -Name $hostname
    Write-Host "VM '$hostname' wurde erstellt und gestartet." -ForegroundColor Green
}