schtasks /Delete /TN '\star2000\AutoMonitorBrightness' /F
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$env:ALLUSERSPROFILE\AutoMonitorBrightness.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item "$env:ALLUSERSPROFILE\AutoMonitorBrightness.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ALLUSERSPROFILE\AutoMonitorBrightness.count" -Force -ErrorAction SilentlyContinue
