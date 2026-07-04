$ErrorActionPreference = 'Stop'

if ($Host.Version.Major -ge 3) {
    Register-ScheduledTask AutoMonitorBrightness star2000 (
        New-ScheduledTaskAction wscript AutoMonitorBrightness.vbs %ALLUSERSPROFILE%
    ) (
        New-ScheduledTaskTrigger -Once -At 6am -RepetitionInterval (New-TimeSpan -Hours 1)
    ) (
        New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RunOnlyIfNetworkAvailable -StartWhenAvailable
    ) -Force | Out-Null
}
else {
    $Xml = "$env:TMP\AutoMonitorBrightness.xml"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072;
    (New-Object Net.WebClient).DownloadFile('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/AutoMonitorBrightness.xml', $Xml)
    schtasks /Create /XML $Xml /TN '\star2000\AutoMonitorBrightness' /F
    Remove-Item $Xml -Force
}

@'
CreateObject("WScript.Shell").Run "powershell -NoProfile -NonInteractive ""[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; (New-Object Net.WebClient).DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/AutoMonitorBrightness.ps1') | iex""",0
'@ > "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs"

schtasks /Run /TN '\star2000\AutoMonitorBrightness'
