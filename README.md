# OpenWRT_scripts

OpenWrt 常用安装/运维脚本集合。当前包含两个脚本：

| 脚本 | 用途 |
| --- | --- |
| [install_ddns_cloudflare.sh](install_ddns_cloudflare.sh) | 自动安装/修复 Cloudflare DDNS，并注册 `cloudflare.com-v4` 服务商 |
| [install_eMMC_Info.sh](install_eMMC_Info.sh) | 一键安装 eMMC 检测工具（命令行脚本 + LuCI 页面） |

两个脚本都需要在 OpenWrt 设备上以 root 权限运行。

## install_ddns_cloudflare.sh

在 OpenWrt 上自动安装/修复 `ddns-scripts-cloudflare`，并注册 `cloudflare.com-v4` 服务商，用于通过 Cloudflare API 动态更新域名解析记录。

### 功能

- 自动检测并补装基础依赖：`ddns-scripts`、`ddns-scripts-services`、`curl`
- 尝试补装可选的 LuCI 界面 `luci-app-ddns`（失败不影响核心功能）
- 安装或修复 `ddns-scripts-cloudflare`，确保更新脚本 `/usr/lib/ddns/update_cloudflare_com_v4.sh` 存在
- 向 `/etc/ddns/services` 和 `/etc/ddns/services_ipv6` 注册 `cloudflare.com-v4` 服务商，IPv6 AAAA 记录同样可用
- 重启 DDNS 服务并做最终校验
- 当前软件源找不到包时，自动识别目标架构，从 OpenWrt 官方源回退安装
- 若检测到设备上已有 DDNS 配置，会先询问是否继续，避免覆盖已有配置

### 使用前提

- OpenWrt 设备，具备 `opkg` 包管理器
- 以 root 权限运行
- 设备可正常访问网络（安装依赖及回退到官方源时需要）

### 使用方法

```sh
bash -c "$(wget -qLO - https://raw.githubusercontent.com/isJackeroo/OpenWRT_scripts/refs/heads/main/install_ddns_cloudflare.sh)"
```



## install_eMMC_Info.sh

一键安装 eMMC 检测工具：命令行脚本 `/usr/bin/emmcinfo.sh` + LuCI 页面。安装完成后可在 LuCI → 系统 → eMMC Info 查看 eMMC 型号、寿命和读写速度。

### 功能

- 设备没有 eMMC 时直接终止，不执行任何安装动作
- 自动创建缺失目录，写入并校验三个文件：
  - `/usr/bin/emmcinfo.sh`（权限 755）
  - `/usr/lib/lua/luci/controller/emmcinfo.lua`
  - `/usr/lib/lua/luci/view/emmcinfo/status.htm`
- 安装完成后刷新 LuCI 缓存，菜单即可用
- 若未检测到 `/etc/openwrt_release` 会给出警告但不中断（可兼容类 OpenWrt 固件）

### 使用前提

- 板载 eMMC 的 OpenWrt 设备（脚本最前面会检测）
- 以 root 权限运行
- 标准 LuCI 环境

### 使用方法

```sh
bash -c "$(wget -qLO - https://raw.githubusercontent.com/isJackeroo/OpenWRT_scripts/refs/heads/main/install_eMMC_Info.sh)"
```

安装完成后刷新浏览器，进入 LuCI → 系统 → eMMC Info，点击“运行检测”。

### 检测内容

- 基本信息：型号、CID、容量、序列号、固件/硬件版本、厂商 ID、生产日期等
- 寿命信息：通过 `mmc extcsd read` 读取 EXT_CSD，显示 Life Time Estimation A/B 和 Pre EOL；未安装 `mmc-utils` 时自动跳过并提示
- 速度测试：`dd` 写入/读取测试，存在 `hdparm` 时额外显示缓存/缓冲读取速度

### 注意事项

- 没有 eMMC 的设备会直接终止安装
- `/tmp` 可用空间小于 16 MB 时跳过写入速度测试，测试大小也会按剩余空间自动调小
- 建议安装 `mmc-utils` 和 `hdparm` 以获得完整检测结果：

```sh
opkg install mmc-utils hdparm
```

- 安装脚本会覆盖同名目标文件，改动前请自行确认
