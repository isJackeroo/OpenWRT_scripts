#!/bin/sh
#
# install.sh - 一键安装 eMMC 检测工具（脚本 + LuCI 页面）
#
# 安装内容:
#   /usr/bin/emmcinfo.sh                        eMMC 信息采集脚本
#   /usr/lib/lua/luci/controller/emmcinfo.lua   LuCI 控制器
#   /usr/lib/lua/luci/view/emmcinfo/status.htm  LuCI 页面
#
# 用法:
#   sh install.sh

set -eu

EMMCINFO_BIN="/usr/bin/emmcinfo.sh"
LUCI_CTRL="/usr/lib/lua/luci/controller/emmcinfo.lua"
LUCI_VIEW="/usr/lib/lua/luci/view/emmcinfo/status.htm"

log() {
    echo "[install.sh] $*"
}

# 设备没有 eMMC 时直接终止，不执行后续任何安装动作
has_emmc() {
    for sysdev in /sys/block/mmcblk*; do
        [ -e "$sysdev" ] || continue
        name=${sysdev##*/}
        case "$name" in
            *p[0-9]*|*boot[0-9]|*rpmb*) continue ;;
        esac
        if [ "$(cat "$sysdev/device/type" 2>/dev/null)" = "MMC" ]; then
            return 0
        fi
    done
    return 1
}

if ! has_emmc; then
    log "错误：未检测到 eMMC 设备，安装终止"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    log "错误：请以 root 权限运行（OpenWrt 上默认 root）"
    exit 1
fi

if [ ! -f /etc/openwrt_release ]; then
    log "警告：未检测到 /etc/openwrt_release，当前可能不是 OpenWrt 系统" >&2
fi

mkdir -p /usr/bin
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/view/emmcinfo

cat > "$EMMCINFO_BIN" <<'EMMCINFO_SH_EOF'
#!/bin/sh
# eMMC Info & Health Check
# OpenWrt/BusyBox 兼容：不依赖 bash、coreutils、固定 mmcblk 序号
#
# 用法:
#   emmcinfo.sh                         输出可读文本
#   emmcinfo.sh --json                  输出 JSON，供 LuCI/脚本调用
#   emmcinfo.sh --device /dev/mmcblk0   指定 eMMC 设备
#   emmcinfo.sh --test-size 128         设置写入/读取测试大小 (MB)
#   emmcinfo.sh --list                  列出检测到的 eMMC 设备
#   环境变量: EMMC_TEST_FILE, EMMC_TEST_SIZE_MB

set -u

TMP_FILE="${EMMC_TEST_FILE:-/tmp/emmc_test.img}"
TEST_SIZE_MB="${EMMC_TEST_SIZE_MB:-256}"
JSON_OUT=0
LIST_ONLY=0
DEV=""

WARNINGS_TEXT=""
WARNINGS_JSON=""

# 基本信息
MODEL=""
CID=""
DATE_FMT=""
CAPACITY=""
FWREV=""
HWREV=""
MANFID=""
OEMID=""
PRV=""
SERIAL=""

# 寿命
A_HEX=""
B_HEX=""
A_PCT=""
B_PCT=""
EOL=""
EOL_STR="N/A"

# 速度
WRITE_LINE=""
READ_LINE=""
HDPARM_LINES=""
WRITE_SPEED=""
READ_SPEED=""
HDPARM_CACHED=""
HDPARM_BUFFERED=""

usage() {
    cat <<'EOF'
用法: emmcinfo.sh [选项]
  --json              输出 JSON
  --device <设备>     指定 eMMC 设备，如 /dev/mmcblk0
  --test-size <MB>    设置速度测试大小（默认 256MB）
  --list              列出检测到的 eMMC 设备
  -h, --help          显示帮助
环境变量:
  EMMC_TEST_FILE      速度测试临时文件路径
  EMMC_TEST_SIZE_MB   速度测试大小 (MB)
EOF
}

esc() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/\t/\\t/g' \
        -e 's/\r/\\r/g'
}

warn_add() {
    [ -n "$1" ] || return 0
    if [ -z "$WARNINGS_TEXT" ]; then
        WARNINGS_TEXT=$1
    else
        WARNINGS_TEXT="$WARNINGS_TEXT
$1"
    fi
    if [ -z "$WARNINGS_JSON" ]; then
        WARNINGS_JSON="\"$(esc "$1")\""
    else
        WARNINGS_JSON="$WARNINGS_JSON,\"$(esc "$1")\""
    fi
}

