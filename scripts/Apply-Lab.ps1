<#
  Hyper-V-VM-Provisioning – finale bereinigte Fassung
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $CustomerYaml,
    [Parameter(Mandatory)][ValidateSet('DC','RDS')] [string] $Role
)

#──────────────── Pfad zur Kunden-YAML auflösen ────────────────
if (-not (Test-Path $CustomerYaml)) {
    $probe = Join-Path $PSScriptRoot "..\src\data\customers\$CustomerYaml"
    if (Test-Path $probe) { $CustomerYaml = (Resolve-Path $probe).Path }
    else { throw "Kundendatei '$CustomerYaml' nicht gefunden." }
}
if ($CustomerYaml -like '*template.yml') {
    throw "Bitte zuerst template.yml kopieren & anpassen!"
}

#──────────────── Module & Daten laden ─────────────────────────
Import-Module powershell-yaml -ErrorAction Stop
Import-Module Hyper-V        -ErrorAction Stop

$customer   = (Get-Content $CustomerYaml -Raw) | ConvertFrom-Yaml
$profiles   = (Get-Content "$PSScriptRoot\..\src\data\profiles.yaml" -Raw) | ConvertFrom-Yaml
$isoIndex   =  Get-Content "$PSScriptRoot\..\src\data\iso-index.json"      | ConvertFrom-Json

$profileKey = ($Role -eq 'DC') ? 'DomainController' : 'RdsSessionHost'
$profile    = $profiles.$profileKey
$roleInfo   = $customer.roles.$Role

#──────────────── Hostname & Basispfad ─────────────────────────
$hostname = '{0}{1:D3}{2}' -f $customer.prefix, $roleInfo.number, $Role
$basePath = if     ($customer.basePath) { $customer.basePath }
            elseif ($profile.basePath)  { $profile.basePath  }
            else                        { (Get-VMHost).VirtualMachinePath }

#  ➜  Laufwerk validieren
if (-not (Test-Path (Split-Path $basePath -Qualifier))) {
    Write-Warning "Laufwerk '$basePath' existiert nicht – fallback zu %ProgramData%\Hyper-V"
    $basePath = Join-Path $env:ProgramData 'Hyper-V'
}

$vmRoot     = Join-Path $basePath $hostname
$vhdPath    = Join-Path $vmRoot  "$hostname.vhdx"
$installIso = $isoIndex.WindowsServer2025.$($roleInfo.lang)
$unattIso   = Join-Path $vmRoot 'Unattend.iso'

if (-not (Test-Path $installIso)) { throw "Installations-ISO '$installIso' nicht gefunden." }
New-Item $vmRoot -ItemType Directory -Force | Out-Null

#──────────────── Unattended-ISO bauen ─────────────────────────
$templatePath = "$PSScriptRoot\..\src\templates\Unattend.xml"
$template     = Get-Content $templatePath -Raw

# Platzhalter → echte Werte
$placeholders = @{
    Lang          = $roleInfo.lang
    Prefix        = $customer.prefix
    Hostname      = $hostname
    AdminPassword = 'Passw0rd!'     # TODO: geheim verwalten
}

foreach ($kv in $placeholders.GetEnumerator()) {
    # \$\{Lang\}  usw. – 100 % exakter Treffer, kein RegEx-Sonderzeichen
    $pattern  = [regex]::Escape('$' + '{' + $kv.Key + '}')
    $template = $template -replace $pattern, $kv.Value
}

# ----------------------------------------------------------------
# bis hierhin ist $template nun komplett ohne ${...}-Platzhalter!
# ----------------------------------------------------------------

function New-MinIso ([string]$Xml,[string]$Iso) {
    $tmp = Join-Path $env:TEMP "unatt_$(New-Guid)"
    New-Item $tmp -ItemType Directory | Out-Null
    $Xml | Set-Content "$tmp\Autounattend.xml" -Encoding UTF8

    $oscd = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits" -Filter oscdimg.exe -Recurse |
            Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscd) { throw "oscdimg.exe (ADK) fehlt." }

    & $oscd -o -u2 -udfver102 $tmp $Iso | Out-Null
    Remove-Item $tmp -Recurse -Force
}

New-MinIso -Xml $template -Iso $unattIso


#──────────────── VM anlegen ───────────────────────────────────
if ($PSCmdlet.ShouldProcess($hostname,'Create Hyper-V VM')) {

    $vmSwitch = if     ($customer.switch) { $customer.switch }
                elseif ($profile.switch)  { $profile.switch  }
                else                      { 'S2DSwitch' }

    New-VM -Name $hostname `
           -Generation 2 `
           -MemoryStartupBytes ($profile.memoryMB * 1MB) `
           -Path            $vmRoot `
           -NewVHDPath      $vhdPath `
           -NewVHDSizeBytes ($profile.disks[0].sizeGB * 1GB) `
           -SwitchName      $vmSwitch | Out-Null

    # CPU & Nested
    Set-VMProcessor -VMName $hostname -Count $profile.cpu `
        -ExposeVirtualizationExtensions ($profile.nested)

    # RAM-Konfiguration
    if ($profile.dynamicMemory) {
        Set-VMMemory -VMName $hostname -DynamicMemoryEnabled $true `
            -MinimumBytes ($profile.memoryMinMB * 1MB) `
            -MaximumBytes ($profile.memoryMaxMB * 1MB)
    } else {
        Set-VMMemory -VMName $hostname -DynamicMemoryEnabled $false `
            -StartupBytes ($profile.memoryMB * 1MB)               # ← **StartupBytes gesetzt**
    }

    # SecureBoot + TPM
    Set-VMFirmware -VMName $hostname -EnableSecureBoot ($profile.secureBoot ? 'On' : 'Off')
    if ($profile.tpm) {
        Set-VMKeyProtector -VMName $hostname -NewLocalKeyProtector
        Enable-VMTPM       -VMName $hostname
    }

    # ---------- DVD-Laufwerke sicher einrichten ----------
    # 1) Erstes (oder neues) DVD-Laufwerk für Install-ISO
    $dvd0 = Get-VMDvdDrive -VMName $hostname -ErrorAction SilentlyContinue
    if ($dvd0) {
        Set-VMDvdDrive -VMName $hostname -Path $installIso
    } else {
        $dvd0 = Add-VMDvdDrive -VMName $hostname -Path $installIso
    }

    # 2) Zweites DVD-Laufwerk für Unattend-ISO
    Add-VMDvdDrive -VMName $hostname -Path $unattIso | Out-Null

    # 3) Boot-Reihenfolge – nur FirstBootDevice setzen
    Set-VMFirmware -VMName $hostname -FirstBootDevice $dvd0

    # VLAN (optional)
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

    # AutoStart / AutoStop
    Set-VM -VMName $hostname `
        -AutomaticStartAction $profile.autoStartAction `
        -AutomaticStartDelay  $profile.autoStartDelay `
        -AutomaticStopAction  $profile.autoStopAction

    Start-VM -Name $hostname
    Write-Host "VM '$hostname' wurde erstellt und gestartet." -ForegroundColor Green
}
