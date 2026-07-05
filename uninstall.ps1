schtasks /Delete /TN '\star2000\AutoMonitorBrightness' /F
Remove-Item "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs" -Force