list_emmc() {
    found=0
    for sysdev in /sys/block/mmcblk*; do
        [ -e "$sysdev" ] || continue
        name=${sysdev##*/}
        case "$name" in
            *p[0-9]*|*boot[0-9]|*rpmb*) continue ;;
        esac
        if [ "$(cat "$sysdev/device/type" 2>/dev/null)" = "MMC" ]; then
            printf '/dev/%s\n' "$name"
            found=1
        fi
    done
    if [ "$found" -eq 1 ]; then
        return 0
    fi
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) JSON_OUT=1 ;;
        --list) LIST_ONLY=1 ;;
        --device)
            DEV=${2:-}
            if [ -z "$DEV" ]; then
                echo "[ERROR] --device 需要设备参数" >&2
                exit 1
            fi
            shift
            ;;
        --test-size)
            TEST_SIZE_MB=${2:-}
            if [ -z "$TEST_SIZE_MB" ]; then
                echo "[ERROR] --test-size 需要大小参数 (MB)" >&2
                exit 1
            fi
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "[ERROR] 未知参数: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$TEST_SIZE_MB" in
    ''|*[!0-9]*)
        echo "[ERROR] 无效的测试大小: $TEST_SIZE_MB" >&2
        exit 1
        ;;
esac
[ "$TEST_SIZE_MB" -gt 0 ] || {
    echo "[ERROR] 测试大小必须大于 0" >&2
    exit 1
}

if [ "$LIST_ONLY" -eq 1 ]; then
    list_emmc
    exit $?
fi

if [ -z "$DEV" ]; then
    DEV=$(list_emmc | head -n 1)
fi

if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    if [ "$JSON_OUT" -eq 1 ]; then
        printf '{"error":"no eMMC device found"}\n'
    else
        echo "[ERROR] No valid eMMC device found!"
    fi
    exit 1
fi

DEV_BASENAME=${DEV##*/}
SYS="/sys/block/$DEV_BASENAME/device"

if [ "$(cat "$SYS/type" 2>/dev/null)" != "MMC" ]; then
    if [ "$JSON_OUT" -eq 1 ]; then
        printf '{"error":"%s is not an MMC device"}\n' "$DEV"
    else
        echo "[ERROR] $DEV is not an MMC device!"
    fi
    exit 1
fi

MODEL=$(cat "$SYS/name" 2>/dev/null)
CID=$(cat "$SYS/cid" 2>/dev/null)
DATE_RAW=$(cat "$SYS/date" 2>/dev/null)
FWREV=$(cat "$SYS/fwrev" 2>/dev/null)
HWREV=$(cat "$SYS/hwrev" 2>/dev/null)
MANFID=$(cat "$SYS/manfid" 2>/dev/null)
OEMID=$(cat "$SYS/oemid" 2>/dev/null)
PRV=$(cat "$SYS/prv" 2>/dev/null)
SERIAL=$(cat "$SYS/serial" 2>/dev/null)

case "$DATE_RAW" in
    */*)
        MONTH=${DATE_RAW%%/*}
        YEAR=${DATE_RAW##*/}
        DATE_FMT=$(printf '%04d-%02d' "$YEAR" "$MONTH" 2>/dev/null)
        [ -n "$DATE_FMT" ] || DATE_FMT="$DATE_RAW"
        ;;
    *) DATE_FMT="$DATE_RAW" ;;
esac
[ -n "$DATE_FMT" ] || DATE_FMT="Unknown"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
[ -n "$TIMESTAMP" ] || TIMESTAMP="Unknown"

SIZE_SECTORS=$(cat "/sys/block/$DEV_BASENAME/size" 2>/dev/null)
case "$SIZE_SECTORS" in
    ''|*[!0-9]*) CAPACITY="Unknown" ;;
    *)
        BYTES=$((SIZE_SECTORS * 512))
        MIB=$((1024 * 1024))
        GIB=$((MIB * 1024))
        if [ "$BYTES" -ge "$GIB" ]; then
            CAPACITY=$(awk -v b="$BYTES" -v g="$GIB" 'BEGIN { printf "%.2f GB", b / g }')
        elif [ "$BYTES" -ge "$MIB" ]; then
            CAPACITY=$(awk -v b="$BYTES" -v m="$MIB" 'BEGIN { printf "%.2f MB", b / m }')
        else
            CAPACITY="${BYTES} Bytes"
        fi
        ;;
