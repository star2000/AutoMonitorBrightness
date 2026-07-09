# AutoMonitorBrightness

[![total / day](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/day&label=total&query=total&suffix=+/+day&style=flat-square)](https://github.com/star2000/count)
[![total / week](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/week&label=total&query=total&suffix=+/+week&style=flat-square)](https://github.com/star2000/count)
[![total / month](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/month&label=total&query=total&suffix=+/+month&style=flat-square)](https://github.com/star2000/count)
[![total / year](https://img.shields.io/badge/dynamic/json?url=https://data.jsdelivr.com/v1/package/gh/star2000/count@5/stats/year&label=total&query=total&suffix=+/+year&style=flat-square)](https://github.com/star2000/count)

Windows 自动调整屏幕亮度

通过位置信息 查询到 天气里的紫外线指数、再根据日升日落时间 调整屏幕亮度

开机触发一次，每小时整点触发一次

如果没开机或没联网, 则自动延迟

最低支持 Win7、Win2008

## 使用

鼠标移至命令上，连点三次，`Ctrl+C`，`Win+R`，`Ctrl+V`，`Enter`

### 安装

```ps1
powershell [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; (New-Object Net.WebClient).DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/install.ps1') | iex
```

### 卸载

```ps1
powershell [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; (New-Object Net.WebClient).DownloadString('https://cdn.jsdelivr.net/gh/star2000/AutoMonitorBrightness@main/uninstall.ps1') | iex
```

## 设置

通过环境变量改变行为

```bat
setx "环境变量名" "环境变量值"
```

手动刷新执行

```bat
schtasks /Run /TN "\star2000\AutoMonitorBrightness"
```

- 位置
  - 环境变量名：`AMB_LOCATION`
  - 默认值：无（未填时尝试使用Windows系统的定位服务，如果获取不到最好手动填写位置信息，不然靠IP推断位置会偏很远，查到的天气信息可能不对）
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
