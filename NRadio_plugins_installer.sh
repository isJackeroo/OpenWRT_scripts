set -eu

# 脚本工作目录与运行时路径。
# SCRIPT_DIR: 当前脚本所在目录，便于生成调试产物与备份文件。
# WORKDIR: 临时工作区，用于下载 ipk、解包与重打包。
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
WORKDIR="${TMPDIR:-/tmp}/NRadio_plugin"
BACKUP_DIR="$SCRIPT_DIR/.backup"
CFG="/etc/config/appcenter"
FEEDS="/etc/opkg/distfeeds.conf"
OPENCLASH_BRANCH="${OPENCLASH_BRANCH:-master}"
OPENCLASH_MIRRORS="${OPENCLASH_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://fastly.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH} https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@package/${OPENCLASH_BRANCH}}"
OPENCLASH_CORE_VERSION_MIRRORS="${OPENCLASH_CORE_VERSION_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/dev https://raw.githubusercontent.com/vernesong/OpenClash/core/dev}"
OPENCLASH_CORE_SMART_MIRRORS="${OPENCLASH_CORE_SMART_MIRRORS:-https://cdn.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/dev/smart https://raw.githubusercontent.com/vernesong/OpenClash/core/dev/smart}"
OPENCLASH_GH_PROXIES="${OPENCLASH_GH_PROXIES:-https://gh-proxy.com/ https://ghproxy.net/}"
OPENCLASH_PACKAGE_DOWNLOAD_MAX_TIME="${OPENCLASH_PACKAGE_DOWNLOAD_MAX_TIME:-120}"
KMS_CORE_VERSION="${KMS_CORE_VERSION:-svn1113-1}"
KMS_CORE_IPK_BASE_URL="${KMS_CORE_IPK_BASE_URL:-https://raw.githubusercontent.com/cokebar/openwrt-vlmcsd/gh-pages}"
KMS_LUCI_IPK_URL="${KMS_LUCI_IPK_URL:-https://github.com/cokebar/luci-app-vlmcsd/releases/download/v1.0.2-1/luci-app-vlmcsd_1.0.2-1_all.ipk}"
KMS_GH_PROXIES="${KMS_GH_PROXIES:-https://gh-proxy.com/ https://ghproxy.net/}"
KMS_DOWNLOAD_MAX_TIME="${KMS_DOWNLOAD_MAX_TIME:-60}"
OPENLIST_RELEASE_SDK="${OPENLIST_RELEASE_SDK:-openwrt-24.10}"
OPENLIST_RELEASE_VERSION="${OPENLIST_RELEASE_VERSION:-v4.1.10}"
OPENLIST_RELEASE_BASE_URL="${OPENLIST_RELEASE_BASE_URL:-https://github.com/sbwml/luci-app-openlist2/releases/download/${OPENLIST_RELEASE_VERSION}}"
OPENLIST_GH_PROXY="${OPENLIST_GH_PROXY:-https://gh-proxy.com/}"
OPENLIST_GH_PROXIES="${OPENLIST_GH_PROXIES:-https://gh-proxy.com/ https://ghproxy.net/}"
OPENLIST_MIN_FREE_MB="${OPENLIST_MIN_FREE_MB:-20}"
OPENLIST_DOWNLOAD_MAX_TIME="${OPENLIST_DOWNLOAD_MAX_TIME:-300}"
OPENWRT_RELEASE="${OPENWRT_RELEASE:-21.02.7}"
OPENWRT_ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53}"
OPENWRT_MIRRORS="${OPENWRT_MIRRORS:-https://mirrors.aliyun.com/openwrt https://mirror.sjtu.edu.cn/openwrt https://downloads.openwrt.org}"
OPENWRT_FEED_PROBE_MAX_TIME="${OPENWRT_FEED_PROBE_MAX_TIME:-12}"
DOWNLOAD_CONNECT_TIMEOUT="${DOWNLOAD_CONNECT_TIMEOUT:-8}"
DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-1800}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-2}"
OPENCLASH_CORE_DOWNLOAD_MAX_TIME="${OPENCLASH_CORE_DOWNLOAD_MAX_TIME:-240}"
INSTALL_OPENCLASH_SMART_CORE="${INSTALL_OPENCLASH_SMART_CORE:-1}"
MIRROR_PING_COUNT="${MIRROR_PING_COUNT:-2}"
MIRROR_PING_TIMEOUT="${MIRROR_PING_TIMEOUT:-2}"

# 统一日志输出。
log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

confirm_default_yes() {
    prompt="${1:-确认继续吗？}"
    printf '%s [Y/n]: ' "$prompt"
    read -r answer
    case "$answer" in
        n|N|no|NO) return 1 ;;
        *) return 0 ;;
    esac
}

backup_file() {
    target="$1"
    [ -e "$target" ] || return 0
    mkdir -p "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
    safe_name="$(printf '%s' "$target" | sed 's#/#_#g')"
    cp -f "$target" "$BACKUP_DIR/${safe_name}.${stamp}.bak"
}

require_root() {
    [ "$(id -u)" = "0" ] || die 'please run as root'
}

require_file() {
    [ -f "$1" ] || die "missing file: $1"
}

# 某些 NRadio 固件的 feeds 配置并不完整，这里在安装前切回一组可用的默认镜像。
normalize_feed_base_url() {
    base_url="$1"
    case "$base_url" in
        */) printf '%s' "${base_url%/}" ;;
        *) printf '%s' "$base_url" ;;
    esac
}

probe_url_http_ok() {
    url="$1"
    [ -n "$url" ] || return 1

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$OPENWRT_FEED_PROBE_MAX_TIME" -o /dev/null "$url"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null --timeout="$OPENWRT_FEED_PROBE_MAX_TIME" "$url"
        return $?
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        rm -f "$WORKDIR/feed-probe.out"
        uclient-fetch -q -O "$WORKDIR/feed-probe.out" "$url" >/dev/null 2>&1
        return $?
    fi

    return 1
}

select_available_feed_mirror() {
    for base_url in $OPENWRT_MIRRORS; do
        [ -n "$base_url" ] || continue
        mirror="$(normalize_feed_base_url "$base_url")"
        if probe_url_http_ok "$mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/packages/Packages.gz"; then
            printf '%s\n' "$mirror"
            return 0
        fi
        printf 'warn: feed mirror unavailable %s\n' "$mirror" >&2
    done

    return 1
}

write_default_feeds_for_mirror() {
    mirror="$(normalize_feed_base_url "$1")"
    [ -n "$mirror" ] || return 1

    mkdir -p "$WORKDIR"
    feeds_tmp="$WORKDIR/distfeeds.default"

    cat > "$feeds_tmp" <<EOF
# Unsupported vendor target feeds disabled
# src/gz openwrt_core $mirror/releases/$OPENWRT_RELEASE/targets/mediatek/mt7987/packages
src/gz openwrt_base $mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/base
src/gz openwrt_luci $mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/luci
# Vendor private feed unavailable on public mirrors
# src/gz openwrt_mtk_openwrt_feed $mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/mtk_openwrt_feed
src/gz openwrt_packages $mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/packages
src/gz openwrt_routing $mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/routing
src/gz openwrt_telephony $mirror/releases/$OPENWRT_RELEASE/packages/$OPENWRT_ARCH/telephony
EOF

    if ! cmp -s "$feeds_tmp" "$FEEDS"; then
        log "Logs: switching opkg feeds to $mirror ..."
        backup_file "$FEEDS"
        cp "$feeds_tmp" "$FEEDS"
    else
        log "Logs: opkg feeds already use $mirror"
    fi
}

get_preferred_feed_mirror() {
    mirror="$(select_available_feed_mirror 2>/dev/null || true)"
    if [ -z "$mirror" ]; then
        first_mirror="$(printf '%s\n' $OPENWRT_MIRRORS | sed -n '1p')"
        mirror="$(normalize_feed_base_url "$first_mirror")"
        printf 'warn: no feed mirror probe succeeded; using first configured mirror %s\n' "$mirror" >&2
    fi

    printf '%s\n' "$mirror"
}

ensure_default_feeds() {
    mkdir -p "$WORKDIR"
    mirror="$(get_preferred_feed_mirror)"
    write_default_feeds_for_mirror "$mirror"
}

require_safe_uci_value() {
    value_name="$1"
    value="$2"

    case "$value" in
        *"
"*|*"'"*)
            die "unsafe $value_name for uci set"
            ;;
    esac
}

download_with_tool() {
    url="$1"
    dest="$2"
    [ -n "$url" ] || die 'missing download url'
    [ -n "$dest" ] || die 'missing download destination'

    if command -v curl >/dev/null 2>&1; then
        if [ -f "$dest" ] && [ -s "$dest" ]; then
            curl -fL --retry "$DOWNLOAD_RETRIES" --retry-delay 2 -C - --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" -o "$dest" "$url" || {
                log "warn: resume failed for $url, retrying full download..."
                rm -f "$dest"
                curl -fL --retry "$DOWNLOAD_RETRIES" --retry-delay 2 --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" -o "$dest" "$url"
            }
        else
            curl -fL --retry "$DOWNLOAD_RETRIES" --retry-delay 2 --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" -o "$dest" "$url"
        fi
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        if [ -f "$dest" ] && [ -s "$dest" ]; then
            wget --timeout="$DOWNLOAD_MAX_TIME" --tries="$DOWNLOAD_RETRIES" -c -O "$dest" "$url" || {
                log "warn: resume failed for $url, retrying full download..."
                rm -f "$dest"
                wget --timeout="$DOWNLOAD_MAX_TIME" --tries="$DOWNLOAD_RETRIES" -O "$dest" "$url"
            }
        else
            wget --timeout="$DOWNLOAD_MAX_TIME" --tries="$DOWNLOAD_RETRIES" -O "$dest" "$url"
        fi
        return
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        rm -f "$dest"
        uclient-fetch -O "$dest" "$url"
        return
    fi

    die 'no supported download tool found (uclient-fetch/wget/curl)'
}

url_host() {
    url="$1"
    host="${url#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    printf '%s\n' "$host"
}

ping_mirror_latency_ms() {
    base_url="$1"
    host="$(url_host "$base_url")"
    [ -n "$host" ] || return 1
    command -v ping >/dev/null 2>&1 || return 1

    ping_out="$(ping -c "$MIRROR_PING_COUNT" -W "$MIRROR_PING_TIMEOUT" "$host" 2>/dev/null || true)"
    latency="$(printf '%s\n' "$ping_out" | awk '
        /min\/avg\/max/ || /round-trip/ {
            sub(/^.*=[[:space:]]*/, "", $0)
            split($0, parts, "/")
            printf "%.0f\n", parts[2]
            found = 1
        }
        END { if (!found) exit 1 }
    ')"
    [ -n "$latency" ] || return 1
    printf '%s\n' "$latency"
}

sort_mirrors_by_latency() {
    base_list="$1"
    ranked_file="$WORKDIR/mirror-latency.$$"
    unranked_file="$WORKDIR/mirror-unranked.$$"
    rm -f "$ranked_file"
    rm -f "$unranked_file"
    mkdir -p "$WORKDIR"

    for base_url in $base_list; do
        [ -n "$base_url" ] || continue
        latency="$(ping_mirror_latency_ms "$base_url" 2>/dev/null || true)"
        if [ -n "$latency" ]; then
            printf 'Logs: mirror latency %sms %s\n' "$latency" "$base_url" >&2
            printf '%08d %s\n' "$latency" "$base_url" >> "$ranked_file"
        else
            printf 'warn: mirror ping unavailable %s\n' "$base_url" >&2
            printf '%s\n' "$base_url" >> "$unranked_file"
        fi
    done

    if [ -s "$ranked_file" ]; then
        sort -n "$ranked_file" | awk '{print $2}'
        [ -s "$unranked_file" ] && cat "$unranked_file"
        rm -f "$ranked_file" "$unranked_file"
        return 0
    fi

    rm -f "$ranked_file" "$unranked_file"
    for base_url in $base_list; do
        [ -n "$base_url" ] && printf '%s\n' "$base_url"
    done
}