esac

if command -v mmc >/dev/null 2>&1; then
    EXT=$(mmc extcsd read "$DEV" 2>/dev/null)
    A_HEX=$(printf '%s\n' "$EXT" | awk 'tolower($0) ~ /life time estimation a/ {print $NF}' | sed 's/0[xX]//; s/[^0-9a-fA-F]//g' | head -n 1)
    B_HEX=$(printf '%s\n' "$EXT" | awk 'tolower($0) ~ /life time estimation b/ {print $NF}' | sed 's/0[xX]//; s/[^0-9a-fA-F]//g' | head -n 1)
    EOL=$(printf '%s\n' "$EXT" | awk 'tolower($0) ~ /pre eol/ {print $NF}' | head -n 1)
    if [ -n "$A_HEX" ]; then
        A_PCT=$(printf '%d' "0x$A_HEX" 2>/dev/null)
        [ -n "$A_PCT" ] && A_PCT=$((A_PCT * 10))
    fi
    if [ -n "$B_HEX" ]; then
        B_PCT=$(printf '%d' "0x$B_HEX" 2>/dev/null)
        [ -n "$B_PCT" ] && B_PCT=$((B_PCT * 10))
    fi
    case "$EOL" in
        0x01) EOL_STR="Normal" ;;
        0x02) EOL_STR="Warning" ;;
        0x03) EOL_STR="Urgent" ;;
        *) EOL_STR="Unknown" ;;
    esac
else
    warn_add "未检测到 mmc 命令，请安装 mmc-utils 以显示寿命信息"
fi

FREE_KB=$(df -P /tmp 2>/dev/null | awk 'NR == 2 {print $4}')
SKIP_WRITE=0
if [ -n "$FREE_KB" ]; then
    FREE_MB=$((FREE_KB / 1024))
    if [ "$FREE_MB" -lt 16 ]; then
        SKIP_WRITE=1
        warn_add "/tmp 可用空间过小（${FREE_MB}MB），已跳过写入速度测试"
    elif [ "$TEST_SIZE_MB" -gt "$FREE_MB" ]; then
        TEST_SIZE_MB=$FREE_MB
    fi
fi

if command -v dd >/dev/null 2>&1 && [ "$SKIP_WRITE" -eq 0 ]; then
    sync
    OUT=$(dd if=/dev/zero of="$TMP_FILE" bs=1M count="$TEST_SIZE_MB" oflag=direct conv=fsync 2>&1)
    if ! printf '%s\n' "$OUT" | grep -q copied; then
        OUT=$(dd if=/dev/zero of="$TMP_FILE" bs=1M count="$TEST_SIZE_MB" conv=fsync 2>&1)
    fi
    WRITE_LINE=$(printf '%s\n' "$OUT" | grep copied | head -n 1)
    WRITE_SPEED=$(printf '%s\n' "$OUT" | sed -n 's/.* \([0-9][0-9.]* [MG]B\/s\).*/\1/p' | head -n 1)
    if [ -z "$WRITE_LINE" ]; then
        warn_add "写入速度测试执行失败，请检查 /tmp 空间和 dd 参数"
    fi
else
    warn_add "未检测到 dd 或 /tmp 空间不足，跳过写入速度测试"
fi

if command -v dd >/dev/null 2>&1; then
    OUT=$(dd if="$DEV" of=/dev/null bs=1M count="$TEST_SIZE_MB" iflag=direct 2>&1)
    if ! printf '%s\n' "$OUT" | grep -q copied; then
        OUT=$(dd if="$DEV" of=/dev/null bs=1M count="$TEST_SIZE_MB" 2>&1)
    fi
    READ_LINE=$(printf '%s\n' "$OUT" | grep copied | head -n 1)
    READ_SPEED=$(printf '%s\n' "$OUT" | sed -n 's/.* \([0-9][0-9.]* [MG]B\/s\).*/\1/p' | head -n 1)
    if [ -z "$READ_LINE" ]; then
        warn_add "读取速度测试执行失败，请检查设备可读性和 dd 参数"
    fi
