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

function Get-Coordinates([string]$LocationText) {
    # 只识别 "纬度,经度"，地名无法用于本地日出日落计算
    $Match = [regex]::Match($LocationText, '^\s*([-+]?\d+(?:\.\d+)?)\s*,\s*([-+]?\d+(?:\.\d+)?)\s*$')
    if (!$Match.Success) { return $null }
    $Latitude = [double]$Match.Groups[1].Value
    $Longitude = [double]$Match.Groups[2].Value
    if (($Latitude -lt -90) -or ($Latitude -gt 90) -or ($Longitude -lt -180) -or ($Longitude -gt 180)) {
        return $null
    }
    return [pscustomobject]@{ Latitude = $Latitude; Longitude = $Longitude }
}

function Get-SunTimes([double]$Latitude, [double]$Longitude, [datetime]$Date) {
    # NOAA 近似公式，纯本地计算，不依赖天气服务
    $BaseUtc = $Date.Date.AddHours(12).ToUniversalTime().Date
    $Gamma = 2 * [Math]::PI / 365 * ($BaseUtc.DayOfYear - 1)
    $EqTime = 229.18 * (0.000075 + 0.001868 * [Math]::Cos($Gamma) - 0.032077 * [Math]::Sin($Gamma) - 0.014615 * [Math]::Cos(2 * $Gamma) - 0.040849 * [Math]::Sin(2 * $Gamma))
    $Declination = 0.006918 - 0.399912 * [Math]::Cos($Gamma) + 0.070257 * [Math]::Sin($Gamma) - 0.006758 * [Math]::Cos(2 * $Gamma) + 0.000907 * [Math]::Sin(2 * $Gamma) - 0.002697 * [Math]::Cos(3 * $Gamma) + 0.00148 * [Math]::Sin(3 * $Gamma)
    $LatitudeRad = $Latitude * [Math]::PI / 180
    $CosHourAngle = [Math]::Cos(90.833 * [Math]::PI / 180) / ([Math]::Cos($LatitudeRad) * [Math]::Cos($Declination)) - [Math]::Tan($LatitudeRad) * [Math]::Tan($Declination)
    if ($CosHourAngle -gt 1) {
        # 极夜：太阳整天不升起
        return [pscustomobject]@{ Sunrise = [timespan]::Zero; Sunset = [timespan]::Zero; PolarDay = $false }
    }
    if ($CosHourAngle -lt -1) {
        # 极昼：太阳整天不落下
        return [pscustomobject]@{ Sunrise = [timespan]::Zero; Sunset = [timespan]::FromDays(1); PolarDay = $true }
    }
    $HourAngle = [Math]::Acos($CosHourAngle) * 180 / [Math]::PI
    $SolarNoonMinutes = 720 - 4 * $Longitude - $EqTime
    $SunriseUtc = $BaseUtc.AddMinutes($SolarNoonMinutes - 4 * $HourAngle)
    $SunsetUtc = $BaseUtc.AddMinutes($SolarNoonMinutes + 4 * $HourAngle)
    return [pscustomobject]@{
        Sunrise  = $SunriseUtc.ToLocalTime().TimeOfDay
        Sunset   = $SunsetUtc.ToLocalTime().TimeOfDay
        PolarDay = $false
    }
}

function Get-FallbackBrightness($Sun, [datetime]$Now) {
    # 天气不可用时的固定分段亮度：夜间最低、晨昏 25%、白天 50%
    if ($Sun.PolarDay) {
        return [int][Math]::Round($MinBrightness + ($MaxBrightness - $MinBrightness) * 0.5)
    }
    if ($Sun.Sunrise -eq $Sun.Sunset) {
        return $MinBrightness
    }
    $NowMinutes = $Now.TimeOfDay.TotalMinutes
    $SunriseMinutes = $Sun.Sunrise.TotalMinutes
    $SunsetMinutes = $Sun.Sunset.TotalMinutes
    $TwilightMinutes = 60
    if (($NowMinutes -ge ($SunriseMinutes + $TwilightMinutes)) -and ($NowMinutes -le ($SunsetMinutes - $TwilightMinutes))) {
        return [int][Math]::Round($MinBrightness + ($MaxBrightness - $MinBrightness) * 0.5)
    }
    if ((($NowMinutes -ge ($SunriseMinutes - $TwilightMinutes)) -and ($NowMinutes -le ($SunriseMinutes + $TwilightMinutes))) -or
        (($NowMinutes -ge ($SunsetMinutes - $TwilightMinutes)) -and ($NowMinutes -le ($SunsetMinutes + $TwilightMinutes)))) {
        return [int][Math]::Round($MinBrightness + ($MaxBrightness - $MinBrightness) * 0.25)
    }
    return $MinBrightness
}

