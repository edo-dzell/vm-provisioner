<#
  Hyper-V-VM-Provisioning – konsolidierte Fassung (2-ISO-Methode)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $CustomerYaml,
    [Parameter(Mandatory)][ValidateSet('DC','RDS')] [string] $Role
)

# ─────────── Kunden-YAML finden ───────────────────────────────────────────
if (-not (Test-Path $CustomerYaml)) {
    $probe = Join-Path $PSScriptRoot "..\src\data\customers\$CustomerYaml"
    if (Test-Path $probe) { $CustomerYaml = (Resolve-Path $probe).Path }
    else { throw "Kundendatei '$CustomerYaml' nicht gefunden." }
}
if ($CustomerYaml -like '*template.yml') { throw "Bitte erst Vorlage kopieren." }

# ─────────── Module & Daten laden ─────────────────────────────────────────
Import-Module powershell-yaml -ErrorAction Stop
Import-Module Hyper-V        -ErrorAction Stop

$customer   = (Get-Content $CustomerYaml -Raw) | ConvertFrom-Yaml
$profiles   = (Get-Content "$PSScriptRoot\..\src\data\profiles.yaml" -Raw) | ConvertFrom-Yaml
$isoMap     =  Get-Content "$PSScriptRoot\..\src\data\iso-index.json" | ConvertFrom-Json

$profileKey = ($Role -eq 'DC') ? 'DomainController' : 'RdsSessionHost'
$profile    = $profiles.$profileKey
$roleInfo   = $customer.roles.$Role

# ─────────── Hostname & Pfade ─────────────────────────────────────────────
$hostname = ('{0}{1:D3}{2}' -f $customer.prefix, $roleInfo.number, $Role).Substring(0,15)

$basePath = $customer.basePath ?? $profile.basePath ?? (Get-VMHost).VirtualMachinePath
if (-not (Test-Path (Split-Path $basePath -Qualifier))) {
    Write-Warning "Laufwerk '$basePath' fehlt – benutze %ProgramData%\Hyper-V"
    $basePath = Join-Path $env:ProgramData 'Hyper-V'
}

$vmRoot   = Join-Path $basePath $hostname
$vhdPath  = Join-Path $vmRoot  "$hostname.vhdx"
$miniIso  = Join-Path $vmRoot  "Unattend.iso"

# Edition / GUI → Index + Original-ISO
$lang = $roleInfo.lang
$ed   = $roleInfo.edition   ?? 'Standard'     # Standard / Datacenter
$gui  = $roleInfo.gui       ?  'Gui' : 'Core' # true/false
$key  = "$ed$gui"                             # z. B. DatacenterGui

$isoInfo   = $isoMap.WindowsServer2025.$lang.$key
$installIso= $isoInfo.iso
$imageIndex= $isoInfo.index

if (-not (Test-Path $installIso)) { throw "Installations-ISO '$installIso' nicht gefunden." }
New-Item $vmRoot -ItemType Directory -Force | Out-Null

# ─────────── Autounattend-Mini-ISO bauen ─────────────────────────────────
$template = Get-Content "$PSScriptRoot\..\src\templates\Unattend.xml" -Raw

$place = @{
    Lang          = $lang
    Prefix        = $customer.prefix
    Hostname      = $hostname
    AdminPassword = $customer.adminPassword
    Diagnostics   = $customer.diagnostics
    ImageIndex    = $imageIndex
    IpAddress     = $roleInfo.ip.address
    Gateway       = $roleInfo.ip.gateway
    Dns1          = $roleInfo.ip.dns
}

foreach ($kv in $place.GetEnumerator()) {
    $template = $template -replace ([regex]::Escape('$'+'{'+$kv.Key+'}')), $kv.Value
}

function New-MiniIso ($Xml,$IsoPath) {
    $tmp = Join-Path $env:TEMP "mini_$(New-Guid)"
    New-Item $tmp -ItemType Directory | Out-Null
    $Xml | Set-Content "$tmp\Autounattend.xml" -Encoding UTF8
    $oscd = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Filter oscdimg.exe -Recurse |
            Select-Object -First 1 -ExpandProperty FullName
    & $oscd -o -u2 -udfver102 $tmp $IsoPath | Out-Null
    Remove-Item $tmp -Recurse -Force
}
New-MiniIso $template $miniIso

# ─────────── VM anlegen ──────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess($hostname,'Create Hyper-V VM')) {

    $vmSwitch = $customer.switch ?? $profile.switch ?? 'S2DSwitch'

    New-VM -Name $hostname `
           -Generation 2 `
           -MemoryStartupBytes ($profile.memoryMB * 1MB) `
           -Path $vmRoot `
           -NewVHDPath $vhdPath `
           -NewVHDSizeBytes ($profile.disks[0].sizeGB * 1GB) `
           -SwitchName $vmSwitch | Out-Null

    Set-VMProcessor -VMName $hostname -Count $profile.cpu `
        -ExposeVirtualizationExtensions ($profile.nested)

    if ($profile.dynamicMemory) {
        Set-VMMemory -VMName $hostname -DynamicMemoryEnabled $true `
          -MinimumBytes ($profile.memoryMinMB*1MB) -MaximumBytes ($profile.memoryMaxMB*1MB)
    } else {
        Set-VMMemory -VMName $hostname -DynamicMemoryEnabled $false `
          -StartupBytes ($profile.memoryMB*1MB)
    }

    Set-VMFirmware -VMName $hostname -EnableSecureBoot ($profile.secureBoot?'On':'Off')
    if ($profile.tpm) {
        Set-VMKeyProtector -VMName $hostname -NewLocalKeyProtector
        Enable-VMTPM -VMName $hostname
    }

    # DVD-0 = Mini-ISO  |  DVD-1 = Install-ISO
    $dvd0 = Get-VMDvdDrive -VMName $hostname -ErrorAction SilentlyContinue
    if ($dvd0) { Set-VMDvdDrive -VMName $hostname -Path $miniIso }
    else       { $dvd0 = Add-VMDvdDrive -VMName $hostname -Path $miniIso }

    Add-VMDvdDrive -VMName $hostname -Path $installIso | Out-Null
    Set-VMFirmware -VMName $hostname -FirstBootDevice $dvd0

    if ($customer.vlanEnable) {
        Set-VMNetworkAdapterVlan -VMName $hostname -Access -VlanId $customer.vlanId
    }

    foreach ($svc in $profile.integrationServices.GetEnumerator()) {
        $is = Get-VMIntegrationService -VMName $hostname -Name $svc.Key
        if ($is) {
            if ($svc.Value -and -not $is.Enabled) { Enable-VMIntegrationService $is }
            elseif (-not $svc.Value -and $is.Enabled) { Disable-VMIntegrationService $is }
        }
    }

    Set-VM -VMName $hostname `
      -AutomaticStartAction $profile.autoStartAction `
      -AutomaticStartDelay  $profile.autoStartDelay `
      -AutomaticStopAction  $profile.autoStopAction

    Start-VM -Name $hostname
    Write-Host "VM '$hostname' wurde erstellt und gestartet." -ForegroundColor Green
}