else
    warn_add "未检测到 dd 命令，跳过读取速度测试"
fi

if command -v hdparm >/dev/null 2>&1; then
    HDPARM_OUT=$(hdparm -tT "$DEV" 2>&1)
    HDPARM_LINES=$(printf '%s\n' "$HDPARM_OUT" | grep -e 'Timing cached reads' -e 'Timing buffered disk reads')
    HDPARM_CACHED=$(printf '%s\n' "$HDPARM_OUT" | sed -n 's/.*Timing cached reads:.*= *\([0-9][0-9.]*\) \([MG]B\)\/sec.*/\1 \2\/s/p' | head -n 1)
    HDPARM_BUFFERED=$(printf '%s\n' "$HDPARM_OUT" | sed -n 's/.*Timing buffered disk reads:.*= *\([0-9][0-9.]*\) \([MG]B\)\/sec.*/\1 \2\/s/p' | head -n 1)
else
    warn_add "未检测到 hdparm 命令，跳过缓存读取测试"
fi

emit_text() {
    echo "==== eMMC Info & Health Check ===="
    echo "Device    : $DEV"
    echo "Model     : $MODEL"
    echo "CID       : $CID"
    echo "Date      : $DATE_FMT"
    echo "Capacity  : $CAPACITY"
    echo "FWRev    : $FWREV"
    echo "HWRev    : $HWREV"
    echo "Manf ID   : $MANFID"
    echo "OEM ID    : $OEMID"
    echo "Product Ver: $PRV"
    echo "Serial : $SERIAL"
    echo
    echo "==== eMMC Health (EXT_CSD) ===="
    if [ -n "$A_HEX" ]; then
        echo "Life Time Estimation A : 0x$A_HEX (~${A_PCT}% used)"
    else
        echo "Life Time Estimation A : N/A"
    fi
    if [ -n "$B_HEX" ]; then
        echo "Life Time Estimation B : 0x$B_HEX (~${B_PCT}% used)"
    else
        echo "Life Time Estimation B : N/A"
    fi
    echo "Pre EOL info           : ${EOL:-N/A} (${EOL_STR})"
    echo
    echo "==== eMMC Speed Test ===="
    echo "[WRITE TEST] Writing ${TEST_SIZE_MB}MB..."
    if [ -n "$WRITE_LINE" ]; then
        echo "$WRITE_LINE"
    else
        echo "[SKIP] write test skipped"
    fi
    echo
    echo "[READ TEST] Reading ${TEST_SIZE_MB}MB..."
    if [ -n "$READ_LINE" ]; then
        echo "$READ_LINE"
    else
        echo "[SKIP] read test skipped"
    fi
    echo
    echo "[HDParm Cache/Read Test]"
    if [ -n "$HDPARM_LINES" ]; then
        printf '%s\n' "$HDPARM_LINES"
    else
        echo "[SKIP] hdparm test skipped"
    fi
    if [ -n "$WARNINGS_TEXT" ]; then
        echo
        echo "==== Warnings ===="
        printf '%s\n' "$WARNINGS_TEXT"
    fi
    echo
    echo "==== Done ===="
}

emit_json() {
    printf '{\n'
    printf '  "device": "%s",\n' "$(esc "$DEV")"
    printf '  "model": "%s",\n' "$(esc "$MODEL")"
    printf '  "cid": "%s",\n' "$(esc "$CID")"
    printf '  "date": "%s",\n' "$(esc "$DATE_FMT")"
    printf '  "capacity": "%s",\n' "$(esc "$CAPACITY")"
    printf '  "fwrev": "%s",\n' "$(esc "$FWREV")"
    printf '  "hwrev": "%s",\n' "$(esc "$HWREV")"
    printf '  "manfid": "%s",\n' "$(esc "$MANFID")"
    printf '  "oemid": "%s",\n' "$(esc "$OEMID")"
    printf '  "prv": "%s",\n' "$(esc "$PRV")"
    printf '  "serial": "%s",\n' "$(esc "$SERIAL")"
    printf '  "life_a_hex": "%s",\n' "$(esc "${A_HEX:+0x$A_HEX}")"
    printf '  "life_a_percent": %s,\n' "${A_PCT:-null}"
    printf '  "life_b_hex": "%s",\n' "$(esc "${B_HEX:+0x$B_HEX}")"
    printf '  "life_b_percent": %s,\n' "${B_PCT:-null}"
    printf '  "pre_eol": "%s",\n' "$(esc "$EOL")"
    printf '  "pre_eol_str": "%s",\n' "$(esc "$EOL_STR")"
    printf '  "write_speed": "%s",\n' "$(esc "$WRITE_SPEED")"
    printf '  "read_speed": "%s",\n' "$(esc "$READ_SPEED")"
    printf '  "hdparm_cached": "%s",\n' "$(esc "$HDPARM_CACHED")"
    printf '  "hdparm_buffered": "%s",\n' "$(esc "$HDPARM_BUFFERED")"
    printf '  "test_size_mb": %s,\n' "$TEST_SIZE_MB"
    printf '  "warnings": [%s],\n' "$WARNINGS_JSON"
    printf '  "timestamp": "%s"\n' "$(esc "$TIMESTAMP")"
    printf '}\n'
}

