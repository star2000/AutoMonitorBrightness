Param (
    $Location = $env:AMB_LOCATION,
    $MaxBrightness = [int]$($env:AMB_MAX_BRIGHTNESS, 100 | Select-Object -First 1),
    $MinBrightness = [int]$($env:AMB_MIN_BRIGHTNESS, 0 | Select-Object -First 1)
)
$ErrorActionPreference = 'Stop'

# 保证只有一个常驻进程
$Mutex = New-Object Threading.Mutex($false, 'AutoMonitorBrightness')
if (-not $Mutex.WaitOne(0)) {
    exit
}

function Get-CurrentLocation {
    try {
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
                $CurrentLocation = '' + $GeoLocation.Latitude + ',' + $GeoLocation.Longitude
            }
        }
        $GeoWatcher.Dispose()
        if ($CurrentLocation) {
            return $CurrentLocation
        }
    }
    catch { }
}

function Get-WeatherData {
    # 未配置位置时每次查询都重新定位，设备移动后位置会变化
    $WeatherLocation = $Location
    if (!$WeatherLocation) {
        $WeatherLocation = Get-CurrentLocation
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $WebClient = New-Object Net.WebClient
    $WebClient.Encoding = [Text.Encoding]::UTF8
    $WebClient.Proxy = $null
    # 20:14:28+0800|05:07:50|19:15:47|0
    $WeatherString = $WebClient.DownloadString("https://wttr.in/${Location}?lang=zh&format=%T|%S|%s|%u")
    $WeatherSplit = $WeatherString.Split('|')
    [pscustomobject]@{
        Time      = [timespan]$WeatherSplit[0].Split('+')[0]
        Sunrise   = [timespan]$WeatherSplit[1]
        Sunset    = [timespan]$WeatherSplit[2]
        UvIndex   = [int]$WeatherSplit[3]
        UpdatedAt = Get-Date
    }
}

function Get-TargetBrightness($Weather) {
    # 用天气数据的时间加上已过去的时间来推进当前时间
    $Ticks = ($Weather.Time.Ticks + ((Get-Date) - $Weather.UpdatedAt).Ticks) % [timespan]::TicksPerDay
    $Time = [timespan]::FromTicks($Ticks)
    if ($Weather.Sunrise -ne $Weather.Sunset -and $Time -ge $Weather.Sunrise -and $Time -le $Weather.Sunset) {
        $MiddayTicks = ($Weather.Sunrise.Ticks + $Weather.Sunset.Ticks) / 2
        $HalfDayTicks = ($Weather.Sunset.Ticks - $Weather.Sunrise.Ticks) / 2
        $SunElevation = [Math]::Max(1 - [Math]::Abs($Time.Ticks - $MiddayTicks) / $HalfDayTicks, 0)
        $UvFactor = [Math]::Min($Weather.UvIndex / 7.5, 1)
        $TimeFactor = ([Math]::Pow($SunElevation - 1, 3) + 1) * 0.382
        $Factor = $TimeFactor * (1 + $UvFactor)
        return [int]($MinBrightness + ($MaxBrightness - $MinBrightness) * $Factor)
    }
    return $MinBrightness
}

function Set-Brightness([int]$Brightness) {
    Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods | ForEach-Object {
        Invoke-CimMethod -InputObject $_ -MethodName WmiSetBrightness -Arguments @{
            Timeout    = 1
            Brightness = $Brightness
        } | Out-Null
    }
}

$CountClient = New-Object Net.WebClient
$CountClient.Encoding = [Text.Encoding]::UTF8
$CountClient.Proxy = $null

$Weather = $null
$WeatherDate = $null
$LastFetchStamp = $null
$LastBrightness = $null
$CountStamp = $null

while ($true) {
    $Now = Get-Date
    $Stamp = $Now.ToString('yyyyMMddHH')

    # 启动时和每天计数一次
    $DayStamp = $Now.ToString('yyyyMMdd')
    if ($DayStamp -ne $CountStamp) {
        $CountStamp = $DayStamp
        try {
            $CountClient.DownloadString('https://cdn.jsdelivr.net/gh/star2000/count@5/count') | Out-Null
        }
        catch { }
    }

    # 启动时和每个整点查询一次天气，失败就沿用当天已有的数据
    if ($Stamp -ne $LastFetchStamp) {
        $LastFetchStamp = $Stamp
        try {
            $Weather = Get-WeatherData
            $WeatherDate = $Now.Date
        }
        catch { }
    }

    # 旧天气数据仅当天有效
    if ($Weather -and ($WeatherDate -eq $Now.Date)) {
        $Brightness = Get-TargetBrightness $Weather
        if (($null -eq $LastBrightness) -or ($Brightness -ne $LastBrightness)) {
            try {
                Set-Brightness $Brightness
                $LastBrightness = $Brightness
            }
            catch { }
        }
    }

    Start-Sleep -Seconds 60
}
