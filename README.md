# VM Provisioner

PowerShell 7 + DSC v3 basierter Workflow zum automatischen Erstellen,
Installieren und Grund­konfigurieren von Hyper-V-VMs.
* Windows ADK (enthält oscdimg.exe)  
  ⇨ winget install --id Microsoft.WindowsADK -e


## Quick Start
1. Kopiere `data/customers/template.yml` ➜ `OBS.yml`, passe Werte an
2. `pwsh scripts/Apply-Lab.ps1 -CustomerYaml data/customers/OBS.yml -Role DC`
