param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$dest    = Join-Path $env:LOCALAPPDATA 'Programs\MagicWand'
$links   = @((Join-Path ([Environment]::GetFolderPath('Startup')) 'MagicWand.lnk'),
             (Join-Path ([Environment]::GetFolderPath('Programs')) 'MagicWand.lnk'))

# stop a running copy
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*MagicWand.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if ($Uninstall) {
    $links | Where-Object { Test-Path $_ } | Remove-Item
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Write-Host 'MagicWand removed.'
    return
}

[void](New-Item -ItemType Directory -Force $dest)
Copy-Item (Join-Path $PSScriptRoot 'MagicWand.ps1') $dest -Force
$script = Join-Path $dest 'MagicWand.ps1'
$shell = New-Object -ComObject WScript.Shell
foreach ($l in $links) {
    $s = $shell.CreateShortcut($l)
    $s.TargetPath = "$env:WINDIR\System32\conhost.exe"
    $s.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script`""
    $s.WorkingDirectory = $dest
    $s.IconLocation = "$env:WINDIR\System32\shell32.dll,43"
    $s.Description = 'Select text anywhere, click the wand, get the answer'
    $s.Save()
}
Start-Process $links[0]
Write-Host "MagicWand installed to $dest and started (it also starts with Windows)."
