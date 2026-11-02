# AutoMonitorBrightness

[![total / day](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/day&label=total&query=total&suffix=+/+day&style=flat-square)](https://github.com/star2000/count)
[![total / week](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/week&label=total&query=total&suffix=+/+week&style=flat-square)](https://github.com/star2000/count)
[![total / month](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/month&label=total&query=total&suffix=+/+month&style=flat-square)](https://github.com/star2000/count)
[![total / year](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/year&label=total&query=total&suffix=+/+year&style=flat-square)](https://github.com/star2000/count)

Windows 自动调整屏幕亮度

通过位置信息 查询到 天气里的紫外线指数、再根据日升日落时间 调整屏幕亮度

开机或登录后启动一个后台常驻进程，启动时及每小时整点更新天气数据，每分钟读取一次当前亮度，仅在当前亮度与目标不符时才设置；读不到当前亮度（如合盖后内屏断电）时，退回按目标是否变化来判断

没联网时沿用当天已有的天气数据，下次整点再查询；旧天气数据仅当天有效

最低支持 Win7、Win2008

## 使用

鼠标移至命令上，连点三次，`Ctrl+C`，`Win+R`，`Ctrl+V`，`Enter`

### 安装

```ps1
powershell [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; (New-Object Net.WebClient).DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/install.ps1') | iex
```

> Windows 已弃用 VBScript，改用 PowerShell 启动常驻进程；只在开机 / 登录启动时可能短暂出现窗口。已安装的用户重新执行安装命令即可，安装时会结束旧的常驻进程

### 卸载

```ps1
powershell [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; (New-Object Net.WebClient).DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/uninstall.ps1') | iex
```

## 设置

通过环境变量改变行为

```bat
setx "环境变量名" "环境变量值"
```

修改环境变量后约 1 分钟内自动生效，无需重启；如需更新脚本版本，再次执行安装命令即可（会结束旧的常驻进程并重新启动）

- 位置
  - 环境变量名：`AMB_LOCATION`
  - 默认值：无（未填时每次查询天气都会重新尝试使用Windows系统的定位服务，如果获取不到最好手动填写位置信息，不然靠IP推断位置会偏很远，查到的天气信息可能不对）
  - 可选值：`纬度,经度` 或者 `地名` 镇级及以上 中英文都行
- 最大亮度
  - 环境变量名：`AMB_MAX_BRIGHTNESS`
  - 默认值：`100`
  - 可选值：`0`到`100`
- 最小亮度
  - 环境变量名：`AMB_MIN_BRIGHTNESS`
  - 默认值：`0`
  - 可选值：`0`到`100`

## [捐赠](https://blog.star2000.work/images/alipay.png)
