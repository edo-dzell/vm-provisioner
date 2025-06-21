@"
# VM Provisioner

PowerShell 7 + DSC v3 basiertes Framework …
"@ | Out-File README.md -Encoding utf8 -Force


Kurzanleitung
-------------

1. Kopiere _data/customers/template.yml_ → _customer.yml_ (oder Kundenpräfix).
2. Fülle VLAN, IP, Sprache usw. aus.
3. Starte Provisionierung:

   ```powershell
   pwsh scripts\Apply-Lab.ps1 `
        -CustomerYaml data\customers\OBS.yml `
        -Role DC