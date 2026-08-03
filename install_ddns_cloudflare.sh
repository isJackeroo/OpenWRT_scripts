#!/bin/sh
#
# 自动安装/修复 ddns-scripts-cloudflare，并注册 cloudflare.com-v4 服务商。
# 缺少 ddns-scripts、curl 等基础依赖时自动补装；
# 当前软件源找不到包时，自动识别架构并从 OpenWrt 官方源回退安装。

PACKAGE="ddns-scripts-cloudflare"
BASE_DEPS="ddns-scripts ddns-scripts-services curl"
OPTIONAL_DEPS="luci-app-ddns"
PROVIDER="cloudflare.com-v4"
SERVICE_FILE="/etc/ddns/services"
SERVICE_IPV6_FILE="/etc/ddns/services_ipv6"
SERVICE_LINE="cloudflare.com-v4        update_cloudflare_com_v4.sh"
SCRIPT_PATH="/usr/lib/ddns/update_cloudflare_com_v4.sh"
TMP_IPK="/tmp/${PACKAGE}.ipk"
FEED_CONF="/etc/opkg/ddns-official.conf"
OFFICIAL_BASE="https://downloads.openwrt.org/releases"

trap 'rm -f "$TMP_IPK" "$FEED_CONF" 2>/dev/null' EXIT HUP INT TERM

log() {
    echo "[DDNS] $*"
}

fail() {
    log "错误：$*"
    exit 1
}

package_installed() {
    pkg_installed "$PACKAGE"
}

pkg_installed() {
    opkg list-installed 2>/dev/null | grep -q "^$1 "
}

detect_arch() {
    # opkg 会输出目标架构及其优先级，选择优先级最高的一项
    _arch="$(opkg print-architecture 2>/dev/null | awk '$1 == "arch" && $2 != "all" && $2 != "noarch" { print $2, $3 }' | sort -k2 -nr | awk 'NR == 1 { print $1 }')"
    if [ -n "$_arch" ]; then
        echo "$_arch"
        return 0
    fi

    # 极少数没有 opkg print-architecture 的环境，用 uname 做最佳猜测
    case "$(uname -m)" in
        aarch64*) _arch="aarch64_cortex-a53" ;;
        armv7*) _arch="arm_cortex-a7_neon-vfpv4" ;;
        armv6*) _arch="arm_arm1176jzf-s_vfp" ;;
        x86_64*) _arch="x86_64" ;;
        i*86*) _arch="i386_pentium4" ;;
        mips*) _arch="mips_24kc" ;;
        mipsel*) _arch="mipsel_24kc" ;;
    esac

    if [ -n "$_arch" ]; then
        echo "$_arch"
        return 0
    fi
    return 1
}

candidate_releases() {
    # 优先使用当前软件源里的 release，再补充常见官方版本
    _rels="$(sed -n 's#.*/releases/\([0-9.]*\)/packages/.*#\1#p' /etc/opkg/*.conf 2>/dev/null | sort -u)"
    _rels="$(echo "$_rels 24.10.5 23.05.5 22.03.7 21.02.7 19.07.10" | tr ' ' '\n' | awk '!seen[$0]++')"
    echo "$_rels"
}

find_ipk_url() {
    _pkg="$1"
    _arch="$2"

    for _rel in $(candidate_releases); do
        for _feed in packages luci; do
            _index_url="${OFFICIAL_BASE}/${_rel}/packages/${_arch}/${_feed}/Packages.gz"
            _filename="$(wget -qO- "$_index_url" 2>/dev/null | gzip -dc 2>/dev/null | awk -v pkg="$_pkg" '
                $0 == "Package: " pkg { found = 1; next }
                found && /^Filename: / { print $2; exit }
            ')"
            if [ -n "$_filename" ]; then
                echo "${OFFICIAL_BASE}/${_rel}/packages/${_arch}/${_feed}/${_filename}"
                return 0
            fi
        done
    done
    return 1
}

install_from_official() {
    _pkg="${1:-$PACKAGE}"
    _arch="${OPKG_ARCH:-}"
    if [ -z "$_arch" ]; then
        _arch="$(detect_arch)" || {
            log "错误：无法自动识别架构，可通过 OPKG_ARCH 环境变量手动指定"
            return 1
        }
    fi
    log "检测到目标架构：$_arch"

    _url="$(find_ipk_url "$_pkg" "$_arch")" || {
        log "错误：OpenWrt 官方源中找不到 ${_pkg}"
        return 1
    }
    log "找到安装包：$_url"
    wget -O "$TMP_IPK" "$_url" || {
        log "错误：${_pkg} 安装包下载失败"
        return 1
    }

    if opkg install "$TMP_IPK" >/dev/null 2>&1; then
        rm -f "$TMP_IPK"
        log "${_pkg} 已从 OpenWrt 官方源安装成功"
        return 0
    fi
    rm -f "$TMP_IPK"

    # 直接安装 ipk 失败时，临时挂载官方源，让 opkg 自动补齐剩余依赖
    for _rel in $(candidate_releases); do
        echo "src/gz ddns_official ${OFFICIAL_BASE}/${_rel}/packages/${_arch}/packages" > "$FEED_CONF"
        echo "src/gz ddns_luci ${OFFICIAL_BASE}/${_rel}/packages/${_arch}/luci" >> "$FEED_CONF"
        if opkg update >/dev/null 2>&1 && opkg install "$_pkg" >/dev/null 2>&1; then
            rm -f "$FEED_CONF"
            log "${_pkg} 已通过临时官方源安装成功"
            return 0
        fi
    done
    rm -f "$FEED_CONF"

    log "错误：${_pkg} 安装失败"
    return 1
}