function Get-ClockBrightness([datetime]$Now) {
    # 完全拿不到经纬度时的最后兜底：只按钟点粗分，不用系统时区反推经度
    $Minutes = $Now.TimeOfDay.TotalMinutes
    if (($Minutes -ge 420) -and ($Minutes -le 1140)) {
        return [int][Math]::Round($MinBrightness + ($MaxBrightness - $MinBrightness) * 0.5)
    }
    if ((($Minutes -ge 360) -and ($Minutes -lt 420)) -or (($Minutes -gt 1140) -and ($Minutes -le 1200))) {
        return [int][Math]::Round($MinBrightness + ($MaxBrightness - $MinBrightness) * 0.25)
    }
    return $MinBrightness
}

function Update-GeoCoords {
    # 系统定位并缓存坐标；超过刷新间隔才重新定位，笔记本移动后能跟着变
    $Expired = ($null -eq $script:GeoUpdatedAt) -or (((Get-Date) - $script:GeoUpdatedAt).TotalMinutes -ge $script:GeoRefreshMinutes)
    if ($Expired) {
        $LocationValue = Get-CurrentLocation
        $Coords = Get-Coordinates $LocationValue
        if ($Coords) {
            $script:GeoCoords = $Coords
        }
        $script:GeoUpdatedAt = Get-Date
        if ($LocationValue) { return $LocationValue }
    }
    if ($script:GeoCoords) {
        return ('{0},{1}' -f $script:GeoCoords.Latitude, $script:GeoCoords.Longitude)
    }
    return $null
}

function Get-SunContext([string]$LocationText, [datetime]$Now) {
    # 日出日落的经纬度来源：配置的经纬度优先，否则用系统定位（地名也走定位，位置会变）
    $Coords = $null
    $Source = $null
    if ($LocationText) {
        $Coords = Get-Coordinates $LocationText
        if ($Coords) { $Source = '配置的经纬度' }
    }
    if (!$Coords) {
        Update-GeoCoords | Out-Null
        if ($script:GeoCoords) {
            $Coords = $script:GeoCoords
            $Source = '系统定位'
        }
    }
    if (!$Coords) { return $null }
    return [pscustomobject]@{
        Sun       = Get-SunTimes $Coords.Latitude $Coords.Longitude $Now.Date
        Source    = $Source
        Latitude  = $Coords.Latitude
        Longitude = $Coords.Longitude
    }
}

