[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CustomerYaml,
    [Parameter(Mandatory)][ValidateSet('DC','RDS')][string]$Role
)

if ($CustomerYaml -like '*template.yml') {
    throw "Bitte kopiere 'template.yml' erst in eine kunden­eigene Datei (z. B. customer.yml) und passe die Werte an."
}

Import-Module powershell-yaml          -ErrorAction Stop
Import-Module Microsoft.PowerShell.Security

# --- Daten einlesen ---------------------------------------------------------
$customer   = ConvertFrom-Yaml (Get-Content $CustomerYaml -Raw)
$profiles   = ConvertFrom-Yaml (Get-Content "$PSScriptRoot\..\src\data\profiles.yaml" -Raw)
$isoIndex   = Get-Content "$PSScriptRoot\..\src\data\iso-index.json" | ConvertFrom-Json

$roleInfo   = $customer.roles.$Role
$profile    = $profiles["$($Role -eq 'DC' ? 'DomainController' : 'RdsSessionHost')"]

# Laufende Nummer zusammensetzen
$hostname   = "{0}{1:D3}{2}" -f $customer.prefix, $roleInfo.number, $Role

# --- Pfade & Größen ---------------------------------------------------------
$isoPath    = $isoIndex.WindowsServer2025.$($roleInfo.lang)
$vhdPath    = "C:\VMs\$hostname\$hostname.vhdx"
$floppyPath = "C:\VMs\$hostname\Autounattend.vfd"

# --- Unattend.xml rendern ---------------------------------------------------
$template = Get-Content "$PSScriptRoot\..\src\templates\Unattend.xml" -Raw
$map = @{
    Lang          = $roleInfo.lang
    Prefix        = $customer.prefix
    Hostname      = $hostname
    AdminPassword = 'Passw0rd!'           # TODO: eigenen Generator / Geheimnis
}
foreach($key in $map.Keys){
    $template = $template -replace "\$\{$key\}", [regex]::Escape($map[$key])
}

# Floppy erstellen (requires Hyper-V PowerShell cmdlets)
$null = New-Item -ItemType Directory -Path (Split-Path $floppyPath) -Force
New-VFD -Path $floppyPath -Size 1440KB
Copy-Item -Path ([IO.Path]::GetTempFileName()) -Destination $floppyPath -Force
Set-VFD -Path $floppyPath -Content $template

# --- YAML für DSC rendern ---------------------------------------------------
$dscYaml = Get-Content "$PSScriptRoot\..\src\DSC\configs\00-NewVM.yaml" -Raw
$map2 = @{
    Hostname     = $hostname
    MemoryBytes  = ($profile.memoryMB * 1MB)
    CPU          = $profile.cpu
    VhdPath      = $vhdPath
    DiskBytes    = ($profile.disks[0].sizeGB * 1GB)
    IsoPath      = $isoPath
    FloppyPath   = $floppyPath
}
foreach($key in $map2.Keys){
    $dscYaml = $dscYaml -replace "\$\{$key\}", $map2[$key]
}
$dscFile = Join-Path $env:TEMP "$hostname-dsc.yaml"
$dscYaml | Set-Content $dscFile

# --- DSC anwenden -----------------------------------------------------------
dsc config set --file $dscFile

# --- Starten & Aufräumen ----------------------------------------------------
Start-VM -Name $hostname
Write-Verbose "VM $hostname wurde gestartet. Unattend via Floppy eingehängt."