ensure_dependencies() {
    _missing=""
    for _dep in $BASE_DEPS; do
        pkg_installed "$_dep" || _missing="$_missing $_dep"
    done

    if [ -z "$_missing" ]; then
        log "基础依赖已满足：$(echo "$BASE_DEPS" | tr ' ' ',')"
        return 0
    fi

    log "检测到缺少基础依赖：$(echo "$_missing" | sed 's/^ *//' | tr ' ' ',')"
    opkg update >/dev/null 2>&1
    for _dep in $_missing; do
        log "正在安装依赖 ${_dep}..."
        if opkg install "$_dep" >/dev/null 2>&1; then
            log "${_dep} 安装成功"
        else
            log "${_dep} 当前软件源安装失败，尝试 OpenWrt 官方源..."
            install_from_official "$_dep" || fail "依赖 ${_dep} 安装失败"
        fi
    done
}

ensure_luci_ui() {
    if pkg_installed "$OPTIONAL_DEPS"; then
        return 0
    fi

    log "尝试补装 ${OPTIONAL_DEPS}（LuCI 界面）..."
    if ! opkg install "$OPTIONAL_DEPS" >/dev/null 2>&1; then
        if install_from_official "$OPTIONAL_DEPS"; then
            log "${OPTIONAL_DEPS} 已安装"
        else
            log "警告：${OPTIONAL_DEPS} 安装失败，不影响 DDNS 核心功能"
        fi
    fi
}

ensure_package() {
    if package_installed && [ -f "$SCRIPT_PATH" ]; then
        log "${PACKAGE} 已安装，更新脚本存在"
        return 0
    fi

    if package_installed; then
        log "${PACKAGE} 已安装但更新脚本缺失，尝试修复..."
        if opkg install --force-reinstall "$PACKAGE" >/dev/null 2>&1 && [ -f "$SCRIPT_PATH" ]; then
            log "修复成功"
            return 0
        fi
    else
        log "正在通过当前软件源安装 ${PACKAGE}..."
        opkg update >/dev/null 2>&1
        if opkg install "$PACKAGE" >/dev/null 2>&1 && [ -f "$SCRIPT_PATH" ]; then
            log "已通过当前软件源安装成功"
            return 0
        fi
    fi

    log "当前软件源无法安装 ${PACKAGE}，尝试 OpenWrt 官方源..."
    install_from_official || fail "安装 ${PACKAGE} 失败，请检查网络或手动安装"
}

add_service_entry() {
    _file="$1"
    mkdir -p /etc/ddns
    [ -f "$_file" ] || touch "$_file"

    if grep -q "^${PROVIDER}[[:space:]]" "$_file"; then
        log "${_file} 中已存在 ${PROVIDER}，跳过"
    else
        echo "" >> "$_file"
        echo "$SERVICE_LINE" >> "$_file"
        log "已向 ${_file} 添加 ${PROVIDER}"
    fi
}

service_exists() {
    grep -q "^${PROVIDER}[[:space:]]" "$SERVICE_FILE" 2>/dev/null && return 0
    grep -q "^${PROVIDER}[[:space:]]" "$SERVICE_IPV6_FILE" 2>/dev/null && return 0
    grep -Eq '^[[:space:]]*config[[:space:]]+service([[:space:]]|$)' /etc/config/ddns 2>/dev/null && return 0
    return 1
}

pause_if_service_exists() {
    if ! service_exists; then
        return 0
    fi

    log "检测到 DDNS 服务已存在"
    printf "[DDNS] 是否继续安装？[y/N] "
    read -r _answer
    case "$_answer" in
        y|Y)
            log "用户选择继续"
            ;;
        *)
            log "已暂停安装进程，未执行安装"
            exit 0
            ;;
    esac
}

log "开始检查 ${PACKAGE} 与 ${PROVIDER} 服务商配置..."

pause_if_service_exists

ensure_dependencies
ensure_package
ensure_luci_ui

add_service_entry "$SERVICE_FILE"
add_service_entry "$SERVICE_IPV6_FILE"

if [ -x /etc/init.d/ddns ]; then
    /etc/init.d/ddns restart >/dev/null 2>&1
    log "已重启 DDNS 服务"
fi

if package_installed && [ -f "$SCRIPT_PATH" ]; then
    log "最终校验通过：${PACKAGE} 已安装，更新脚本存在"
else
    fail "最终校验未通过"
fi

log "完成！可在 LuCI → 服务 → 动态 DNS 中选择 ${PROVIDER}"
