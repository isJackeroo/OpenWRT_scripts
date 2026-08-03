### 功能

- 自动检测并补装基础依赖：`ddns-scripts`、`ddns-scripts-services`、`curl`
- 尝试补装可选的 LuCI 界面 `luci-app-ddns`（失败不影响核心功能）
- 安装或修复 `ddns-scripts-cloudflare`，确保更新脚本 `/usr/lib/ddns/update_cloudflare_com_v4.sh` 存在
- 向 `/etc/ddns/services` 和 `/etc/ddns/services_ipv6` 注册 `cloudflare.com-v4` 服务商
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