# 先按 ping 延迟排序镜像，再依次下载；ping 不可用时回退到原始顺序。
download_from_mirrors() {
    file_name="$1"
    out="$2"
    base_list="${3:-$OPENCLASH_MIRRORS}"
    validator="${4:-}"
    sort_mode="${5:-1}"
    rm -f "$out"
    if [ "$sort_mode" = "0" ]; then
        sorted_list="$base_list"
    else
        sorted_list="$(sort_mirrors_by_latency "$base_list")"
    fi

    for base_url in $sorted_list; do
        [ -n "$base_url" ] || continue
        printf 'Logs: trying mirror %s/%s\n' "$base_url" "$file_name" >&2
        if download_with_tool "$base_url/$file_name" "$out" >/dev/null 2>&1; then
            if [ -n "$validator" ] && ! "$validator" "$out"; then
                printf 'warn: mirror returned invalid file %s/%s\n' "$base_url" "$file_name" >&2
                rm -f "$out"
                continue
            fi
            printf '%s\n' "$base_url"
            return 0
        fi
        printf 'warn: mirror failed %s/%s\n' "$base_url" "$file_name" >&2
        rm -f "$out"
    done

    return 1
}

validate_nonempty_file() {
    [ -s "$1" ]
}

validate_gzip_tar_file() {
    [ -s "$1" ] || return 1
    tar -tzf "$1" >/dev/null 2>&1
}

ensure_opkg_update() {
    update_ok=0

    mirror_list="$(get_preferred_feed_mirror)"
    for base_url in $OPENWRT_MIRRORS; do
        [ -n "$base_url" ] || continue
        mirror="$(normalize_feed_base_url "$base_url")"
        case " $mirror_list " in
            *" $mirror "*) ;;
            *) mirror_list="$mirror_list $mirror" ;;
        esac
    done

    for mirror in $mirror_list; do
        write_default_feeds_for_mirror "$mirror"
        log "Logs: running opkg update via $mirror ..."
        if opkg update >/tmp/NRadio_plugin-opkg-update.log 2>&1; then
            update_ok=1
            break
        fi
        log "warn: opkg update failed via $mirror"
        sed -n '1,80p' /tmp/NRadio_plugin-opkg-update.log >&2
    done

    if [ "$update_ok" != "1" ]; then
        die 'opkg update failed on all configured mirrors'
    fi
}

# 从已更新的 opkg 列表中解析包名与下载路径。
find_package_url() {
    pkg_name="$1"

    awk -v pkg="$pkg_name" '
        $0 == "Package: " pkg { found=1; next }
        found && /^Filename: / {
            sub(/^Filename: /, "", $0)
            print
            exit
        }
        found && /^$/ { found=0 }
    ' /var/opkg-lists/* 2>/dev/null | head -n 1
}

get_package_filename_and_feed_from_lists() {
    pkg_name="$1"

    awk -v pkg="$pkg_name" '
        FNR == 1 {
            feed = FILENAME
            sub(/^.*\//, "", feed)
        }
        $0 == "Package: " pkg { found=1; next }
        found && /^Filename: / {
            sub(/^Filename: /, "", $0)
            print feed "|" $0
            exit
        }
        found && /^$/ { found=0 }
    ' /var/opkg-lists/* 2>/dev/null | head -n 1
}

get_feed_url() {
    feed_name="$1"
    awk -v n="$feed_name" '$1=="src/gz" && $2==n {print $3; exit}' "$FEEDS" 2>/dev/null
}

get_feed_package_field() {
    feed_name="$1"
    package_name="$2"
    field_name="$3"

    feed_url="$(get_feed_url "$feed_name")"
    [ -n "$feed_url" ] || return 1

    mkdir -p "$WORKDIR/feed-index"
    feed_idx="$WORKDIR/feed-index/${feed_name}.Packages.gz"
    download_with_tool "$feed_url/Packages.gz" "$feed_idx" >/dev/null 2>&1 || return 1

    gzip -dc "$feed_idx" 2>/dev/null | awk -v pkg="$package_name" -v fld="$field_name" '
        $0 == ("Package: " pkg) { found = 1; next }
        found && index($0, fld ": ") == 1 {
            sub("^" fld ": ", "")
            print
            exit
        }
        found && $0 == "" { exit }
    '
}

resolve_feed_package_url() {
    feed_name="$1"
    package_name="$2"

    feed_url="$(get_feed_url "$feed_name")"
    [ -n "$feed_url" ] || return 1
    filename="$(get_feed_package_field "$feed_name" "$package_name" Filename)"
    [ -n "$filename" ] || return 1
    printf '%s/%s\n' "$feed_url" "$filename"
}

resolve_package_url_any_feed() {
    package_name="$1"
    feed_names="$(awk '$1=="src/gz" {print $2}' "$FEEDS" 2>/dev/null)"

    for feed_name in $feed_names; do
        [ -n "$feed_name" ] || continue
        url="$(resolve_feed_package_url "$feed_name" "$package_name" 2>/dev/null || true)"
        if [ -n "$url" ]; then
            printf '%s\n' "$url"
            return 0
        fi
    done

    return 1
}

resolve_package_download_url() {
    package_name="$1"

    url="$(resolve_package_url_any_feed "$package_name" 2>/dev/null || true)"
    if [ -n "$url" ]; then
        printf '%s\n' "$url"
        return 0
    fi

    info="$(get_package_filename_and_feed_from_lists "$package_name" 2>/dev/null || true)"
    [ -n "$info" ] || return 1

    feed_name="${info%%|*}"
    filename="${info#*|}"
    [ -n "$feed_name" ] || return 1
    [ -n "$filename" ] || return 1

    feed_url="$(get_feed_url "$feed_name" 2>/dev/null || true)"
    [ -n "$feed_url" ] || return 1

    case "$filename" in
        http://*|https://*) printf '%s\n' "$filename" ;;
        *) printf '%s/%s\n' "${feed_url%/}" "${filename#./}" ;;
    esac
}

resolve_package_version_any_feed() {
    package_name="$1"
    feed_names="$(awk '$1=="src/gz" {print $2}' "$FEEDS" 2>/dev/null)"

    for feed_name in $feed_names; do
        [ -n "$feed_name" ] || continue
        ver="$(get_feed_package_field "$feed_name" "$package_name" Version 2>/dev/null || true)"
        if [ -n "$ver" ]; then
            printf '%s\n' "$ver"
            return 0
        fi
    done

    return 1
}

# 通用下载包装：统一日志、空值校验与下载完成校验。
download_url_to_file_or_die() {
    url="$1"
    dest="$2"
    label="$3"

    [ -n "$url" ] || die "missing download url for $label"
    log "Logs: downloading $label..."
    download_with_tool "$url" "$dest"
    [ -s "$dest" ] || die "$label download failed"
}

download_feed_package_or_die() {
    package_name="$1"
    dest="$2"
    label="${3:-$package_name}"

    pkg_url="$(resolve_package_download_url "$package_name" 2>/dev/null || true)"
    [ -n "$pkg_url" ] || die "failed to resolve $package_name package from feeds"
    download_url_to_file_or_die "$pkg_url" "$dest" "$label"
}

get_installed_or_feed_version() {
    package_name="$1"
    fallback="${2:-}"

    ver="$(opkg status "$package_name" 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$ver" ] || ver="$(resolve_package_version_any_feed "$package_name" 2>/dev/null || true)"
    [ -n "$ver" ] || ver="$fallback"
    [ -n "$ver" ] || ver='unknown'
    printf '%s\n' "$ver"
}


# 安装可选依赖，失败时只记录，不中断主流程。
ensure_packages() {
    missing=""
    for pkg in "$@"; do
        opkg status "$pkg" >/dev/null 2>&1 && continue
        opkg install "$pkg" >/tmp/NRadio_plugin-extra-install.log 2>&1 || missing="$missing $pkg"
    done

    if [ -n "$missing" ]; then
        log "warn: optional packages install failed:$missing"
    fi
}

# 安装必须依赖，任一失败则直接终止，避免后续步骤在半残状态下继续。
ensure_required_packages() {
    missing=""
    for pkg in "$@"; do
        opkg status "$pkg" >/dev/null 2>&1 && continue
        if ! opkg install "$pkg" >/tmp/NRadio_plugin-extra-install.log 2>&1; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        sed -n '1,160p' /tmp/NRadio_plugin-extra-install.log >&2
        die "required packages install failed:$missing"
    fi
}

get_openwrt_release_value() {
    key_name="$1"
    [ -f /etc/openwrt_release ] || return 1

    awk -F"'" -v key="$key_name" '
        $1 ~ ("^" key "=") {
            print $2
            exit
        }
    ' /etc/openwrt_release
}

get_openwrt_distrib_arch() {
    arch="$(get_openwrt_release_value DISTRIB_ARCH 2>/dev/null || true)"
    [ -n "$arch" ] || die 'failed to detect OpenWrt DISTRIB_ARCH'
    printf '%s\n' "$arch"
}

require_luci_controller_dir() {
    [ -d /usr/lib/lua/luci/controller ] || die 'LuCI controller directory missing; luci-base may not be installed'
}

require_free_space_mb() {
    target_path="$1"
    min_free_mb="$2"

    free_mb="$(df -m "$target_path" 2>/dev/null | awk 'END{print $4}')"
    case "$free_mb" in
        ''|*[!0-9]*)
            die "failed to detect free space for $target_path"
            ;;
    esac

    [ "$free_mb" -ge "$min_free_mb" ] || die "insufficient free space on $target_path (need ${min_free_mb} MiB)"
}

extract_tarball_archive() {
    archive_file="$1"
    out_dir="$2"

    rm -rf "$out_dir"
    mkdir -p "$out_dir"
    tar -xzf "$archive_file" -C "$out_dir" >/dev/null 2>&1 || die "failed to extract archive: $archive_file"
}

append_plugin_install_specs_from_glob() {
    pkg_glob="$1"
    pkg_label="$2"
    found=0

    for pkg_file in $pkg_glob; do
        [ -f "$pkg_file" ] || continue
        append_plugin_install_spec "$pkg_file" "$pkg_label"
        found=1
    done

    [ "$found" = "1" ] || die "missing package for pattern: $pkg_glob"
}

stop_service_if_present() {
    service_name="$1"
    [ -x "/etc/init.d/$service_name" ] || return 0
    "/etc/init.d/$service_name" stop >/dev/null 2>&1 || true
}

# 尝试正常安装；若包依赖与当前固件轻微不匹配，再降级为强制依赖安装。
install_ipk_file() {
    ipk="$1"
    label="$2"
    opkg install "$ipk" --force-reinstall >/tmp/NRadio_plugin-install.log 2>&1 || {
        opkg install "$ipk" --force-reinstall --force-depends >/tmp/NRadio_plugin-install.log 2>&1 || {
            sed -n '1,160p' /tmp/NRadio_plugin-install.log >&2
            die "$label install failed"
        }
    }
}

install_ipk_file_force_overwrite() {
    ipk="$1"
    label="$2"
    opkg install "$ipk" --force-reinstall --force-overwrite >/tmp/NRadio_plugin-install.log 2>&1 || {
        opkg install "$ipk" --force-reinstall --force-depends --force-overwrite >/tmp/NRadio_plugin-install.log 2>&1 || {
            sed -n '1,200p' /tmp/NRadio_plugin-install.log >&2
            die "$label install failed"
        }
    }
}

# 获取文件字节大小，避免在多个安装函数里重复写 wc/tr 组合。
file_size_bytes() {
    file_path="$1"
    wc -c < "$file_path" | tr -d ' '
}

# 对服务执行 enable + restart/start 兜底，减少安装函数中的重复逻辑。
enable_and_restart_service() {
    service_name="$1"
    /etc/init.d/"$service_name" enable >/dev/null 2>&1 || true
    /etc/init.d/"$service_name" restart >/dev/null 2>&1 || /etc/init.d/"$service_name" start >/dev/null 2>&1 || true
}

