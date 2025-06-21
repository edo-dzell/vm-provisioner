<#
.SYNOPSIS
  Erstellt und konfiguriert eine VM auf Hyper-V mithilfe von DSC v3.
  Generation 2, Secure Boot, Unattended-Setup via Mini-ISO.

.EXAMPLE
  pwsh scripts\Apply-Lab.ps1 -CustomerYaml data\customers\OBS.yml -Role DC
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CustomerYaml,
    [Parameter(Mandatory)][ValidateSet('DC','RDS')][string] $Role
)

# ---------------------------------------------------------
# Resolve -CustomerYaml to an absolute path
# ---------------------------------------------------------
if (-not (Test-Path $CustomerYaml)) {
    # 1) versuchen: src\data\customers\<Dateiname>
    $candidate = Join-Path $PSScriptRoot "..\src\data\customers\$CustomerYaml"
    if (Test-Path $candidate) {
        $CustomerYaml = (Resolve-Path $candidate).Path
    }
    else {
        throw "Kundendatei '$CustomerYaml' nicht gefunden. Erwartet wird ein Pfad oder Dateiname unter src\data\customers."
    }
}

# --- Schutz gegen versehentliches Template -------------------------------
if ($CustomerYaml -like '*template.yml') {
    throw "Bitte kopiere 'template.yml' zuerst in eine kunden­eigene Datei und passe die Werte an."
}

# --- Basismodule ---------------------------------------------------------
Import-Module powershell-yaml  -ErrorAction Stop
Import-Module Microsoft.PowerShell.Security

# --- Daten einlesen ------------------------------------------------------
$customer   = ConvertFrom-Yaml (Get-Content $CustomerYaml -Raw)
$profiles   = ConvertFrom-Yaml (Get-Content "$PSScriptRoot\..\src\data\profiles.yaml" -Raw)
$isoIndex   = Get-Content "$PSScriptRoot\..\src\data\iso-index.json" | ConvertFrom-Json

$roleInfo   = $customer.roles.$Role
$profile    = $profiles[$Role -eq 'DC' ? 'DomainController' : 'RdsSessionHost']

# --- Hostname & Pfade ----------------------------------------------------
$hostname      = '{0}{1:D3}{2}' -f $customer.prefix, $roleInfo.number, $Role
$vmRoot        = "C:\VMs\$hostname"
$vhdPath       = "$vmRoot\$hostname.vhdx"
$unattendIso   = "$vmRoot\Unattend.iso"
$installIso    = $isoIndex.WindowsServer2025.$($roleInfo.lang)

# --- Prüfen, ob OS-Install-ISO existiert ---------------------------------
if (-not (Test-Path $installIso)) {
    throw "Installations-ISO '$installIso' nicht gefunden."
}

# --- Unattend.xml rendern ------------------------------------------------
$template = Get-Content "$PSScriptRoot\..\src\templates\Unattend.xml" -Raw
$replace  = @{
    Lang          = $roleInfo.lang
    Prefix        = $customer.prefix
    Hostname      = $hostname
    AdminPassword = 'Passw0rd!'    # TODO: geheim verwalten
}
foreach ($k in $replace.Keys) { $template = $template -replace "\$\{$k\}", $replace[$k] }

# --- Mini-ISO erstellen --------------------------------------------------
function New-MinIso {
    param(
        [Parameter(Mandatory)][string] $XmlContent,
        [Parameter(Mandatory)][string] $IsoPath
    )
    $temp = Join-Path $env:TEMP "attend_$([guid]::NewGuid())"
    New-Item $temp -ItemType Directory | Out-Null
    $XmlContent | Set-Content "$temp\Autounattend.xml" -Encoding UTF8

    $oscd = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits" -Filter oscdimg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscd) { throw "oscdimg.exe nicht gefunden – installiere das Windows ADK!" }

    & $oscd -o -u2 -udfver102 $temp $IsoPath | Out-Null
    Remove-Item $temp -Recurse -Force
}

New-Item $vmRoot -ItemType Directory -Force | Out-Null
New-MinIso -XmlContent $template -IsoPath $unattendIso

# --- DSC-YAML rendern ----------------------------------------------------
$dscYaml = Get-Content "$PSScriptRoot\..\src\DSC\configs\00-NewVM.yaml" -Raw
$map = @{
    Hostname      = $hostname
    MemoryBytes   = ($profile.memoryMB * 1MB)
    CPU           = $profile.cpu
    VhdPath       = $vhdPath
    DiskBytes     = ($profile.disks[0].sizeGB * 1GB)
    IsoPath       = $installIso
    UnattendIso   = $unattendIso
}
foreach ($k in $map.Keys) { $dscYaml = $dscYaml -replace "\$\{$k\}", $map[$k] }
$dscFile = Join-Path $env:TEMP "$hostname-dsc.yaml"
$dscYaml | Set-Content $dscFile

# --- DSC anwenden & VM starten -------------------------------------------
dsc config set --file $dscFile
Start-VM -Name $hostname

Write-Host "VM '$hostname' erstellt und gestartet."
