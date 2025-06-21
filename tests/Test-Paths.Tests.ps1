BeforeAll {
    $root = "$PSScriptRoot\..\src\data"
}
Describe 'ISO paths valid' {
    It 'All ISO files exist' {
        $iso = Get-Content "$root\iso-index.json" | ConvertFrom-Json
        $iso.WindowsServer2025 | Get-Member -MemberType NoteProperty | ForEach-Object {
            Test-Path $iso.WindowsServer2025.$($_.Name) | Should -BeTrue
        }
    }
}
