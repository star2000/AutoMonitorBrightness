$ErrorActionPreference = 'Stop'

# Windows 已弃用 VBScript，改用 PowerShell 启动常驻进程
$Launcher = "$env:ALLUSERSPROFILE\AutoMonitorBrightness.ps1"
$Legacy = "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs"
$LauncherContent = @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$WebClient = New-Object Net.WebClient
$WebClient.Encoding = [Text.Encoding]::UTF8
($WebClient.DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/AutoMonitorBrightness.ps1')) | iex
'@

Set-Content -Path $Launcher -Value $LauncherContent -Encoding ASCII

if ($Host.Version.Major -ge 3) {
    Register-ScheduledTask AutoMonitorBrightness star2000 (
        New-ScheduledTaskAction powershell.exe "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Launcher`""
    ) (
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    ) (
        New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew
    ) -Force | Out-Null
}
else {
    $Xml = "$env:TMP\AutoMonitorBrightness.xml"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072;
    (New-Object Net.WebClient).DownloadFile('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/AutoMonitorBrightness.xml', $Xml)
    schtasks /Create /XML $Xml /TN '\star2000\AutoMonitorBrightness' /F
    Remove-Item $Xml -Force
}

# 结束已在运行的旧常驻进程，让新版本生效
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$env:ALLUSERSPROFILE\AutoMonitorBrightness.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 清理旧的 VBScript 启动器
if (Test-Path $Legacy) {
    Remove-Item $Legacy -Force -ErrorAction SilentlyContinue
}

schtasks /Run /TN '\star2000\AutoMonitorBrightness'