ensure_ttyd_uci_config() {
    [ -f /etc/config/ttyd ] || {
        mkdir -p /etc/config
        : > /etc/config/ttyd
    }

    if ! uci -q get ttyd.@ttyd[0] >/dev/null 2>&1; then
        backup_file /etc/config/ttyd
        sec="$(uci -q add ttyd ttyd 2>/dev/null || true)"
        [ -n "$sec" ] || sec='@ttyd[0]'
        uci -q set ttyd."$sec".enable='1' >/dev/null 2>&1 || true
        uci -q set ttyd."$sec".interface='@lan' >/dev/null 2>&1 || true
        uci -q set ttyd."$sec".command='/bin/login' >/dev/null 2>&1 || true
        uci -q commit ttyd >/dev/null 2>&1 || true
    fi
}

# 写入 ttyd 的 LuCI 兼容页面。
# 目标固件上的原版页面并不总能直接工作，因此这里统一覆盖为兼容封装页。
write_ttyd_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/ttyd

    cat > /usr/lib/lua/luci/controller/ttyd.lua <<'EOF'
module("luci.controller.ttyd", package.seeall)
local dispatcher = require "luci.dispatcher"

function index()
    local page = entry({"admin", "services", "ttyd"}, alias("admin", "services", "ttyd", "ttyd"), _("ttyd"), 15)
    page.dependent = true
    entry({"admin", "services", "ttyd", "ttyd"}, template("ttyd/oem_terminal"), _("Terminal"), 1).leaf = true
    entry({"admin", "services", "ttyd", "config"}, template("ttyd/oem_config"), _("Config"), 2).leaf = true
    entry({"admin", "services", "ttyd", "restart"}, call("restart")).leaf = true
end

function restart()
    local http = require "luci.http"
    os.execute("( /etc/init.d/ttyd restart >/dev/null 2>&1 || /etc/init.d/ttyd start >/dev/null 2>&1 ) &")
    http.redirect(dispatcher.build_url("admin", "services", "ttyd", "ttyd"))
end
EOF

    cat > /usr/lib/lua/luci/view/ttyd/oem_terminal.htm <<'EOF'