trap 'rm -f "$TMP_FILE"' 0
if [ "$JSON_OUT" -eq 1 ]; then
    emit_json
else
    emit_text
fi
EMMCINFO_SH_EOF
chmod 755 "$EMMCINFO_BIN"

cat > "$LUCI_CTRL" <<'EMMCINFO_LUA_EOF'
module("luci.controller.emmcinfo", package.seeall)

function index()
    entry({"admin", "system", "emmcinfo"}, template("emmcinfo/status"), "eMMC Info", 90)
    entry({"admin", "system", "emmcinfo_run"}, call("action_run")).leaf = true
    entry({"admin", "system", "emmcinfo_json"}, call("action_json")).leaf = true
end

function action_run()
    luci.http.prepare_content("text/plain")
    local util = require "luci.util"
    local output = util.exec("/usr/bin/emmcinfo.sh 2>&1")
    luci.http.write(output)
end

function action_json()
    luci.http.prepare_content("application/json")
    local util = require "luci.util"
    local output = util.exec("/usr/bin/emmcinfo.sh --json 2>&1")
    luci.http.write(output)
end
EMMCINFO_LUA_EOF

cat > "$LUCI_VIEW" <<'EMMCINFO_VIEW_EOF'
<%+header%>
<style>
  .card {
    background: var(--cbi-section-bg, #fff);
    border-radius: 8px;
    padding: 20px;
    box-shadow: 0 2px 8px rgb(0 0 0 / 0.1);
    margin-bottom: 20px;
    position: relative;
  }
  .card h3 {
    margin-top: 0;
    color: var(--cbi-section-header-color, #2c3e50);
    font-weight: 600;
    font-size: 1.2em;
    border-bottom: 2px solid var(--cbi-section-header-color, #2c3e50);
    padding-bottom: 6px;
  }
  .info-table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 10px;
  }
  .info-table th, .info-table td {
    text-align: left;
    padding: 6px 8px;
    vertical-align: top;
  }
  .info-table th {
    background: var(--cbi-section-bg-alt, #f9fafb);
    width: 150px;
  }
  .progress-bar {
    height: 18px;
    background: #eee;
    border-radius: 9px;
    overflow: hidden;
    margin-top: 6px;
    width: 100%;
  }
  .progress-fill {
    height: 100%;
    background: var(--cbi-button-bg, #007AFF);
    transition: width 0.5s ease;
  }
  .remark {
    font-size: x-small;
    font-style: italic;
    color: #666;
    margin-top: 2px;
    display: block;
  }
  #resultConsole {
    background: #1e1e2f;
    color: #a0a0ff;
    font-family: monospace;
    font-size: 13px;
    white-space: pre-wrap;
    max-height: 300px;
    overflow-y: auto;
    padding: 12px;
    border-radius: 6px;
    margin-top: 15px;
    display: none;
  }
  .btn-center {
    text-align: center;
    margin-bottom: 15px;
  }
  #speedResults {
    list-style: none;
    padding-left: 0;
    font-family: monospace;
    margin-top: 10px;
  }
  #speedResults li {
    margin-bottom: 6px;
    font-weight: 600;
    color: var(--cbi-section-header-color, #2c3e50);
  }
  #lastCheckTime {
    position: absolute;
    right: 20px;
    bottom: 12px;
    color: red;
    font-size: 0.85em;
    font-weight: 600;
    font-family: monospace;
    user-select: none;
  }
  .warnings {
    display: none;
    background: #fff3cd;
    color: #664d03;
    border: 1px solid #ffecb5;
    border-radius: 6px;
    padding: 10px 14px;
    margin-bottom: 16px;
  }
  .warnings p {
    margin: 4px 0;
  }
  .log-output {
    background-color: #1e1e1e;
    color: #dcdcdc;
    font-family: Consolas, monospace;
    font-size: 13px;
    padding: 12px;
    border-radius: 6px;
    border: 1px solid #444;
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 400px;
    overflow-y: auto;
    box-shadow: inset 0 0 5px #000;
  }
</style>

<h2 class="cbi-section-title">eMMC 检测工具</h2>
<p>查看板载 eMMC 的型号、寿命、速度等信息。</p>

<div class="btn-center">
  <button class="cbi-button cbi-button-apply" onclick="runCheck()">运行检测</button>
</div>

<div id="warnings" class="warnings"></div>

<div id="infoCards" style="display:none; position: relative;">
  <div class="card" id="basicInfo">
    <h3>基本信息</h3>
    <table class="info-table">
      <tbody>
        <tr><th>设备</th><td id="device"></td></tr>
        <tr><th>型号</th><td id="model"></td></tr>
        <tr><th>CID</th><td id="cid"></td></tr>
        <tr><th>容量</th><td id="capacity"></td></tr>
        <tr><th>序列号</th><td id="serial"></td></tr>
        <tr><th>固件版本</th><td id="fwrev"></td></tr>
        <tr><th>硬件版本</th><td id="hwrev"></td></tr>
        <tr><th>厂商ID</th><td id="manfid"></td></tr>
        <tr><th>OEM ID</th><td id="oemid"></td></tr>
        <tr><th>产品版本</th><td id="prv"></td></tr>
        <tr><th>生产日期</th><td id="date"></td></tr>
      </tbody>
    </table>
  </div>

  <div class="card" id="healthInfo">
    <h3>寿命信息<small>（10%阶梯）</small></h3>
    <table class="info-table">
      <tbody>
        <tr>
          <th>
            已使用寿命<br>
            <span class="remark">（擦除次数）</span>
          </th>
          <td>
            <span id="lifeA_val"></span>
            <div class="progress-bar"><div id="lifeA_bar" class="progress-fill"></div></div>
          </td>
        </tr>
        <tr>
          <th>
            已使用寿命<br>
            <span class="remark">（写入量）</span>
          </th>
          <td>
            <span id="lifeB_val"></span>
            <div class="progress-bar"><div id="lifeB_bar" class="progress-fill"></div></div>
          </td>
        </tr>
        <tr><th>Pre EOL 信息</th><td id="preEOL"></td></tr>
      </tbody>
    </table>
  </div>

  <div class="card" id="speedInfo" style="position: relative;">
    <h3>速度测试</h3>
    <ul id="speedResults"></ul>
    <div id="lastCheckTime" title="最后检测时间"></div>
  </div>

  <h3 style="cursor:pointer; user-select:none;">详细检测日志</h3>
  <pre id="rawOutput" class="log-output"></pre>
</div>

<script type="text/javascript">
function formatDateTime(date) {
  const pad = (n) => n < 10 ? '0' + n : n;
  return date.getFullYear() + '-' + pad(date.getMonth()+1) + '-' + pad(date.getDate()) + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}

function setText(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = (value === null || value === undefined) ? '' : String(value);
}

function parseAndFill(data) {
  if (!data || typeof data !== 'object') return;

  setText('device', data.device);
  setText('model', data.model);
  setText('cid', data.cid);
  setText('date', data.date);
  setText('capacity', data.capacity);
  setText('fwrev', data.fwrev);
  setText('hwrev', data.hwrev);
  setText('manfid', data.manfid);
  setText('oemid', data.oemid);
  setText('prv', data.prv);
  setText('serial', String(data.serial || '').toUpperCase());

  const setLife = (valId, barId, value) => {
    let p = parseInt(value, 10);
    if (isNaN(p)) p = 0;
    p = Math.max(0, Math.min(100, p));
    setText(valId, p + '%');
    const bar = document.getElementById(barId);
    if (bar) bar.style.width = p + '%';
  };
  setLife('lifeA_val', 'lifeA_bar', data.life_a_percent);
  setLife('lifeB_val', 'lifeB_bar', data.life_b_percent);
  setText('preEOL', data.pre_eol_str || data.pre_eol);

  const ul = document.getElementById('speedResults');
  ul.innerHTML = '';
  const addSpeed = (label, value) => {
    if (value) {
      const li = document.createElement('li');
      li.textContent = label + ': ' + value;
      ul.appendChild(li);
    }
  };
  addSpeed('写入速度', data.write_speed);
  addSpeed('读取速度', data.read_speed);
  addSpeed('缓存读取速度 (hdparm)', data.hdparm_cached);
  addSpeed('缓冲读取速度 (hdparm)', data.hdparm_buffered);

  const warningsEl = document.getElementById('warnings');
  warningsEl.innerHTML = '';
  if (data.warnings && data.warnings.length) {
    warningsEl.style.display = 'block';
    data.warnings.forEach(w => {
      const p = document.createElement('p');
      p.textContent = w;
      warningsEl.appendChild(p);
    });
  } else {
    warningsEl.style.display = 'none';
  }
}

function loadFromStorage() {
  try {
    const savedData = localStorage.getItem('emmcinfo_last_result');
    const savedTime = localStorage.getItem('emmcinfo_last_time');
    if (savedData && savedTime) {
      const data = JSON.parse(savedData);
      document.getElementById('infoCards').style.display = 'block';
      document.getElementById('lastCheckTime').textContent = '检测时间: ' + savedTime;
      parseAndFill(data);
    }
  } catch(e) {
    console.warn('加载本地缓存失败', e);
  }
}

function runCheck() {
  const btn = document.querySelector('button.cbi-button-apply');
  btn.disabled = true;
  btn.textContent = '检测中，请稍候...';

  document.getElementById('infoCards').style.display = 'none';
  document.getElementById('rawOutput').textContent = '';
  document.getElementById('warnings').style.display = 'none';
  document.getElementById('warnings').innerHTML = '';
  ['device','model','cid','date','capacity','fwrev','hwrev','manfid','oemid','prv','serial','lifeA_val','lifeB_val','preEOL'].forEach(id => {
    setText(id, '');
  });
  document.getElementById('lifeA_bar').style.width = '0%';
  document.getElementById('lifeB_bar').style.width = '0%';
  document.getElementById('speedResults').innerHTML = '';
  document.getElementById('lastCheckTime').textContent = '';

  fetch('<%=url([[admin]], [[system]], [[emmcinfo_json]])%>', { cache: 'no-store' })
    .then(res => res.text())
    .then(txt => {
      let data;
      try {
        data = JSON.parse(txt);
      } catch(e) {
        data = { error: txt };
      }
      document.getElementById('rawOutput').textContent = txt;
      btn.disabled = false;
      btn.textContent = '运行检测';

      if (data.error && !data.device) {
        alert('检测失败: ' + data.error);
        return;
      }

      document.getElementById('infoCards').style.display = 'block';
      const nowStr = formatDateTime(new Date());
      document.getElementById('lastCheckTime').textContent = '检测时间: ' + nowStr;
      try {
        localStorage.setItem('emmcinfo_last_result', txt);
        localStorage.setItem('emmcinfo_last_time', nowStr);
      } catch(e) {}
      parseAndFill(data);
    })
    .catch(err => {
      alert('检测出错: ' + err);
      btn.disabled = false;
      btn.textContent = '运行检测';
    });
}

window.onload = loadFromStorage;
</script>
<%+footer%>
EMMCINFO_VIEW_EOF

for f in "$EMMCINFO_BIN" "$LUCI_CTRL" "$LUCI_VIEW"; do
    [ -s "$f" ] || {
        log "错误：$f 写入失败或内容为空"
        exit 1
    }
done

log "刷新 LuCI 缓存..."
rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
fi
if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd reload >/dev/null 2>&1 || /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

log "安装完成："
log "  $EMMCINFO_BIN"
log "  $LUCI_CTRL"
log "  $LUCI_VIEW"
log "刷新浏览器后可在 LuCI → 系统 → eMMC Info 中查看"
