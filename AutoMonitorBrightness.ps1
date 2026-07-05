Param (
    $Location = $env:AMB_LOCATION,
    $MaxBrightness = [int]$($env:AMB_MAX_BRIGHTNESS, 50 | Select-Object -First 1),
    $MinBrightness = [int]$($env:AMB_MIN_BRIGHTNESS, 0 | Select-Object -First 1)
)
$ErrorActionPreference = 'Stop'

if (!$Location) {
    Add-Type -AssemblyName System.Device
    $GeoWatcher = New-Object System.Device.Location.GeoCoordinateWatcher
    $GeoWatcher.Start()
    $timeout = 10
    $start = Get-Date
    while (($GeoWatcher.Status -ne 'Ready') -and ($GeoWatcher.Permission -ne 'Denied')) {
        Start-Sleep -Milliseconds 100
        if ((Get-Date) -gt $start.AddSeconds($timeout)) {
            $GeoWatcher.Stop()
            break
        }
    }
    if ($GeoWatcher.Status -eq 'Ready') {
        $GeoLocation = $GeoWatcher.Position.Location
        if (!$GeoLocation.IsUnknown) {
            $Location = '' + $GeoLocation.Latitude + ',' + $GeoLocation.Longitude
        }
    }
    $GeoWatcher.Dispose()
}

# Get weather info
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$WebClient = New-Object Net.WebClient
$WebClient.Encoding = [Text.Encoding]::UTF8
$WebClient.Proxy = $null
# 20:14:28+0800|05:07:50|19:15:47|0
$WeatherString = $WebClient.DownloadString("https://wttr.is/${Location}?lang=zh&format=%T|%S|%s|%u")
$WeatherSplit = $WeatherString.Split('|')
$Time = [timespan]$WeatherSplit[0].Split('+')[0]
$Sunrise = [timespan]$WeatherSplit[1]
$Sunset = [timespan]$WeatherSplit[2]
$UvIndex = [int]$WeatherSplit[3]

# Calculate brightness
if ($Time -ge $Sunrise -and $Time -le $Sunset) {
    $Noon = [timespan]::FromTicks(($Sunrise.Ticks + $Sunset.Ticks) / 2)
    $HalfDayTicks = ($Sunset.Ticks - $Sunrise.Ticks) / 2
    $NoonProximity = 1 - [Math]::Min([Math]::Abs(($Time - $Noon).Ticks) / $HalfDayTicks, 1.0)
    $Factor = [Math]::Min([Math]::Max($UvIndex / 10.0, $NoonProximity / 2.0), 1.0)
    $Brightness = [int]($MinBrightness + ($MaxBrightness - $MinBrightness) * $Factor)
}
else {
    $Brightness = $MinBrightness
}

# Set brightness
Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods | ForEach-Object {
    Invoke-CimMethod -InputObject $_ -MethodName WmiSetBrightness -Arguments @{
        Timeout    = 1
        Brightness = $Brightness 
    }
}

# Update link
if (Test-Path "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs") {
    @'
CreateObject("WScript.Shell").Run "powershell -NoProfile -NonInteractive ""[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; (New-Object Net.WebClient).DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/AutoMonitorBrightness.ps1') | iex""",0
'@ > "$env:ALLUSERSPROFILE\AutoMonitorBrightness.vbs"
}

# Count
$ErrorActionPreference = 'SilentlyContinue'
$WebClient.DownloadString('https://cdn.jsdelivr.net/gh/star2000/count@5/count')