<%
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local dispatcher = require "luci.dispatcher"
local http = require "luci.http"
local port = uci:get("ttyd", "@ttyd[0]", "port") or "7681"
local is_embed = (http.formvalue("appcenter") == "1")
%>
<%+header%>
<style>
    .ttyd-shell { color: #10233a; }
    .ttyd-frame-wrap { position: relative; overflow: hidden; max-width: 100%; border: 1px solid #d6e3f5; border-radius: 22px; background: linear-gradient(180deg, #0f172a 0%, #111827 100%); box-shadow: 0 22px 40px rgba(15, 23, 42, 0.16); }
    .ttyd-frame-top { display: flex; align-items: center; justify-content: flex-start; gap: 12px; padding: 10px 14px; border-bottom: 1px solid rgba(255,255,255,.08); background: linear-gradient(90deg, rgba(2,6,23,.88), rgba(15,23,42,.88)); color: #dbeafe; }
    .ttyd-frame-dots { display: inline-flex; gap: 6px; }
    .ttyd-frame-dots i { width: 10px; height: 10px; border-radius: 999px; display: inline-block; }
    .ttyd-frame-dots i:nth-child(1) { background: #fb7185; }
    .ttyd-frame-dots i:nth-child(2) { background: #fbbf24; }
    .ttyd-frame-dots i:nth-child(3) { background: #34d399; }
    .ttyd-frame { display: block; width: 100%; min-height: 76vh; border: 0; background: #0b1120; }
<% if is_embed then %>
    html, body { height: 100%; }
    body { overflow: hidden; }
    header,.header,.navbar,.navbar-static-top,.navbar-fixed-top,.main-header,.topbar,.luci-header,.menu,.main-menu,.side-menu,.sidebar,.main-sidebar,.left-menu,.navigation,.nav-container,.menu_mobile,.footer,footer,.tail_wave { display: none !important; }
    .ttyd-shell { height: calc(100vh - 4px); }
    .ttyd-frame-wrap { display: flex; flex-direction: column; height: calc(100vh - 4px); }
    .ttyd-frame { flex: 1 1 auto; min-height: 0; height: calc(100vh - 48px); }
<% end %>
</style>
<div class="cbi-map ttyd-shell">
    <div class="ttyd-frame-wrap">
        <div class="ttyd-frame-top">
            <div class="ttyd-frame-dots"><i></i><i></i><i></i></div>
        </div>
        <iframe id="ttyd_frame" class="ttyd-frame" src="about:blank"></iframe>
    </div>
</div>
<script>
function getTtydUrl() {
    var proto = (window.location.protocol === 'https:') ? 'https://' : 'http://';
    return proto + window.location.hostname + ':<%=port%>/';
}
function loadTtydFrame() {
    var frame = document.getElementById('ttyd_frame');
    if (frame) frame.src = getTtydUrl();
}
function openTtydWindow() {
    window.open(getTtydUrl(), '_blank');
}
loadTtydFrame();
</script>
<%+footer%>
EOF

    cat > /usr/lib/lua/luci/view/ttyd/oem_config.htm <<'EOF'
<%
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local http = require "luci.http"
local port = uci:get("ttyd", "@ttyd[0]", "port") or "7681"
local interface = uci:get("ttyd", "@ttyd[0]", "interface") or "@lan"
local command = uci:get("ttyd", "@ttyd[0]", "command") or "/bin/login"
local enable = uci:get("ttyd", "@ttyd[0]", "enable") or "1"
local debug = util.trim(util.exec("sed -n '1,120p' /etc/config/ttyd 2>/dev/null || true"))
local is_embed = (http.formvalue("appcenter") == "1")
%>
<%+header%>
<style>
    .ttyd-shell { color: #10233a; }
<% if is_embed then %>
    header,.header,.navbar,.navbar-static-top,.navbar-fixed-top,.main-header,.topbar,.luci-header,.menu,.main-menu,.side-menu,.sidebar,.main-sidebar,.left-menu,.navigation,.nav-container,.menu_mobile,.footer,footer,.tail_wave { display: none !important; }
<% end %>
    .ttyd-hero { position: relative; overflow: hidden; margin: 12px 0 16px; padding: 24px 24px 20px; border: 1px solid #d6e3f5; border-radius: 22px; background: radial-gradient(circle at top right, rgba(14, 165, 233, 0.18), rgba(14, 165, 233, 0) 34%), radial-gradient(circle at left 20%, rgba(37, 99, 235, 0.14), rgba(37, 99, 235, 0) 28%), linear-gradient(135deg, #f6fbff 0%, #ffffff 48%, #f7fbff 100%); box-shadow: 0 18px 44px rgba(15, 23, 42, 0.08); }
    .ttyd-hero:before { content: ""; position: absolute; right: -48px; top: -48px; width: 180px; height: 180px; border-radius: 999px; background: radial-gradient(circle, rgba(59, 130, 246, 0.22) 0%, rgba(59, 130, 246, 0) 72%); }
    .ttyd-toolbar { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 10px; }
    .ttyd-pill { display: inline-flex; align-items: center; padding: 5px 12px; border-radius: 999px; background: #ebf5ff; color: #175cd3; font-size: 12px; font-weight: 700; letter-spacing: .03em; }
    .ttyd-title { margin: 0; font-size: 28px; line-height: 1.15; color: #0f172a; }
    .ttyd-sub { margin: 8px 0 0; max-width: 760px; color: #5f6f82; line-height: 1.75; }
    .ttyd-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px; margin-bottom: 16px; }
    .ttyd-metric { padding: 16px 18px; border: 1px solid #e5edf7; border-radius: 18px; background: linear-gradient(180deg, #ffffff 0%, #f9fcff 100%); box-shadow: 0 8px 18px rgba(15, 23, 42, 0.04); }
    .ttyd-metric-label { display: block; color: #738298; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; margin-bottom: 8px; }
    .ttyd-metric-value { display: block; color: #0f172a; font-size: 18px; font-weight: 700; word-break: break-all; }
    .ttyd-card { margin-bottom: 16px; padding: 18px; border: 1px solid #dbe8f6; border-radius: 20px; background: linear-gradient(180deg, #ffffff 0%, #f8fbff 100%); box-shadow: 0 12px 28px rgba(15, 23, 42, 0.05); }
    .ttyd-card-title { margin: 0 0 10px; font-size: 16px; font-weight: 700; color: #0f172a; }
    .ttyd-note { margin: 0; color: #64748b; line-height: 1.7; }
    .ttyd-pre { margin-top: 12px; padding: 14px 16px; border-radius: 16px; background: #0f172a; color: #dbeafe; white-space: pre-wrap; word-break: break-word; font-family: Menlo, Consolas, monospace; font-size: 12px; line-height: 1.6; }
</style>
<div class="cbi-map ttyd-shell">
    <div class="ttyd-hero">
        <div class="ttyd-toolbar"><span class="ttyd-pill">NROS Service Profile</span></div>
        <h2 class="ttyd-title" name="content">ttyd 配置概览</h2>
        <p class="ttyd-sub">保留鲲鹏 NROS 风格的浅色科技仪表板布局，把核心运行参数和配置文件内容汇总到一个页面里，便于排查和快速确认服务状态。</p>
    </div>
    <div class="ttyd-grid">
        <div class="ttyd-metric"><span class="ttyd-metric-label">Enabled</span><span class="ttyd-metric-value"><%=pcdata(enable)%></span></div>
        <div class="ttyd-metric"><span class="ttyd-metric-label">Port</span><span class="ttyd-metric-value"><%=pcdata(port)%></span></div>
        <div class="ttyd-metric"><span class="ttyd-metric-label">Interface</span><span class="ttyd-metric-value"><%=pcdata(interface)%></span></div>
        <div class="ttyd-metric"><span class="ttyd-metric-label">Command</span><span class="ttyd-metric-value"><%=pcdata(command)%></span></div>
    </div>
    <div class="ttyd-card">
        <div class="ttyd-card-title">兼容说明</div>
        <p class="ttyd-note">当前固件的 LuCI 与官方 ttyd 新版页面结构不兼容时，这里会显示兼容摘要页。需要更细的配置时，可以直接编辑 <code>/etc/config/ttyd</code>。</p>
    </div>
    <div class="ttyd-card">
        <div class="ttyd-card-title">/etc/config/ttyd</div>
        <div class="ttyd-pre"><%=pcdata(debug ~= "" and debug or "no config")%></div>
    </div>
</div>
<%+footer%>
EOF
}

write_openlist_wrapper_files() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/openlist2

    cat > /usr/lib/lua/luci/controller/openlist2.lua <<'EOF'
module("luci.controller.openlist2", package.seeall)
local dispatcher = require "luci.dispatcher"

function index()
    local page = entry({"admin", "services", "openlist2"}, alias("admin", "services", "openlist2", "basic"), _("OpenList"), 55)
    page.dependent = true
    entry({"admin", "services", "openlist2", "basic"}, template("openlist2/oem_web"), _("OpenList"), 1).leaf = true
    entry({"admin", "services", "openlist2", "config"}, template("openlist2/oem_config"), _("Config"), 2).leaf = true
    entry({"admin", "services", "openlist2", "restart"}, call("restart")).leaf = true
end

function restart()
    local http = require "luci.http"
    os.execute("( /etc/init.d/openlist2 restart >/dev/null 2>&1 || /etc/init.d/openlist2 start >/dev/null 2>&1 ) &")
    http.redirect(dispatcher.build_url("admin", "services", "openlist2", "basic"))
end
EOF

    cat > /usr/lib/lua/luci/view/openlist2/oem_web.htm <<'EOF'
<%
local uci = require "luci.model.uci".cursor()
local http = require "luci.http"
local dispatcher = require "luci.dispatcher"
local site_url = uci:get("openlist2", "@openlist2[0]", "site_url") or ""
local port = uci:get("openlist2", "@openlist2[0]", "port") or "5244"
local ssl = uci:get("openlist2", "@openlist2[0]", "ssl") or "0"
local is_embed = (http.formvalue("appcenter") == "1")
local protocol = (ssl == "1") and "https://" or "http://"
local web_url = site_url ~= "" and site_url or (protocol .. http.getenv("SERVER_NAME") .. ":" .. port .. "/")
%>
<%+header%>
<style>
    .openlist-shell { color: #10233a; }
    .openlist-hero { position: relative; overflow: hidden; margin: 12px 0 16px; padding: 24px 24px 20px; border: 1px solid #d6e3f5; border-radius: 22px; background: radial-gradient(circle at top right, rgba(22, 163, 74, 0.16), rgba(22, 163, 74, 0) 34%), radial-gradient(circle at left 20%, rgba(59, 130, 246, 0.14), rgba(59, 130, 246, 0) 28%), linear-gradient(135deg, #f7fff9 0%, #ffffff 48%, #f7fbff 100%); box-shadow: 0 18px 44px rgba(15, 23, 42, 0.08); }
    .openlist-toolbar { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 10px; }
    .openlist-pill { display: inline-flex; align-items: center; padding: 5px 12px; border-radius: 999px; background: #ecfdf3; color: #15803d; font-size: 12px; font-weight: 700; letter-spacing: .03em; }
    .openlist-title { margin: 0; font-size: 28px; line-height: 1.15; color: #0f172a; }
    .openlist-sub { margin: 8px 0 0; max-width: 820px; color: #5f6f82; line-height: 1.75; }
    .openlist-actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 16px; }
    .openlist-btn { display: inline-flex; align-items: center; justify-content: center; min-width: 148px; padding: 10px 16px; border-radius: 12px; border: 1px solid #16a34a; background: #16a34a; color: #fff !important; font-weight: 700; text-decoration: none !important; box-shadow: 0 10px 24px rgba(22,163,74,.18); }
    .openlist-btn-secondary { border-color: #d6e3f5; background: #fff; color: #0f172a !important; box-shadow: none; }
    .openlist-frame-wrap { position: relative; overflow: hidden; max-width: 100%; border: 1px solid #d6e3f5; border-radius: 22px; background: #ffffff; box-shadow: 0 22px 40px rgba(15, 23, 42, 0.10); display: flex; flex-direction: column; }
    .openlist-frame-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 14px; border-bottom: 1px solid #e5edf7; background: linear-gradient(90deg, #f8fafc, #f1f5f9); color: #0f172a; }
    .openlist-frame-dots { display: inline-flex; gap: 6px; }
    .openlist-frame-dots i { width: 10px; height: 10px; border-radius: 999px; display: inline-block; }
    .openlist-frame-dots i:nth-child(1) { background: #fb7185; }
    .openlist-frame-dots i:nth-child(2) { background: #fbbf24; }
    .openlist-frame-dots i:nth-child(3) { background: #34d399; }
    .openlist-frame-label { font-size: 13px; color: #64748b; }
    .openlist-frame { display: block; width: 100%; min-height: 640px; height: calc(100vh - 260px); border: 0; background: #fff; flex: 1 1 auto; }
<% if is_embed then %>
    html, body { height: 100%; }
    body { overflow: hidden; }
    header,.header,.navbar,.navbar-static-top,.navbar-fixed-top,.main-header,.topbar,.luci-header,.menu,.main-menu,.side-menu,.sidebar,.main-sidebar,.left-menu,.navigation,.nav-container,.menu_mobile,.footer,footer,.tail_wave { display: none !important; }
    .openlist-shell { height: calc(100vh - 4px); display: flex; flex-direction: column; }
    .openlist-hero { display: none; }
    .openlist-frame-wrap { display: flex; flex-direction: column; height: calc(100vh - 4px); border-radius: 18px; }
    .openlist-frame { flex: 1 1 auto; min-height: 0; height: auto; }
<% end %>
</style>
<div class="cbi-map openlist-shell">
    <div class="openlist-hero">
        <div class="openlist-toolbar"><span class="openlist-pill">OpenList Service Hub</span></div>
        <h2 class="openlist-title" name="content">OpenList 管理面板</h2>
        <p class="openlist-sub">当前固件对 luci-app-openlist2 的原生 JS 路由兼容性较弱，这里改为提供一个稳定的兼容入口，直接嵌入 OpenList Web 界面，避免在 AppCenter 中出现空白页。</p>
        <div class="openlist-actions">
            <a class="openlist-btn" href="<%=web_url%>" target="_blank" rel="noreferrer">打开 Web 界面</a>
            <a class="openlist-btn openlist-btn-secondary" href="<%=dispatcher.build_url("admin", "services", "openlist2", "config")%>">查看配置</a>
        </div>
    </div>
    <div class="openlist-frame-wrap">
        <div class="openlist-frame-top">
            <div class="openlist-frame-dots"><i></i><i></i><i></i></div>
            <div class="openlist-frame-label"><%=web_url%></div>
        </div>
        <iframe id="openlist_frame" class="openlist-frame" src="about:blank"></iframe>
    </div>
</div>
<script>
(function() {
    var frame = document.getElementById('openlist_frame');
    function resizeFrame() {
        if (!frame) return;
        try {
            var doc = frame.contentWindow && frame.contentWindow.document;
            if (!doc || !doc.body || !doc.documentElement) return;
            var bodyHeight = doc.body.scrollHeight || 0;
            var docHeight = doc.documentElement.scrollHeight || 0;
            var nextHeight = bodyHeight > docHeight ? bodyHeight : docHeight;
            if (nextHeight > 0) frame.style.height = nextHeight + 'px';
        } catch (e) {}
    }
    if (frame) {
        frame.onload = function() {
            resizeFrame();
            setTimeout(resizeFrame, 180);
            setTimeout(resizeFrame, 600);
        };
        frame.src = '<%=web_url%>';
    }
})();
</script>
<%+footer%>
EOF

    cat > /usr/lib/lua/luci/view/openlist2/oem_config.htm <<'EOF'
<%
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local http = require "luci.http"
local port = uci:get("openlist2", "@openlist2[0]", "port") or "5244"
local enabled = uci:get("openlist2", "@openlist2[0]", "enabled") or "1"
local allow_wan = uci:get("openlist2", "@openlist2[0]", "allow_wan") or "0"
local data_dir = uci:get("openlist2", "@openlist2[0]", "data_dir") or "/etc/openlist2"
local temp_dir = uci:get("openlist2", "@openlist2[0]", "temp_dir") or "/tmp/openlist2"
local site_url = uci:get("openlist2", "@openlist2[0]", "site_url") or ""
local log_path = uci:get("openlist2", "@openlist2[0]", "log_path") or "/var/log/openlist2.log"
local is_embed = (http.formvalue("appcenter") == "1")
local debug = util.trim(util.exec("sed -n '1,160p' /etc/config/openlist2 2>/dev/null || true"))
%>
<%+header%>
<style>
    .openlist-config-shell { color: #10233a; }
<% if is_embed then %>
    header,.header,.navbar,.navbar-static-top,.navbar-fixed-top,.main-header,.topbar,.luci-header,.menu,.main-menu,.side-menu,.sidebar,.main-sidebar,.left-menu,.navigation,.nav-container,.menu_mobile,.footer,footer,.tail_wave { display: none !important; }
<% end %>
    .openlist-config-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-bottom: 16px; }
    .openlist-config-card { padding: 16px 18px; border: 1px solid #e5edf7; border-radius: 18px; background: linear-gradient(180deg, #ffffff 0%, #f9fcff 100%); box-shadow: 0 8px 18px rgba(15, 23, 42, 0.04); }
    .openlist-config-label { display: block; color: #738298; font-size: 12px; text-transform: uppercase; letter-spacing: .06em; margin-bottom: 8px; }
    .openlist-config-value { display: block; color: #0f172a; font-size: 18px; font-weight: 700; word-break: break-all; }
    .openlist-config-box { margin-bottom: 16px; padding: 18px; border: 1px solid #dbe8f6; border-radius: 20px; background: linear-gradient(180deg, #ffffff 0%, #f8fbff 100%); box-shadow: 0 12px 28px rgba(15, 23, 42, 0.05); }
    .openlist-config-title { margin: 0 0 10px; font-size: 16px; font-weight: 700; color: #0f172a; }
    .openlist-config-note { margin: 0; color: #64748b; line-height: 1.7; }
    .openlist-config-pre { margin-top: 12px; padding: 14px 16px; border-radius: 16px; background: #0f172a; color: #dbeafe; white-space: pre-wrap; word-break: break-word; font-family: Menlo, Consolas, monospace; font-size: 12px; line-height: 1.6; }
</style>
<div class="cbi-map openlist-config-shell">
    <div class="openlist-config-grid">
        <div class="openlist-config-card"><span class="openlist-config-label">Enabled</span><span class="openlist-config-value"><%=pcdata(enabled)%></span></div>
        <div class="openlist-config-card"><span class="openlist-config-label">Port</span><span class="openlist-config-value"><%=pcdata(port)%></span></div>
        <div class="openlist-config-card"><span class="openlist-config-label">Allow WAN</span><span class="openlist-config-value"><%=pcdata(allow_wan)%></span></div>
        <div class="openlist-config-card"><span class="openlist-config-label">Site URL</span><span class="openlist-config-value"><%=pcdata(site_url ~= "" and site_url or "auto")%></span></div>
        <div class="openlist-config-card"><span class="openlist-config-label">Data Dir</span><span class="openlist-config-value"><%=pcdata(data_dir)%></span></div>
        <div class="openlist-config-card"><span class="openlist-config-label">Temp Dir</span><span class="openlist-config-value"><%=pcdata(temp_dir)%></span></div>
        <div class="openlist-config-card"><span class="openlist-config-label">Log Path</span><span class="openlist-config-value"><%=pcdata(log_path)%></span></div>
    </div>
    <div class="openlist-config-box">
        <div class="openlist-config-title">兼容说明</div>
        <p class="openlist-config-note">当前固件未正确加载 luci-app-openlist2 原生 JS 路由，这里提供的是兼容配置页与 Web 面板入口。需要更细粒度配置时，可以直接编辑 <code>/etc/config/openlist2</code>。</p>
    </div>
    <div class="openlist-config-box">
        <div class="openlist-config-title">/etc/config/openlist2</div>
        <div class="openlist-config-pre"><%=pcdata(debug ~= "" and debug or "no config")%></div>
    </div>
</div>
<%+footer%>
EOF
}

# 在 appcenter 的 UCI 配置中查找指定 name 对应的 section。
find_uci_section() {
    sec_type="$1"
    pkg_name="$2"

    uci show appcenter 2>/dev/null | awk -v st="$sec_type" -v n="$pkg_name" '
        $0 ~ ("^appcenter\\.@" st "\\[[0-9]+\\]=" st "$") {
            line = $0
            sub(/^appcenter\./, "", line)
            sub(/=.*/, "", line)
            sec = line
            next
        }
        sec != "" && $0 == ("appcenter." sec ".name='\''" n "'\''") {
            print sec
            exit
        }
    '
}

# 清理同一路由的旧菜单项，避免重复注入后在 AppCenter 中出现重复入口。
cleanup_appcenter_route_entries() {
    target_route="$1"
    extra_route="${2:-}"
    extra_route2="${3:-}"

    uci show appcenter 2>/dev/null | awk -v route="$target_route" -v extra="$extra_route" -v extra2="$extra_route2" '
        /^appcenter\.@package_list\[[0-9]+\]=package_list$/ {
            sec=$1
            sub(/^appcenter\./, "", sec)
            sub(/=.*/, "", sec)
            current=sec
            next
        }
        current != "" && ($0 == ("appcenter." current ".luci_module_route='"'"'" route "'"'"'") || (extra != "" && $0 == ("appcenter." current ".luci_module_route='"'"'" extra "'"'"'")) || (extra2 != "" && $0 == ("appcenter." current ".luci_module_route='"'"'" extra2 "'"'"'"))) {
            print current
            current=""
        }
    ' | while IFS= read -r list_sec; do
        [ -n "$list_sec" ] || continue
        old_name="$(uci -q get "appcenter.$list_sec.name" 2>/dev/null || true)"
        if [ -n "$old_name" ]; then
            pkg_sec="$(find_uci_section package "$old_name")"
            [ -n "$pkg_sec" ] && uci delete "appcenter.$pkg_sec" >/dev/null 2>&1 || true
        fi
        uci delete "appcenter.$list_sec" >/dev/null 2>&1 || true
    done
}

# 向 appcenter 注册插件展示信息；package 与 package_list 两类 section 需要同时维护。
set_appcenter_entry() {
    plugin_name="$1"
    pkg_name="$2"
    version="$3"
    size="$4"
    controller_file="$5"
    route="$6"
    description="$7"

    require_safe_uci_value "plugin name" "$plugin_name"
    require_safe_uci_value "package name" "$pkg_name"
    require_safe_uci_value "version" "$version"
    require_safe_uci_value "size" "$size"
    require_safe_uci_value "controller file" "$controller_file"
    require_safe_uci_value "route" "$route"
    require_safe_uci_value "description" "$description"

    cleanup_extra_route=""
    cleanup_extra_route2=""
    if [ "$plugin_name" = "OpenClash" ]; then
        cleanup_extra_route="admin/services/openclash"
        cleanup_extra_route2="admin/services/openclash/client"
    fi
    cleanup_appcenter_route_entries "$route" "$cleanup_extra_route" "$cleanup_extra_route2"

    pkg_sec="$(find_uci_section package "$plugin_name")"
    [ -n "$pkg_sec" ] || pkg_sec="$(uci add appcenter package)"

    list_sec="$(find_uci_section package_list "$plugin_name")"
    [ -n "$list_sec" ] || list_sec="$(uci add appcenter package_list)"

    uci set "appcenter.$pkg_sec.name=$plugin_name"
    uci set "appcenter.$pkg_sec.version=$version"
    uci set "appcenter.$pkg_sec.size=$size"
    uci set "appcenter.$pkg_sec.status=1"
    uci set "appcenter.$pkg_sec.has_luci=1"
    uci set "appcenter.$pkg_sec.open=1"
    uci set "appcenter.$pkg_sec.des=$description"

    uci set "appcenter.$list_sec.name=$plugin_name"
    uci set "appcenter.$list_sec.pkg_name=$pkg_name"
    uci set "appcenter.$list_sec.parent=$plugin_name"
    uci set "appcenter.$list_sec.size=$size"
    uci set "appcenter.$list_sec.luci_module_file=$controller_file"
    uci set "appcenter.$list_sec.luci_module_route=$route"
    uci set "appcenter.$list_sec.version=$version"
    uci set "appcenter.$list_sec.has_luci=1"
    uci set "appcenter.$list_sec.type=1"
    uci set "appcenter.$list_sec.des=$description"
}

# 完成 UCI 注册后刷新 LuCI/AppCenter 缓存，不改动 AppCenter 页面模板或系统主题样式。
register_appcenter_plugin() {
    plugin_name="$1"
    pkg_name="$2"
    version="$3"
    size="$4"
    controller_file="$5"
    route="$6"
    description="$7"

    backup_file "$CFG"
    set_appcenter_entry "$plugin_name" "$pkg_name" "$version" "$size" "$controller_file" "$route" "$description"
    uci commit appcenter

    refresh_luci_appcenter
    verify_appcenter_route "$plugin_name" "$route"
}

refresh_luci_appcenter() {
    rm -f /tmp/luci-indexcache /tmp/infocd/cache/appcenter 2>/dev/null || true
    rm -f /tmp/luci-modulecache/* 2>/dev/null || true
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    /etc/init.d/infocd stop >/dev/null 2>&1 || true
    killall infocd infocd_consumer 2>/dev/null || true
    /etc/init.d/infocd start >/dev/null 2>&1 || true
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    /etc/init.d/appcenter stop >/dev/null 2>&1 || true
    killall appcenter 2>/dev/null || true
    /etc/init.d/appcenter start >/dev/null 2>&1 || /etc/init.d/appcenter restart >/dev/null 2>&1 || true
    sleep 2
}

verify_appcenter_route() {
    plugin_name="$1"
    expect_route="$2"
    sec="$(find_uci_section package_list "$plugin_name")"
    [ -n "$sec" ] || die "$plugin_name verify failed: appcenter package_list missing"
    actual_route="$(uci -q get appcenter.$sec.luci_module_route 2>/dev/null || true)"
    [ "$actual_route" = "$expect_route" ] || die "$plugin_name verify failed: appcenter route mismatch ($actual_route)"
}

verify_ttyd_route() {
    verify_appcenter_route "TTYD" "admin/services/ttyd/ttyd"
}

verify_kms_route() {
    verify_appcenter_route "KMS" "admin/services/vlmcsd"
}

get_openclash_core_arch() {
    machine="$(uname -m 2>/dev/null || true)"
    case "$machine" in
        x86_64) printf '%s\n' amd64 ;;
        i386|i686) printf '%s\n' 386 ;;
        aarch64|arm64) printf '%s\n' arm64 ;;
        armv7l|armv7) printf '%s\n' armv7 ;;
        armv6l|armv6) printf '%s\n' armv6 ;;
        armv5tel|armv5*) printf '%s\n' armv5 ;;
        mips64el|mips64le) printf '%s\n' mips64le ;;
        mips64) printf '%s\n' mips64 ;;
        mipsel|mipsle)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mipsle-softfloat
            else
                printf '%s\n' mipsle-hardfloat
            fi
            ;;
        mips)
            if opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /_sf$/ {found=1} END{exit found?0:1}'; then
                printf '%s\n' mips-softfloat
            else
                printf '%s\n' mips-hardfloat
            fi
            ;;
        *) return 1 ;;
    esac
}

parse_openclash_smart_core_version() {
    version_file="$1"
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /smart/) {
                    print $i
                    exit
                }
            }
        }
    ' "$version_file"
}

install_openclash_smart_core() {
    core_arch="$(get_openclash_core_arch 2>/dev/null || true)"
    [ -n "$core_arch" ] || {
        log "warn: failed to detect OpenClash smart core architecture"
        return 1
    }

    mkdir -p "$WORKDIR/openclash/core" /etc/openclash/core
    core_version_file="$WORKDIR/openclash/core_version"
    smart_core_tar="$WORKDIR/openclash/clash-linux-${core_arch}.tar.gz"
    smart_core_dir="/etc/openclash/core"
    old_download_max_time="$DOWNLOAD_MAX_TIME"
    DOWNLOAD_MAX_TIME="$OPENCLASH_CORE_DOWNLOAD_MAX_TIME"

    log "Logs: downloading OpenClash smart core version file..."
    download_from_mirrors "core_version" "$core_version_file" "$OPENCLASH_CORE_VERSION_MIRRORS" validate_nonempty_file >/dev/null || {
        log "warn: failed to fetch OpenClash smart core version file"
        DOWNLOAD_MAX_TIME="$old_download_max_time"
        return 1
    }
    smart_core_ver="$(parse_openclash_smart_core_version "$core_version_file" | tr -d '\r\n')"
    [ -n "$smart_core_ver" ] || smart_core_ver="$(sed -n '1p' "$core_version_file" | tr -d '\r\n')"
    [ -n "$smart_core_ver" ] || {
        log "warn: failed to parse OpenClash smart core version"
        DOWNLOAD_MAX_TIME="$old_download_max_time"
        return 1
    }

    log "Logs: downloading OpenClash smart core $smart_core_ver for $core_arch..."
    download_from_mirrors "clash-linux-${core_arch}.tar.gz" "$smart_core_tar" "$OPENCLASH_CORE_SMART_MIRRORS" validate_gzip_tar_file >/dev/null || {
        log "warn: failed to fetch OpenClash smart core"
        DOWNLOAD_MAX_TIME="$old_download_max_time"
        return 1
    }
    [ -s "$smart_core_tar" ] || {
        log "warn: OpenClash smart core download failed"
        DOWNLOAD_MAX_TIME="$old_download_max_time"
        return 1
    }

    tar -xzf "$smart_core_tar" -C "$smart_core_dir" >/dev/null 2>&1 || {
        log "warn: failed to extract OpenClash smart core"
        DOWNLOAD_MAX_TIME="$old_download_max_time"
        return 1
    }
    smart_core_entry="$(tar -tzf "$smart_core_tar" 2>/dev/null | awk 'NF && $0 !~ /\/$/ && $0 ~ /(^|\/)clash([._-]|$)/ { print; exit }')"
    [ -n "$smart_core_entry" ] || smart_core_entry="$(tar -tzf "$smart_core_tar" 2>/dev/null | awk 'NF && $0 !~ /\/$/ { print; exit }')"
    smart_core_entry_target="${smart_core_entry#./}"
    smart_core_binary="$(basename "$smart_core_entry_target" 2>/dev/null || true)"
    [ -n "$smart_core_binary" ] || {
        log "warn: failed to locate extracted smart core binary"
        DOWNLOAD_MAX_TIME="$old_download_max_time"
        return 1
    }

    [ "$smart_core_binary" = "clash_meta" ] || mv -f "$smart_core_dir/$smart_core_entry_target" "$smart_core_dir/clash_meta" 2>/dev/null || ln -sf "$smart_core_entry_target" "$smart_core_dir/clash_meta"
    [ -e "$smart_core_dir/clash" ] || ln -sf clash_meta "$smart_core_dir/clash"
    chmod 755 "$smart_core_dir"/clash* 2>/dev/null || true

    printf '%s\n%s\n' "$(sed -n '1p' "$core_version_file")" "$(sed -n '2p' "$core_version_file")" > /etc/openclash/core_version
    chmod 644 /etc/openclash/core_version 2>/dev/null || true
    DOWNLOAD_MAX_TIME="$old_download_max_time"
}

fix_openclash_luci_compat() {
    oc_overwrite="/usr/lib/lua/luci/model/cbi/openclash/config-overwrite.lua"
    [ -f "$oc_overwrite" ] || return 0
    if grep -q 'datatype.cidr4(value)' "$oc_overwrite"; then
        backup_file "$oc_overwrite"
        sed -i 's/if datatype.cidr4(value) then/if ((datatype.cidr4 and datatype.cidr4(value)) or (datatype.ipmask4 and datatype.ipmask4(value))) then/' "$oc_overwrite"
    fi
}

fix_openclash_tab_visibility() {
    oc_controller="/usr/lib/lua/luci/controller/openclash.lua"
    [ -f "$oc_controller" ] || return 0
    grep -q '\.leaf = true' "$oc_controller" 2>/dev/null || return 0

    backup_file "$oc_controller"
    sed -i \
        -e '/entry({"admin", "services", "openclash", "client"}/s/\.leaf = true/.leaf = false/' \
        -e '/entry({"admin", "services", "openclash", "settings"}/s/\.leaf = true/.leaf = false/' \
        -e '/entry({"admin", "services", "openclash", "config-overwrite"}/s/\.leaf = true/.leaf = false/' \
        -e '/entry({"admin", "services", "openclash", "config-subscribe"}/s/\.leaf = true/.leaf = false/' \
        -e '/entry({"admin", "services", "openclash", "config"}/s/\.leaf = true/.leaf = false/' \
        -e '/entry({"admin", "services", "openclash", "log"}/s/\.leaf = true/.leaf = false/' \
        "$oc_controller"
}

remove_legacy_openclash_template_overrides() {
    legacy_switch="/usr/lib/lua/luci/view/openclash/switch_dashboard.htm"
    if [ -f "$legacy_switch" ] && grep -q 'Update Metacubexd Version' "$legacy_switch" 2>/dev/null; then
        backup_file "$legacy_switch"
        rm -f "$legacy_switch"
    fi

    legacy_settings="/usr/lib/lua/luci/model/cbi/openclash/settings.lua"
    if [ -f "$legacy_settings" ] && grep -q '^[[:space:]]*o.rawhtml = true[[:space:]]*$' "$legacy_settings" 2>/dev/null; then
        backup_file "$legacy_settings"
        sed -i '/^[[:space:]]*o.rawhtml = true[[:space:]]*$/d' "$legacy_settings"
    fi
}

remove_openclash_embed_chrome_guard_file() {
    target="$1"
    [ -f "$target" ] || return 1
    grep -q 'NRADIO_OPENCLASH_EMBED_CHROME_GUARD' "$target" || return 0

    mkdir -p "$WORKDIR/openclash/theme"
    tmp="$WORKDIR/openclash/theme/$(basename "$target").unembed"
    backup_file "$target"

    awk '
        BEGIN { skip = 0; count = 0 }
        NR == 1 && $0 == "<!-- NRADIO_OPENCLASH_EMBED_CHROME_GUARD -->" {
            skip = 1
            count = 5
            next
        }
        skip && count > 0 {
            count--
            next
        }
        {
            lines[++n] = $0
        }
        END {
            if (n > 0 && lines[n] == "<% end %>")
                n--
            for (i = 1; i <= n; i++)
                print lines[i]
        }
    ' "$target" > "$tmp" || return 1

    mv "$tmp" "$target"
}

remove_openclash_embed_chrome_guard() {
    theme_path="$(uci -q get luci.main.mediaurlbase 2>/dev/null || true)"
    theme_name="${theme_path##*/}"

    for target in \
        "/usr/lib/lua/luci/view/themes/$theme_name/header.htm" \
        "/usr/lib/lua/luci/view/themes/$theme_name/footer.htm" \
        /usr/lib/lua/luci/view/header.htm \
        /usr/lib/lua/luci/view/footer.htm
    do
        [ -n "$target" ] || continue
        remove_openclash_embed_chrome_guard_file "$target" || true
    done
}

apply_openclash_all_fix() {
    sed -i \
        -e 's#/usr/lib/lua/luci/controller/nradio_adv/openclash_full.lua#/usr/lib/lua/luci/controller/openclash.lua#g' \
        -e 's#nradioadv/system/openclashfull#admin/services/openclash-nradio#g' \
        -e 's#admin/services/openclash/client'\''#admin/services/openclash-nradio'\''#g' \
        -e 's#admin/services/openclash'\''#admin/services/openclash-nradio'\''#g' \
        "$CFG" 2>/dev/null || true
}

write_openclash_nradio_entry() {
    mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/openclash
    backup_file /usr/lib/lua/luci/controller/openclash_nradio.lua
    backup_file /usr/lib/lua/luci/view/openclash/nradio_tabs.htm

    cat > /usr/lib/lua/luci/controller/openclash_nradio.lua <<'EOF'
module("luci.controller.openclash_nradio", package.seeall)

function index()
    local page = entry({"admin", "services", "openclash-nradio"}, template("openclash/nradio_tabs"), _("OpenClash"), 50)
    page.dependent = true
end
EOF

    cat > /usr/lib/lua/luci/view/openclash/nradio_tabs.htm <<'EOF'
<%+header%>
<style type="text/css">
:root{color-scheme:dark;}
.nradio-oc-wrap{display:flex;flex-direction:column;min-height:calc(100vh - 120px);}
.nradio-oc-tabs{
    position:sticky;top:0;z-index:20;
    display:flex;flex-wrap:wrap;gap:6px;
    margin:0 0 12px;padding:8px 0 10px;
    background:#292932;border-bottom:1px solid #41414e;
}
.nradio-oc-tab{
    display:inline-flex;align-items:center;justify-content:center;
    min-height:30px;padding:6px 12px;
    border:1px solid transparent;border-radius:6px;
    background:transparent;color:#aeb2b8;
    font-size:12px;line-height:1;white-space:nowrap;
    text-decoration:none;cursor:pointer;
    transition:color .16s ease,background-color .16s ease,border-color .16s ease;
}
.nradio-oc-tab:hover{background:rgba(26,182,255,.08);color:#1ab6ff;border-color:rgba(26,182,255,.28);text-decoration:none;}
.nradio-oc-tab.active{background:rgba(26,182,255,.14);color:#8bdcff;border-color:#1ab6ff;}
.nradio-oc-frame{
    display:block;width:100%;height:620px;min-height:480px;
    border:0;background:transparent;overflow:visible;box-sizing:border-box;
}
@media(max-width:768px){
    .nradio-oc-wrap{min-height:calc(100vh - 130px);}
    .nradio-oc-tabs{flex-wrap:nowrap;overflow-x:auto;overflow-y:hidden;padding:6px 0 8px;scrollbar-width:none;}
    .nradio-oc-tabs::-webkit-scrollbar{display:none;}
    .nradio-oc-tab{flex:0 0 auto;padding:6px 10px;}
    .nradio-oc-frame{height:480px;min-height:420px;}
}
@media(prefers-reduced-motion:reduce){.nradio-oc-tab{transition:none;}}
</style>
<div class="nradio-oc-wrap">
    <div class="nradio-oc-tabs" id="nradio_oc_tabs" role="tablist" aria-label="OpenClash 导航">
        <a class="nradio-oc-tab active" role="tab" aria-selected="true" href="<%=url('admin/services/openclash/client')%>?nradio_embed=1" data-route="<%=url('admin/services/openclash/client')%>?nradio_embed=1">运行状态</a>
        <a class="nradio-oc-tab" role="tab" aria-selected="false" href="<%=url('admin/services/openclash/settings')%>?nradio_embed=1" data-route="<%=url('admin/services/openclash/settings')%>?nradio_embed=1">插件设置</a>
        <a class="nradio-oc-tab" role="tab" aria-selected="false" href="<%=url('admin/services/openclash/config-overwrite')%>?nradio_embed=1" data-route="<%=url('admin/services/openclash/config-overwrite')%>?nradio_embed=1">覆写设置</a>
        <a class="nradio-oc-tab" role="tab" aria-selected="false" href="<%=url('admin/services/openclash/config-subscribe')%>?nradio_embed=1" data-route="<%=url('admin/services/openclash/config-subscribe')%>?nradio_embed=1">配置订阅</a>
        <a class="nradio-oc-tab" role="tab" aria-selected="false" href="<%=url('admin/services/openclash/config')%>?nradio_embed=1" data-route="<%=url('admin/services/openclash/config')%>?nradio_embed=1">配置管理</a>
        <a class="nradio-oc-tab" role="tab" aria-selected="false" href="<%=url('admin/services/openclash/log')%>?nradio_embed=1" data-route="<%=url('admin/services/openclash/log')%>?nradio_embed=1">运行日志</a>
    </div>
    <iframe class="nradio-oc-frame" id="nradio_oc_frame" src="<%=url('admin/services/openclash/client')%>?nradio_embed=1"></iframe>
</div>
<script type="text/javascript">//<![CDATA[
(function(){
    var tabs = document.querySelectorAll('#nradio_oc_tabs .nradio-oc-tab');
    var frame = document.getElementById('nradio_oc_frame');
    var layoutTimer = null;
    var refreshTimer = null;
    var resizeObserver = null;
    var mutationObserver = null;
    var attempts = 0;

    function getFrameDocument() {
        try {
            var d = frame.contentWindow && frame.contentWindow.document;
            if (!d || !d.head || !d.body)
                return null;
            return d;
        }
        catch(e) {
            return null;
        }
    }

    function cleanFrameChrome() {
        var d = getFrameDocument();
        if (!d)
            return;
        try {
            var style = d.getElementById('nradio_oc_frame_chrome_fix');
            if (!style) {
                style = d.createElement('style');
                style.id = 'nradio_oc_frame_chrome_fix';
                style.type = 'text/css';
                style.textContent = [
                    'header,.header,.navbar,.navbar-static-top,.navbar-fixed-top,.main-header,.topbar,.luci-header{display:none!important;}',
                    '.menu,.main-menu,.side-menu,.sidebar,.main-sidebar,.left-menu,.navigation,.nav-container,.menu_mobile{display:none!important;}',
                    '.footer,footer,.tail_wave{display:none!important;}',
                    'html,body{margin-top:0!important;padding-top:0!important;}',
                    'main,.main,.main-content,#maincontent,#maincontainer{height:auto!important;min-height:0!important;max-height:none!important;overflow:visible!important;}',
                    '.cbi-map,.cbi-section,.panel,.container-fluid{height:auto!important;max-height:none!important;overflow:visible!important;}'
                ].join('');
                d.head.appendChild(style);
            }
        }
        catch(e) {}
    }

    function getContentHeight() {
        var d = getFrameDocument();
        if (!d)
            return 0;
        try {
            var root = d.documentElement;
            var body = d.body;
            var heights = [
                root ? root.offsetHeight : 0,
                body ? body.scrollHeight : 0,
                body ? body.offsetHeight : 0
            ];
            return Math.max.apply(Math, heights);
        }
        catch(e) {
            return 0;
        }
    }

    function resizeFrame() {
        var next = getContentHeight();
        var min = window.matchMedia && window.matchMedia('(max-width: 768px)').matches ? 420 : 480;
        if (next > 0) {
            frame.style.height = Math.max(min, Math.ceil(next + 20)) + 'px';
        }
    }

    function refreshFrameLayout() {
        cleanFrameChrome();
        resizeFrame();
    }

    function scheduleRefresh() {
        if (refreshTimer)
            window.clearTimeout(refreshTimer);
        refreshTimer = window.setTimeout(refreshFrameLayout, 80);
    }

    function stopWatchers() {
        if (layoutTimer) {
            window.clearInterval(layoutTimer);
            layoutTimer = null;
        }
        if (refreshTimer) {
            window.clearTimeout(refreshTimer);
            refreshTimer = null;
        }
        if (resizeObserver) {
            resizeObserver.disconnect();
            resizeObserver = null;
        }
        if (mutationObserver) {
            mutationObserver.disconnect();
            mutationObserver = null;
        }
        attempts = 0;
    }

    function watchFrameLayout() {
        stopWatchers();
        layoutTimer = window.setInterval(function() {
            refreshFrameLayout();
            attempts++;
            if (attempts >= 24) {
                window.clearInterval(layoutTimer);
                layoutTimer = null;
            }
        }, 500);

        try {
            var d = getFrameDocument();
            if (!d || !d.body)
                return;

            if (window.ResizeObserver) {
                resizeObserver = new ResizeObserver(scheduleRefresh);
                resizeObserver.observe(d.body);
            }
            if (window.MutationObserver) {
                mutationObserver = new MutationObserver(scheduleRefresh);
                mutationObserver.observe(d.body, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['style', 'class']
                });
            }
        }
        catch(e) {}
    }

    for (var i = 0; i < tabs.length; i++) {
        tabs[i].onclick = function() {
            for (var j = 0; j < tabs.length; j++) tabs[j].className = tabs[j].className.replace(/\s*active/g, '');
            for (var k = 0; k < tabs.length; k++) tabs[k].setAttribute('aria-selected', 'false');
            this.className += ' active';
            this.setAttribute('aria-selected', 'true');
            stopWatchers();
            frame.src = this.getAttribute('data-route');
            frame.style.height = '';
            return false;
        };
    }

    frame.onload = function() {
        stopWatchers();
        refreshFrameLayout();
        watchFrameLayout();
    };

    if (window.addEventListener) {
        window.addEventListener('resize', scheduleRefresh);
        window.addEventListener('beforeunload', stopWatchers);
    }
})();
//]]></script>
<%+footer%>
EOF
}

write_openclash_alias_controller() {
    mkdir -p /usr/lib/lua/luci/controller/nradio_adv
    backup_file /usr/lib/lua/luci/controller/nradio_adv/openclash_alias.lua
    cat > /usr/lib/lua/luci/controller/nradio_adv/openclash_alias.lua <<'EOF'
module("luci.controller.nradio_adv.openclash_alias", package.seeall)

function index()
    local page = entry({"nradio", "advanced", "openclash"}, alias("admin", "services", "openclash-nradio"), _("OpenClash"), 60)
    page.dependent = true
end
EOF
}

reset_plugin_install_context() {
    INSTALL_CTX_NAME=""
    INSTALL_CTX_PKG_NAME=""
    INSTALL_CTX_VERSION=""
    INSTALL_CTX_SIZE=""
    INSTALL_CTX_CONTROLLER_FILE=""
    INSTALL_CTX_ROUTE=""
    INSTALL_CTX_DESCRIPTION=""
    INSTALL_CTX_NEXT_HINT=""
    INSTALL_CTX_ALIAS=""
    INSTALL_CTX_WORKDIRS="$WORKDIR"
    INSTALL_CTX_NEEDS_OPKG_UPDATE="0"
    INSTALL_CTX_DOWNLOAD_SPECS=""
    INSTALL_CTX_INSTALL_SPECS=""
}

append_plugin_download_spec() {
    spec_kind="$1"
    spec_ref="$2"
    spec_dest="$3"
    spec_label="$4"

    spec_line="${spec_kind}|${spec_ref}|${spec_dest}|${spec_label}"
    if [ -n "$INSTALL_CTX_DOWNLOAD_SPECS" ]; then
        INSTALL_CTX_DOWNLOAD_SPECS="${INSTALL_CTX_DOWNLOAD_SPECS}
${spec_line}"
    else
        INSTALL_CTX_DOWNLOAD_SPECS="${spec_line}"
    fi
}

append_plugin_install_spec() {
    spec_ipk="$1"
    spec_label="$2"

    spec_line="${spec_ipk}|${spec_label}"
    if [ -n "$INSTALL_CTX_INSTALL_SPECS" ]; then
        INSTALL_CTX_INSTALL_SPECS="${INSTALL_CTX_INSTALL_SPECS}
${spec_line}"
    else
        INSTALL_CTX_INSTALL_SPECS="${spec_line}"
    fi
}

download_plugin_spec_list() {
    spec_list="$1"
    [ -n "$spec_list" ] || return 0

    printf '%s\n' "$spec_list" | while IFS='|' read -r spec_kind spec_ref spec_dest spec_label; do
        [ -n "$spec_kind" ] || continue
        case "$spec_kind" in
            feed) download_feed_package_or_die "$spec_ref" "$spec_dest" "$spec_label" ;;
            url) download_url_to_file_or_die "$spec_ref" "$spec_dest" "$spec_label" ;;
            *) die "unsupported download spec kind: $spec_kind" ;;
        esac
    done
}

install_plugin_spec_list() {
    spec_list="$1"
    [ -n "$spec_list" ] || return 0

    printf '%s\n' "$spec_list" | while IFS='|' read -r spec_ipk spec_label; do
        [ -n "$spec_ipk" ] || continue
        install_ipk_file "$spec_ipk" "$spec_label"
    done
}

# 统一安装模板：
# 1. 公共前置校验与工作目录准备
# 2. 插件专属下载/安装钩子
# 3. AppCenter 注册与统一日志收尾
run_plugin_install_flow() {
    plugin_key="$1"

    reset_plugin_install_context
    require_file "$CFG"

    "${plugin_key}_setup_install"

    mkdir -p $INSTALL_CTX_WORKDIRS
    [ "$INSTALL_CTX_NEEDS_OPKG_UPDATE" = "1" ] && ensure_opkg_update

    "${plugin_key}_plan_downloads"
    download_plugin_spec_list "$INSTALL_CTX_DOWNLOAD_SPECS"
    log "Logs: installing ${INSTALL_CTX_NAME} and registering AppCenter entry..."
    "${plugin_key}_prepare_install"
    "${plugin_key}_plan_installs"
    install_plugin_spec_list "$INSTALL_CTX_INSTALL_SPECS"
    "${plugin_key}_post_install"
    "${plugin_key}_finalize_metadata"

    [ -n "$INSTALL_CTX_NAME" ] || die "install context missing plugin name for $plugin_key"
    [ -n "$INSTALL_CTX_PKG_NAME" ] || die "install context missing package name for $plugin_key"
    [ -n "$INSTALL_CTX_VERSION" ] || die "install context missing version for $plugin_key"
    [ -n "$INSTALL_CTX_SIZE" ] || die "install context missing size for $plugin_key"
    [ -n "$INSTALL_CTX_CONTROLLER_FILE" ] || die "install context missing controller file for $plugin_key"
    [ -n "$INSTALL_CTX_ROUTE" ] || die "install context missing route for $plugin_key"
    [ -n "$INSTALL_CTX_DESCRIPTION" ] || die "install context missing description for $plugin_key"

    register_appcenter_plugin \
        "$INSTALL_CTX_NAME" \
        "$INSTALL_CTX_PKG_NAME" \
        "$INSTALL_CTX_VERSION" \
        "$INSTALL_CTX_SIZE" \
        "$INSTALL_CTX_CONTROLLER_FILE" \
        "$INSTALL_CTX_ROUTE" \
        "$INSTALL_CTX_DESCRIPTION"

    "${plugin_key}_after_register"
    log_plugin_install_result
}

log_plugin_install_result() {
    log 'done'
    log "plugin:   $INSTALL_CTX_NAME"
    log "version:  $INSTALL_CTX_VERSION"
    log "route:    $INSTALL_CTX_ROUTE"
    [ -n "$INSTALL_CTX_ALIAS" ] && log "alias:    $INSTALL_CTX_ALIAS"
    [ -n "$INSTALL_CTX_NEXT_HINT" ] && log "next:     $INSTALL_CTX_NEXT_HINT"
}

ttyd_setup_install() {
    INSTALL_CTX_NAME="TTYD"
    INSTALL_CTX_PKG_NAME="luci-app-ttyd"
    INSTALL_CTX_ROUTE="admin/services/ttyd/ttyd"
    INSTALL_CTX_DESCRIPTION="本地调试利器"
    INSTALL_CTX_NEXT_HINT="close appcenter popup, then press Ctrl+F5 and reopen ttyd"
    INSTALL_CTX_WORKDIRS="$WORKDIR"
    INSTALL_CTX_NEEDS_OPKG_UPDATE="1"
}

ttyd_plan_downloads() {
    ttyd_ipk="$WORKDIR/ttyd.ipk"
    luci_ttyd_ipk="$WORKDIR/luci-app-ttyd.ipk"

    append_plugin_download_spec feed ttyd "$ttyd_ipk" 'ttyd core package'
    append_plugin_download_spec feed luci-app-ttyd "$luci_ttyd_ipk" 'ttyd LuCI package'
}

ttyd_prepare_install() {
    :
}

ttyd_plan_installs() {
    append_plugin_install_spec "$ttyd_ipk" "ttyd"
    append_plugin_install_spec "$luci_ttyd_ipk" "luci-app-ttyd"
}

ttyd_post_install() {
    ensure_ttyd_uci_config
    enable_and_restart_service ttyd

    backup_file /usr/lib/lua/luci/controller/ttyd.lua
    backup_file /usr/lib/lua/luci/view/ttyd/oem_terminal.htm
    backup_file /usr/lib/lua/luci/view/ttyd/oem_config.htm
    write_ttyd_wrapper_files
}

ttyd_finalize_metadata() {
    INSTALL_CTX_CONTROLLER_FILE="/usr/lib/lua/luci/controller/ttyd.lua"
    [ -f "$INSTALL_CTX_CONTROLLER_FILE" ] || die 'ttyd controller file missing after install'

    INSTALL_CTX_VERSION="$(get_installed_or_feed_version luci-app-ttyd)"
    INSTALL_CTX_SIZE="$(file_size_bytes "$luci_ttyd_ipk")"
}

ttyd_after_register() {
    :
}

kms_setup_install() {
    INSTALL_CTX_NAME="KMS"
    INSTALL_CTX_PKG_NAME="luci-app-vlmcsd"
    INSTALL_CTX_ROUTE="admin/services/vlmcsd"
    INSTALL_CTX_DESCRIPTION="局域网内Windows系列工具激活神器"
    INSTALL_CTX_NEXT_HINT="close appcenter popup, then press Ctrl+F5 and reopen KMS"
    INSTALL_CTX_WORKDIRS="$WORKDIR"
    INSTALL_CTX_NEEDS_OPKG_UPDATE="1"

    kms_core_pkg='vlmcsd'
    kms_luci_pkg='luci-app-vlmcsd'
}

kms_plan_downloads() {
    kms_arch="$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" { arch=$2 } END { print arch }')"
    [ -n "$kms_arch" ] || die 'failed to detect current OpenWrt package architecture for KMS core'

    kms_core_file="vlmcsd_${KMS_CORE_VERSION}_${kms_arch}.ipk"
    [ -n "$KMS_LUCI_IPK_URL" ] || die 'failed to resolve KMS LuCI package url'
    kms_luci_file="${KMS_LUCI_IPK_URL##*/}"
    kms_core_base="${KMS_CORE_IPK_BASE_URL%/}"
    kms_luci_base="${KMS_LUCI_IPK_URL%/*}"
    kms_core_mirrors=""
    kms_luci_mirrors=""

    for proxy in $KMS_GH_PROXIES; do
        [ -n "$proxy" ] || continue
        case "$proxy" in
            */) proxy_core_base="${proxy}${kms_core_base}" ;;
            *) proxy_core_base="${proxy}/${kms_core_base}" ;;
        esac
        [ -n "$kms_core_mirrors" ] && kms_core_mirrors="$kms_core_mirrors $proxy_core_base" || kms_core_mirrors="$proxy_core_base"
        case "$proxy" in
            */) proxy_luci_base="${proxy}${kms_luci_base}" ;;
            *) proxy_luci_base="${proxy}/${kms_luci_base}" ;;
        esac
        [ -n "$kms_luci_mirrors" ] && kms_luci_mirrors="$kms_luci_mirrors $proxy_luci_base" || kms_luci_mirrors="$proxy_luci_base"
    done
    [ -n "$kms_core_mirrors" ] && kms_core_mirrors="$kms_core_mirrors $kms_core_base" || kms_core_mirrors="$kms_core_base"
    [ -n "$kms_luci_mirrors" ] && kms_luci_mirrors="$kms_luci_mirrors $kms_luci_base" || kms_luci_mirrors="$kms_luci_base"

    kms_core_ipk="$WORKDIR/${kms_core_pkg}.ipk"
    kms_luci_ipk="$WORKDIR/${kms_luci_pkg}.ipk"
}

kms_prepare_install() {
    old_download_max_time="$DOWNLOAD_MAX_TIME"
    DOWNLOAD_MAX_TIME="$KMS_DOWNLOAD_MAX_TIME"

    log "Logs: downloading KMS core package..."
    kms_core_base="$(download_from_mirrors "$kms_core_file" "$kms_core_ipk" "$kms_core_mirrors" validate_nonempty_file 0 || true)"
    log "Logs: downloading KMS LuCI package..."
    kms_luci_base="$(download_from_mirrors "$kms_luci_file" "$kms_luci_ipk" "$kms_luci_mirrors" validate_nonempty_file 0 || true)"

    DOWNLOAD_MAX_TIME="$old_download_max_time"
    [ -n "$kms_core_base" ] || die 'KMS core package download failed from all mirrors'
    [ -n "$kms_luci_base" ] || die 'KMS LuCI package download failed from all mirrors'
}

kms_plan_installs() {
    append_plugin_install_spec "$kms_core_ipk" "$kms_core_pkg"
    append_plugin_install_spec "$kms_luci_ipk" "$kms_luci_pkg"
}

kms_post_install() {
    enable_and_restart_service vlmcsd
}

kms_finalize_metadata() {
    INSTALL_CTX_CONTROLLER_FILE=""
    for candidate in \
        /usr/lib/lua/luci/controller/vlmcsd.lua \
        /usr/lib/lua/luci/controller/kms.lua \
        /usr/share/luci/menu.d/luci-app-vlmcsd.json; do
        if [ -f "$candidate" ]; then
            INSTALL_CTX_CONTROLLER_FILE="$candidate"
            break
        fi
    done
    [ -n "$INSTALL_CTX_CONTROLLER_FILE" ] || die 'KMS controller file missing after install'

    INSTALL_CTX_VERSION="$(get_installed_or_feed_version "$kms_luci_pkg")"
    INSTALL_CTX_SIZE="$(file_size_bytes "$kms_luci_ipk")"
}

kms_after_register() {
    :
}

openclash_setup_install() {
    INSTALL_CTX_NAME="OpenClash"
    INSTALL_CTX_PKG_NAME="luci-app-openclash"
    INSTALL_CTX_ROUTE="admin/services/openclash-nradio"
    INSTALL_CTX_DESCRIPTION="超级好用的养猫插件"
    INSTALL_CTX_NEXT_HINT="close appcenter popup, then press Ctrl+F5 and reopen OpenClash"
    INSTALL_CTX_ALIAS="nradio/advanced/openclash"
    INSTALL_CTX_WORKDIRS="$WORKDIR $WORKDIR/openclash/pkg $WORKDIR/openclash/control"
    INSTALL_CTX_NEEDS_OPKG_UPDATE="0"
}

openclash_plan_downloads() {
    version_file="$WORKDIR/openclash/version"
    raw_ipk="$WORKDIR/openclash/openclash.ipk"

    log "Logs: downloading OpenClash version file..."
    mirror_base="$(download_from_mirrors "version" "$version_file" "$OPENCLASH_MIRRORS" validate_nonempty_file 0)" || die "failed to fetch OpenClash version from mirrors"
    last_ver="$(sed -n '1p' "$version_file" | sed 's/^v//g' | tr -d '\r\n')"
    [ -n "$last_ver" ] || die "failed to parse OpenClash version"

    openclash_ipk_file="luci-app-openclash_${last_ver}_all.ipk"
    openclash_ipk_mirrors="$mirror_base"
    openclash_raw_base="https://raw.githubusercontent.com/vernesong/OpenClash/package/${OPENCLASH_BRANCH}"
    for proxy in $OPENCLASH_GH_PROXIES; do
        [ -n "$proxy" ] || continue
        case "$proxy" in
            */) openclash_ipk_mirrors="$openclash_ipk_mirrors ${proxy}${openclash_raw_base}" ;;
            *) openclash_ipk_mirrors="$openclash_ipk_mirrors ${proxy}/${openclash_raw_base}" ;;
        esac
    done
    openclash_ipk_mirrors="$openclash_ipk_mirrors $openclash_raw_base"
    for base_url in $OPENCLASH_MIRRORS; do
        case " $openclash_ipk_mirrors " in
            *" $base_url "*) ;;
            *) openclash_ipk_mirrors="$openclash_ipk_mirrors $base_url" ;;
        esac
    done
}

openclash_prepare_install() {
    log "Logs: downloading OpenClash v$last_ver package..."
    old_download_max_time="$DOWNLOAD_MAX_TIME"
    DOWNLOAD_MAX_TIME="$OPENCLASH_PACKAGE_DOWNLOAD_MAX_TIME"
    openclash_pkg_base="$(download_from_mirrors "$openclash_ipk_file" "$raw_ipk" "$openclash_ipk_mirrors" validate_nonempty_file 0 || true)"
    DOWNLOAD_MAX_TIME="$old_download_max_time"
    [ -n "$openclash_pkg_base" ] || die "OpenClash package download failed from all mirrors"
    [ -s "$raw_ipk" ] || die "OpenClash package download failed"

    ensure_opkg_update
    ensure_required_packages dnsmasq-full bash curl ca-bundle ip-full ruby ruby-yaml kmod-inet-diag kmod-nft-tproxy kmod-tun unzip
    remove_legacy_openclash_template_overrides
}

openclash_plan_installs() {
    append_plugin_install_spec "$raw_ipk" "luci-app-openclash"
}

openclash_post_install() {
    # 保留 OpenClash 页面模板原样，只修复当前固件上确认必要的 LuCI 兼容点。
    apply_openclash_all_fix
    fix_openclash_luci_compat
    fix_openclash_tab_visibility
    write_openclash_nradio_entry
    remove_openclash_embed_chrome_guard
    write_openclash_alias_controller
}

openclash_finalize_metadata() {
    INSTALL_CTX_VERSION="$(opkg status luci-app-openclash 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$INSTALL_CTX_VERSION" ] || INSTALL_CTX_VERSION="$last_ver"
    INSTALL_CTX_SIZE="$(file_size_bytes "$raw_ipk")"
    INSTALL_CTX_CONTROLLER_FILE="/usr/lib/lua/luci/controller/openclash_nradio.lua"
    [ -f "$INSTALL_CTX_CONTROLLER_FILE" ] || die "OpenClash controller file missing after install"
    [ -f /usr/lib/lua/luci/view/openclash/nradio_tabs.htm ] || die "OpenClash NRadio tab view missing after install"
}

openclash_after_register() {
    if [ "${INSTALL_OPENCLASH_SMART_CORE:-0}" = "1" ] && confirm_default_yes "是否继续下载 OpenClash smart 核心？"; then
        install_openclash_smart_core || {
            log 'warn: OpenClash smart core download/install failed; LuCI package has been installed, please install core later from OpenClash page'
            return 0
        }
    fi
}

openlist_setup_install() {
    INSTALL_CTX_NAME="OpenList"
    INSTALL_CTX_PKG_NAME="luci-app-openlist2"
    INSTALL_CTX_ROUTE="admin/services/openlist2/basic"
    INSTALL_CTX_DESCRIPTION="Alist:一个支持多种存储的文件列表程序"
    INSTALL_CTX_NEXT_HINT="close appcenter popup, then press Ctrl+F5 and reopen OpenList"
    INSTALL_CTX_WORKDIRS="$WORKDIR $WORKDIR/openlist"
    INSTALL_CTX_NEEDS_OPKG_UPDATE="0"
}

openlist_plan_downloads() {
    openlist_arch="$(get_openwrt_distrib_arch)"
    openlist_pkg_file="${OPENLIST_RELEASE_SDK}-${openlist_arch}.tar.gz"
    openlist_archive="$WORKDIR/openlist/${openlist_pkg_file}"
    openlist_extract_dir="$WORKDIR/openlist/release"
    openlist_origin_base="${OPENLIST_RELEASE_BASE_URL%/}"
    openlist_origin_url="${openlist_origin_base}/${openlist_pkg_file}"
    openlist_mirrors=""
    proxy_candidates="$OPENLIST_GH_PROXY"

    for proxy in $OPENLIST_GH_PROXIES; do
        case " $proxy_candidates " in
            *" $proxy "*) ;;
            *) proxy_candidates="$proxy_candidates $proxy" ;;
        esac
    done
    for proxy in $proxy_candidates; do
        [ -n "$proxy" ] || continue
        case "$proxy" in
            */) proxy_base="${proxy}${openlist_origin_base}" ;;
            *) proxy_base="${proxy}/${openlist_origin_base}" ;;
        esac
        case " $openlist_mirrors " in
            *" $proxy_base "*) ;;
            *) [ -n "$openlist_mirrors" ] && openlist_mirrors="$openlist_mirrors $proxy_base" || openlist_mirrors="$proxy_base" ;;
        esac
    done
    [ -n "$openlist_mirrors" ] && openlist_mirrors="$openlist_mirrors $openlist_origin_base" || openlist_mirrors="$openlist_origin_base"

    openlist_pkg_url="$(printf '%s\n' $openlist_mirrors | sed -n '1p')/${openlist_pkg_file}"
}

openlist_prepare_install() {
    require_luci_controller_dir
    require_free_space_mb /usr "$OPENLIST_MIN_FREE_MB"

    log "Logs: downloading OpenList package archive..."
    old_download_max_time="$DOWNLOAD_MAX_TIME"
    DOWNLOAD_MAX_TIME="$OPENLIST_DOWNLOAD_MAX_TIME"
    mirror_base="$(download_from_mirrors "$openlist_pkg_file" "$openlist_archive" "$openlist_mirrors" validate_gzip_tar_file 0 || true)"
    DOWNLOAD_MAX_TIME="$old_download_max_time"
    [ -n "$mirror_base" ] || die "OpenList package archive download failed from all mirrors"
    [ -s "$openlist_archive" ] || die "OpenList package archive download failed"
    log "Logs: OpenList archive fetched from $mirror_base/$openlist_pkg_file"

    stop_service_if_present openlist
    stop_service_if_present openlist2

    extract_tarball_archive "$openlist_archive" "$openlist_extract_dir"
    rm -f /tmp/luci-* 2>/dev/null || true
}

openlist_plan_installs() {
    openlist_pkg_dir="$openlist_extract_dir/packages_ci"
    [ -d "$openlist_pkg_dir" ] || die "OpenList package directory missing: $openlist_pkg_dir"

    append_plugin_install_specs_from_glob "$openlist_pkg_dir/openlist2*.*" "openlist2"
    append_plugin_install_specs_from_glob "$openlist_pkg_dir/luci-app-openlist2*.*" "luci-app-openlist2"

    openlist_i18n_ipk=""
    for pkg_file in "$openlist_pkg_dir"/luci-i18n-openlist2-zh-cn*.*; do
        [ -f "$pkg_file" ] || continue
        openlist_i18n_ipk="$pkg_file"
        append_plugin_install_spec "$pkg_file" "luci-i18n-openlist2-zh-cn"
    done
}

ensure_openlist_uci_config() {
    [ -f /etc/config/openlist2 ] || return 0

    if ! uci -q get openlist2.@openlist2[0] >/dev/null 2>&1; then
        sec="$(uci -q add openlist2 openlist2 2>/dev/null || true)"
        [ -n "$sec" ] || sec='@openlist2[0]'
    else
        sec='@openlist2[0]'
    fi

    backup_file /etc/config/openlist2
    uci -q set openlist2."$sec".enabled='1' >/dev/null 2>&1 || true
    uci -q set openlist2."$sec".allow_wan='0' >/dev/null 2>&1 || true
    uci -q commit openlist2 >/dev/null 2>&1 || true
}

openlist_post_install() {
    backup_file /usr/lib/lua/luci/controller/openlist2.lua
    backup_file /usr/lib/lua/luci/view/openlist2/oem_web.htm
    backup_file /usr/lib/lua/luci/view/openlist2/oem_config.htm
    write_openlist_wrapper_files
    ensure_openlist_uci_config
    enable_and_restart_service openlist2
}

openlist_finalize_metadata() {
    INSTALL_CTX_VERSION="$(opkg status luci-app-openlist2 2>/dev/null | awk -F': ' '/Version: /{print $2; exit}')"
    [ -n "$INSTALL_CTX_VERSION" ] || INSTALL_CTX_VERSION='unknown'
    INSTALL_CTX_CONTROLLER_FILE="/usr/lib/lua/luci/controller/openlist2.lua"
    [ -f "$INSTALL_CTX_CONTROLLER_FILE" ] || die 'OpenList controller file missing after install'

    openlist_luci_ipk=""
    for pkg_file in "$openlist_extract_dir"/packages_ci/luci-app-openlist2*.*; do
        [ -f "$pkg_file" ] || continue
        openlist_luci_ipk="$pkg_file"
        break
    done
    [ -n "$openlist_luci_ipk" ] || die 'OpenList LuCI package missing after extract'
    INSTALL_CTX_SIZE="$(file_size_bytes "$openlist_luci_ipk")"
}

openlist_after_register() {
    log 'warn: OpenList upstream service initializes with a default admin password; please change it immediately after first login'
}

install_ttyd() {
    run_plugin_install_flow ttyd
}

install_kms() {
    run_plugin_install_flow kms
}

install_openclash() {
    run_plugin_install_flow openclash
}

install_openlist() {
    run_plugin_install_flow openlist
}

refresh_sources() {
    require_root
    ensure_default_feeds >/dev/null
    ensure_opkg_update
    feed_url="$(get_feed_url openwrt_packages 2>/dev/null || true)"
    log "Logs: opkg feeds ready via ${feed_url:-unknown}"
}

show_menu() {
    printf '1. 安装 ttyd\n'
    printf '2. 安装 OpenClash\n'
    printf '3. 安装 KMS\n'
    printf '4. 安装 OpenList\n'
    printf '5. 更新软件源\n'
    printf '请选择 [1-5]: '
    read -r choice
    case "$choice" in
        1) install_ttyd ;;
        2) install_openclash ;;
        3) install_kms ;;
        4) install_openlist ;;
        5) refresh_sources ;;
        *) die 'invalid choice' ;;
    esac
}

# 安装模式统一要求 root。
prepare_runtime() {
    require_root
    ensure_default_feeds
}

main() {
    prepare_runtime "${1:-}"
    case "${1:-}" in
        ttyd)
            install_ttyd
            ;;
        openclash)
            install_openclash
            ;;
        kms)
            install_kms
            ;;
        openlist)
            install_openlist
            ;;
        sources|feeds|mirror)
            refresh_sources
            ;;
        "" )
            show_menu
            ;;
        *) die 'usage: NRadio_plugin [ttyd|openclash|kms|openlist]' ;;
    esac
}

main "$@"
