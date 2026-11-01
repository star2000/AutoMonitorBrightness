schtasks /Delete /TN '\star2000\AutoMonitorBrightness' /F
Remove-Item "$env:ALLUSERSPROFILE\AutoMonitorBrightness.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs" -Force -ErrorAction SilentlyContinue