function Get-WeatherData([string]$WeatherLocation) {
    # 现在只取紫外线指数，日出日落由本地计算
    if ($WeatherLocation) {
        Write-Log "本次使用位置: $WeatherLocation"
    }
    else {
        Write-Log '没有可用位置，直接查询 wttr.in（由其按 IP 推断）' 'WARN'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $Url = "https://wttr.in/${WeatherLocation}?lang=zh&format=%u"
    Write-Log "查询天气: $Url"
    $Request = [Net.WebRequest]::Create($Url)
    $Request.Timeout = 10000
    $Request.Proxy = $null
    $Response = $null
    try {
        $Response = $Request.GetResponse()
        if ($Response.StatusCode -ne [Net.HttpStatusCode]::OK) {
            throw "HTTP 状态码 $([int]$Response.StatusCode)"
        }
        $Reader = New-Object IO.StreamReader($Response.GetResponseStream(), [Text.Encoding]::UTF8)
        $Text = $Reader.ReadToEnd()
        $Reader.Dispose()
    }
    finally {
        if ($Response) { $Response.Close() }
    }
    $UvIndex = 0
    if (-not [int]::TryParse($Text.Trim(), [ref]$UvIndex)) {
        throw "返回内容异常: '$($Text.Trim())'"
    }
    if (($UvIndex -lt 0) -or ($UvIndex -gt 20)) {
        throw "紫外线指数超出合理范围: $UvIndex"
    }
    return [pscustomobject]@{ UvIndex = $UvIndex; UpdatedAt = Get-Date }
}

function Get-TargetBrightness($Sun, [int]$UvIndex, [datetime]$Now) {
    $Time = $Now.TimeOfDay
    if ($Sun.Sunrise -ne $Sun.Sunset -and $Time -ge $Sun.Sunrise -and $Time -le $Sun.Sunset) {
        $MiddayTicks = ($Sun.Sunrise.Ticks + $Sun.Sunset.Ticks) / 2
        $HalfDayTicks = ($Sun.Sunset.Ticks - $Sun.Sunrise.Ticks) / 2
        $SunElevation = [Math]::Max(1 - [Math]::Abs($Time.Ticks - $MiddayTicks) / $HalfDayTicks, 0)
        $UvFactor = [Math]::Min($UvIndex / 7.5, 1)
        $TimeFactor = ([Math]::Pow($SunElevation - 1, 3) + 1) * 0.382
        $Factor = $TimeFactor * (1 + $UvFactor)
        return [int]($MinBrightness + ($MaxBrightness - $MinBrightness) * $Factor)
    }
    return $MinBrightness
}

function Test-DisplayAvailable {
    # 合盖后内屏断电，WmiMonitorBasicDisplayParams 查不到实例，此时写亮度不会生效
    try {
        $Monitors = @(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop |
                Where-Object { $_.Active -ne $false })
    }
    catch {
        Write-Log "检测显示器状态失败: $($_.Exception.Message)" 'WARN'
        return $false
    }
    return ($Monitors.Count -gt 0)
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
$GeoCoords = $null
$GeoUpdatedAt = $null
$GeoRefreshMinutes = 30
$LastCoordsSource = $null
$FallbackMode = $false
$DisplayAvailable = $true

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
        $GeoCoords = $null
        $GeoUpdatedAt = $null
        $LastCoordsSource = $null
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
        $WeatherLocation = $Location
        if (!$WeatherLocation) {
            # 未配置位置时用系统定位（带缓存刷新），设备移动后位置会变化
            $WeatherLocation = Update-GeoCoords
        }
        try {
            $Weather = Get-WeatherData $WeatherLocation
            $WeatherDate = $Now.Date
            Write-Log "天气数据: 紫外线 $($Weather.UvIndex)" 'OK'
        }
        catch {
            Write-Log "天气查询失败: $($_.Exception.Message)" 'ERROR'
            Write-Log '本次沿用当天已有的天气数据，下次整点再试；没有当天数据时按降级模式调节' 'WARN'
        }
    }

    # 日出日落与经纬度获取放在一起：配置经纬度优先，否则系统定位并按间隔刷新
    $SunContext = Get-SunContext $Location $Now
    if ($SunContext) {
        $Sun = $SunContext.Sun
        $CoordsSource = ('{0}，纬度 {1} 经度 {2}（经度对应太阳时 UTC{3:+0.0;-0.0}）' -f $SunContext.Source, [Math]::Round($SunContext.Latitude, 2), [Math]::Round($SunContext.Longitude, 2), ($SunContext.Longitude / 15))
    }
    else {
        $Sun = $null
        $CoordsSource = '钟点兜底（无法获取经纬度）'
    }
    if ($CoordsSource -ne $LastCoordsSource) {
        Write-Log "日出日落坐标来源: $CoordsSource"
        $LastCoordsSource = $CoordsSource
    }

    # 没有日出日落，或当天没有可用天气数据时，进入降级模式；恢复后自动回到正常逻辑
    $IsFallback = (!$Sun) -or (-not ($Weather -and ($WeatherDate -eq $Now.Date)))
    if ($IsFallback -ne $FallbackMode) {
        if ($IsFallback) {
            if (!$Sun) {
                Write-Log '无法获取经纬度，无法计算日出日落，按钟点时段的固定亮度调节' 'WARN'
            }
            else {
                Write-Log ("天气服务不可用，进入降级模式：日出 {0:hh\:mm} 日落 {1:hh\:mm}，按固定时段亮度调节" -f $Sun.Sunrise, $Sun.Sunset) 'WARN'
            }
        }
        else {
            Write-Log '日出日落与天气数据已恢复，回到正常调节模式' 'OK'
        }
        $FallbackMode = $IsFallback
    }

    if (!$Sun) {
        $Brightness = Get-ClockBrightness $Now
    }
    elseif ($IsFallback) {
        $Brightness = Get-FallbackBrightness $Sun $Now
    }
    else {
        $Brightness = Get-TargetBrightness $Sun $Weather.UvIndex $Now
    }
    # 合盖或屏幕关闭时显示器实例消失，此时写亮度无效，直接跳过本轮
    $IsDisplayAvailable = Test-DisplayAvailable
    if ($IsDisplayAvailable -ne $DisplayAvailable) {
        if ($IsDisplayAvailable) {
            Write-Log '显示器已恢复可用，继续调节亮度' 'OK'
        }
        else {
            Write-Log '显示器当前不可用（可能已合盖或屏幕关闭），暂停调节亮度' 'WARN'
        }
        $DisplayAvailable = $IsDisplayAvailable
    }
    if (!$IsDisplayAvailable) {
        Start-Sleep -Seconds 60
        continue
    }

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

    Start-Sleep -Seconds 60
}
