Param (
    $Location = $env:AMB_LOCATION,
    $MaxBrightness = [int]$($env:AMB_MAX_BRIGHTNESS, 100 | Select-Object -First 1),
    $MinBrightness = [int]$($env:AMB_MIN_BRIGHTNESS, 0 | Select-Object -First 1)
)
$ErrorActionPreference = 'Stop'

function Write-Log {
    Param ([string]$Message, [string]$Level = 'INFO')
    $Colors = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    Write-Host ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(5), $Message) -ForegroundColor $Colors[$Level]
}

Write-Log 'AutoMonitorBrightness 启动'
if ($Location) {
    Write-Log "配置的查询位置: $Location"
}
else {
    Write-Log '未配置查询位置，每次查询天气前会重新定位' 'WARN'
}
Write-Log "亮度范围: $MinBrightness - $MaxBrightness"

# 保证只有一个常驻进程
$Mutex = New-Object Threading.Mutex($false, 'AutoMonitorBrightness')
if (-not $Mutex.WaitOne(0)) {
    Write-Log '已有实例正在运行，本次退出' 'WARN'
    exit
}
Write-Log '已获取单实例锁'

function Get-CurrentLocation {
    Write-Log '正在获取系统定位（最多等待 10 秒）...'
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
        $CurrentLocation = $null
        if ($GeoWatcher.Status -eq 'Ready') {
            $GeoLocation = $GeoWatcher.Position.Location
            if (!$GeoLocation.IsUnknown) {
                $CurrentLocation = '' + $GeoLocation.Latitude + ',' + $GeoLocation.Longitude
            }
        }
        $Status = $GeoWatcher.Status
        $Permission = $GeoWatcher.Permission
        $GeoWatcher.Dispose()
        if ($CurrentLocation) {
            Write-Log "系统定位成功: $CurrentLocation" 'OK'
            return $CurrentLocation
        }
        if ($Permission -eq 'Denied') {
            Write-Log '系统定位权限被拒绝，改由 IP 推断位置' 'WARN'
        }
        else {
            Write-Log "系统定位不可用（状态: $Status），改由 IP 推断位置" 'WARN'
        }
    }
    catch {
        Write-Log "系统定位异常: $($_.Exception.Message)，改由 IP 推断位置" 'WARN'
    }
}

function Get-WeatherData {
    # 未配置位置时每次查询都重新定位，设备移动后位置会变化
    $WeatherLocation = $Location
    if (!$WeatherLocation) {
        $WeatherLocation = Get-CurrentLocation
    }
    if ($WeatherLocation) {
        Write-Log "本次使用位置: $WeatherLocation"
    }
    else {
        Write-Log '没有可用位置，直接查询 wttr.in（由其按 IP 推断）' 'WARN'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $WebClient = New-Object Net.WebClient
    $WebClient.Encoding = [Text.Encoding]::UTF8
    $WebClient.Proxy = $null
    # 20:14:28+0800|05:07:50|19:15:47|0
    $Url = "https://wttr.in/${WeatherLocation}?lang=zh&format=%T|%S|%s|%u"
    Write-Log "查询天气: $Url"
    $WeatherString = $WebClient.DownloadString($Url)
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
    $Monitors = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods)
    if ($Monitors.Count -eq 0) {
        throw '没有找到支持亮度调节的显示器'
    }
    foreach ($Monitor in $Monitors) {
        Invoke-CimMethod -InputObject $Monitor -MethodName WmiSetBrightness -Arguments @{
            Timeout    = 1
            Brightness = $Brightness
        } | Out-Null
    }
    Write-Log "已向 $($Monitors.Count) 个显示器写入亮度 $Brightness" 'OK'
}

$CountClient = New-Object Net.WebClient
$CountClient.Encoding = [Text.Encoding]::UTF8
$CountClient.Proxy = $null

$Weather = $null
$WeatherDate = $null
$LastFetchStamp = $null
$LastBrightness = $null
$CountStamp = $null

Write-Log '进入监控循环，每 60 秒检查一次亮度'

while ($true) {
    $Now = Get-Date
    $Stamp = $Now.ToString('yyyyMMddHH')

    # 启动时和每天计数一次
    $DayStamp = $Now.ToString('yyyyMMdd')
    if ($DayStamp -ne $CountStamp) {
        $CountStamp = $DayStamp
        Write-Log '上报匿名计数'
        try {
            $CountClient.DownloadString('https://cdn.jsdelivr.net/gh/star2000/count@5/count') | Out-Null
            Write-Log '计数上报成功' 'OK'
        }
        catch {
            Write-Log "计数上报失败: $($_.Exception.Message)" 'WARN'
        }
    }

    # 启动时和每个整点查询一次天气，失败就沿用当天已有的数据
    if ($Stamp -ne $LastFetchStamp) {
        $LastFetchStamp = $Stamp
        Write-Log "开始查询天气（$Stamp）"
        try {
            $Weather = Get-WeatherData
            $WeatherDate = $Now.Date
            Write-Log "天气数据: 当前 $($Weather.Time) 日出 $($Weather.Sunrise) 日落 $($Weather.Sunset) 紫外线 $($Weather.UvIndex)" 'OK'
        }
        catch {
            Write-Log "天气查询失败: $($_.Exception.Message)" 'ERROR'
            Write-Log '本次沿用当天已有的天气数据，下次整点再试' 'WARN'
        }
    }

    # 旧天气数据仅当天有效
    if ($Weather -and ($WeatherDate -eq $Now.Date)) {
        $Brightness = Get-TargetBrightness $Weather
        if (($null -eq $LastBrightness) -or ($Brightness -ne $LastBrightness)) {
            if ($null -eq $LastBrightness) {
                Write-Log "首次计算的目标亮度: $Brightness"
            }
            else {
                Write-Log "目标亮度变化: $LastBrightness -> $Brightness"
            }
            try {
                Set-Brightness $Brightness
                $LastBrightness = $Brightness
            }
            catch {
                Write-Log "亮度设置失败: $($_.Exception.Message)" 'ERROR'
            }
        }
        else {
            Write-Log "亮度保持 $Brightness，无需调整"
        }
    }
    else {
        Write-Log '当天暂无可用天气数据，本次跳过亮度调整' 'WARN'
    }

    Start-Sleep -Seconds 60
}
