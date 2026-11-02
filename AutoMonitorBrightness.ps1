Param (
    $Location,
    $MaxBrightness,
    $MinBrightness
)
$ErrorActionPreference = 'Stop'

function Write-Log {
    Param ([string]$Message, [string]$Level = 'INFO')
    $Colors = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }
    Write-Host ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(5), $Message) -ForegroundColor $Colors[$Level]
}

function Get-Setting([string]$Name, [string]$Default = '') {
    # 读注册表中的值而不是 $env:，这样运行期间用 setx 修改也能读到；顺序为用户变量、系统变量、当前进程
    $Value = [Environment]::GetEnvironmentVariable($Name, 'User')
    if (!$Value) { $Value = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    if (!$Value) { $Value = [Environment]::GetEnvironmentVariable($Name) }
    if (!$Value) { $Value = $Default }
    return $Value
}

function Get-SettingInt([string]$Name, [int]$Default) {
    $Text = Get-Setting $Name ([string]$Default)
    $Value = 0
    if ([int]::TryParse($Text, [ref]$Value)) {
        return $Value
    }
    Write-Log "环境变量 $Name 的值 '$Text' 不是有效数字，使用 $Default" 'WARN'
    return $Default
}

function Read-Settings($Bound) {
    # 显式传入的参数优先，其余每轮从环境变量重新读取
    if (!$Bound.ContainsKey('Location')) { $script:Location = [string](Get-Setting 'AMB_LOCATION') }
    if (!$Bound.ContainsKey('MaxBrightness')) { $script:MaxBrightness = Get-SettingInt 'AMB_MAX_BRIGHTNESS' 100 }
    if (!$Bound.ContainsKey('MinBrightness')) { $script:MinBrightness = Get-SettingInt 'AMB_MIN_BRIGHTNESS' 0 }
}

Write-Log 'AutoMonitorBrightness 启动'
Read-Settings $PSBoundParameters
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

function Get-CurrentBrightness {
    # 返回 实例名 -> 当前亮度 的哈希表；读不到时返回 $null（例如合盖后内屏断电）
    try {
        $Monitors = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop)
    }
    catch {
        Write-Log "读取当前亮度失败: $($_.Exception.Message)" 'WARN'
        return $null
    }
    $Values = @{}
    foreach ($Monitor in $Monitors) {
        if (($Monitor.Active -ne $false) -and ($null -ne $Monitor.CurrentBrightness)) {
            $Values[$Monitor.InstanceName] = [int]$Monitor.CurrentBrightness
        }
    }
    if ($Values.Count -eq 0) {
        Write-Log '没有读到可用的当前亮度（可能处于合盖或屏幕关闭状态）' 'WARN'
        return $null
    }
    return $Values
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

    # 每轮重新读取环境变量，运行期间 setx 修改也能及时生效
    $OldLocation = $Location
    $OldMaxBrightness = $MaxBrightness
    $OldMinBrightness = $MinBrightness
    Read-Settings $PSBoundParameters
    if ($Location -ne $OldLocation) {
        Write-Log "查询位置已更新: '$OldLocation' -> '$Location'" 'OK'
        # 位置变了，立即重新查天气，不用等到下个整点
        $LastFetchStamp = $null
    }
    if (($MaxBrightness -ne $OldMaxBrightness) -or ($MinBrightness -ne $OldMinBrightness)) {
        Write-Log "亮度范围已更新: $OldMinBrightness - $OldMaxBrightness -> $MinBrightness - $MaxBrightness" 'OK'
    }

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
        $CurrentBrightness = Get-CurrentBrightness
        if ($null -ne $CurrentBrightness) {
            # 能读到实际亮度时按实际值判断，避免手动调整后被覆盖或重复写入
            $Mismatched = @($CurrentBrightness.GetEnumerator() | Where-Object { $_.Value -ne $Brightness })
            if ($Mismatched.Count -eq 0) {
                Write-Log "当前亮度已是目标 $Brightness，无需调整"
                $LastBrightness = @($CurrentBrightness.Values)[0]
            }
            else {
                $Detail = ($Mismatched | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Value }) -join '; '
                Write-Log "当前亮度与目标 $Brightness 不符（$Detail）"
                try {
                    Set-Brightness $Brightness
                    # 上次亮度记录设置后查询到的实际值，而不是目标值
                    $Applied = Get-CurrentBrightness
                    if ($null -ne $Applied) {
                        $LastBrightness = @($Applied.Values)[0]
                    }
                    else {
                        $LastBrightness = $Brightness
                    }
                }
                catch {
                    Write-Log "亮度设置失败: $($_.Exception.Message)" 'ERROR'
                    # 设置失败视为未执行，清空记录，下一轮必定重试
                    $LastBrightness = $null
                }
            }
        }
        else {
            # 读不到实际亮度时退回按目标变化判断，避免反复无效写入
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
                    # 设置失败视为未执行，清空记录，下一轮必定重试
                    $LastBrightness = $null
                }
            }
            else {
                Write-Log "读不到当前亮度，沿用上次目标 $Brightness，无需调整"
            }
        }
    }
    else {
        Write-Log '当天暂无可用天气数据，本次跳过亮度调整' 'WARN'
    }

    Start-Sleep -Seconds 60
}
