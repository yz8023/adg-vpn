#!/system/bin/sh
# ============================================================
#  subguard.sh  v1.2.0  （单文件版 / 内置 box 模块版）
#
#  订阅守护：多订阅自动例外 + 失败不删档 + fail-open 不断网
#  一个文件、零依赖（只用 curl / awk / sed / grep / tr）
#
#  安装：su -c "sh subguard.sh install"
#  卸载：su -c "sh subguard.sh uninstall"
#  常用：su -c "sh subguard.sh {learn|apply|update|status|doctor}"
#  救急：su -c "sh subguard.sh restart-core"   # 出现两份 mihomo/端口占用时
# ============================================================

SUBG_VERSION="1.2.1"



SUBG_DATA="${SUBG_DATA:-/data/adb/subguard}"
SUBG_LOG_DIR="${SUBG_DATA}/logs"
SUBG_STATE="${SUBG_DATA}/state"
SUBG_LASTGOOD="${SUBG_DATA}/lastgood"
SUBG_BACKUP="${SUBG_DATA}/backup"
SUBG_CONF="${SUBG_CONF:-${SUBG_DATA}/config.conf}"

BEGIN_MARK="# >>> subguard:begin >>>"
END_MARK="# <<< subguard:end <<<"

# ---------- 日志 ----------
subg_ts() { date "+%m-%d %H:%M:%S" 2>/dev/null || date; }

log() {
    line="$(subg_ts) [$1] $2"
    echo "$line"
    [ -d "$SUBG_LOG_DIR" ] && echo "$line" >> "${SUBG_LOG_DIR}/subguard.log"
    if [ -f "${SUBG_LOG_DIR}/subguard.log" ]; then
        sz=$(wc -c < "${SUBG_LOG_DIR}/subguard.log" 2>/dev/null | tr -d ' ')
        [ -n "$sz" ] && [ "$sz" -gt 524288 ] && { tail -c 262144 "${SUBG_LOG_DIR}/subguard.log" > "${SUBG_LOG_DIR}/.t" 2>/dev/null && mv "${SUBG_LOG_DIR}/.t" "${SUBG_LOG_DIR}/subguard.log"; }
    fi
    return 0
}
logi() { log "INFO " "$*"; }
logw() { log "WARN " "$*"; }
loge() { log "ERROR" "$*"; }
logd() { [ "${SUBG_DEBUG:-0}" = "1" ] && log "DEBUG" "$*"; return 0; }

# ---------- 基础工具 ----------
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] && return 0
    if have su; then
        echo "[subguard] 需要 root，正在通过 su 重新执行…"
        exec su -c "SUBG_DATA='${SUBG_DATA}' SUBG_CONF='${SUBG_CONF}' sh '$0' $*"
    fi
    echo "[subguard] 需要 root 权限（Termux 里用 su，或走 Magisk 的 action.sh）" >&2
    exit 1
}

init_dirs() {
    mkdir -p "$SUBG_DATA" "$SUBG_LOG_DIR" "$SUBG_STATE" "$SUBG_LASTGOOD" "$SUBG_BACKUP" 2>/dev/null
}

find_curl() {
    if [ -n "${SUBG_CURL:-}" ] && [ -x "$SUBG_CURL" ]; then echo "$SUBG_CURL"; return 0; fi
    for c in /data/adb/box/bin/curl /data/adb/box/bin/.bin/curl /system/bin/curl /system/xbin/curl /data/data/com.termux/files/usr/bin/curl; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    if have curl; then command -v curl; return 0; fi
    return 1
}

backup_file() {
    [ -f "$1" ] || return 0
    mkdir -p "$SUBG_BACKUP" 2>/dev/null
    dst="${SUBG_BACKUP}/$(basename "$1").$2.$(date +%Y%m%d%H%M%S 2>/dev/null)"
    cp -f "$1" "$dst" 2>/dev/null && logd "已备份 $1 -> $dst"
    ls -1t "${SUBG_BACKUP}/$(basename "$1")."* 2>/dev/null | tail -n +11 | while read -r f; do rm -f "$f"; done
    return 0
}

# ---------- 内容判定 ----------
is_challenge() {
    [ -s "$1" ] || return 1
    if grep -qiE 'cf-mitigated|<title>[[:space:]]*Just a moment|__cf_chl|challenge-platform|cf-challenge|正在进行安全验证|安全服务防护恶意自动程序|Checking your browser|Enable JavaScript and cookies' "$1" 2>/dev/null; then
        return 0
    fi
    return 1
}

valid_payload() {
    f="$1"
    [ -s "$f" ] || return 1
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    [ -n "$sz" ] && [ "$sz" -ge 80 ] || return 1
    is_challenge "$f" && return 1
    head -c 512 "$f" 2>/dev/null | grep -qi '<html\|<!doctype' && return 1

    grep -qE '^[[:space:]]*proxies[[:space:]]*:' "$f" && return 0
    grep -qE '^[[:space:]]*proxy-groups[[:space:]]*:' "$f" && return 0

    if grep -qE '^[A-Za-z0-9+/=]+[[:space:]]*$' "$f" 2>/dev/null; then
        for dec in "base64 -d" "busybox base64 -d" "base64 --decode" "toybox base64 -d"; do
            $dec "$f" 2>/dev/null | grep -qE '(vless|vmess|ss|ssr|trojan|hysteria2?|hy2|tuic|anytls)://' && return 0
        done
    fi
    grep -qE '(vless|vmess|ssr?|trojan|hysteria2?|hy2|tuic|anytls)://' "$f" && return 0
    return 1
}

maybe_decode() {
    src="$1"; dst="$2"
    for dec in "base64 -d" "busybox base64 -d" "base64 --decode" "toybox base64 -d"; do
        if $dec "$src" > "${dst}.tmp" 2>/dev/null && grep -qE '(vless|vmess|ss|ssr|trojan|hysteria2?|hy2|tuic|anytls)://' "${dst}.tmp" 2>/dev/null; then
            mv -f "${dst}.tmp" "$dst"; return 0
        fi
    done
    rm -f "${dst}.tmp" 2>/dev/null
    cp -f "$src" "$dst"
    return 0
}

# ---------- 域名 / IDN（纯 awk 实现 RFC3492，无需 idn2）----------
PUNY_VER="v1"
PUNY_AWK="${SUBG_STATE}/puny.awk"
ensure_puny() {
    [ -s "$PUNY_AWK" ] && grep -q "SUBG_PUNY_${PUNY_VER}" "$PUNY_AWK" 2>/dev/null && return 0
    mkdir -p "$SUBG_STATE" 2>/dev/null
    { printf '# SUBG_PUNY_%s\n' "$PUNY_VER"; cat <<'PUNYAWK'
function ord_init(   i) { if (ORDOK) return; for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i; ORDOK = 1 }
function utf8_cps(s, arr,   i, n, len, c, c1, c2, c3, cp) {
    ord_init(); n = 0; len = length(s); i = 1
    while (i <= len) {
        c = ORD[substr(s, i, 1)]
        if (c == "") return -1
        if (c < 128) { cp = c; i++ }
        else if (c >= 192 && c < 224) { c1 = ORD[substr(s, i + 1, 1)]; if (c1 == "" || c1 < 128 || c1 > 191) return -1; cp = (c - 192) * 64 + (c1 - 128); i += 2 }
        else if (c >= 224 && c < 240) { c1 = ORD[substr(s, i + 1, 1)]; c2 = ORD[substr(s, i + 2, 1)]; if (c1 == "" || c2 == "" || c1 < 128 || c1 > 191 || c2 < 128 || c2 > 191) return -1; cp = (c - 224) * 4096 + (c1 - 128) * 64 + (c2 - 128); i += 3 }
        else if (c >= 240 && c < 248) { c1 = ORD[substr(s, i + 1, 1)]; c2 = ORD[substr(s, i + 2, 1)]; c3 = ORD[substr(s, i + 3, 1)]; if (c1 == "" || c2 == "" || c3 == "" || c1 < 128 || c1 > 191 || c2 < 128 || c2 > 191 || c3 < 128 || c3 > 191) return -1; cp = (c - 240) * 262144 + (c1 - 128) * 4096 + (c2 - 128) * 64 + (c3 - 128); i += 4 }
        else return -1
        if (cp < 0 || cp > 1114111) return -1
        n++; arr[n] = cp
    }
    return n
}
function pdigit(d) { return d < 26 ? sprintf("%c", 97 + d) : sprintf("%c", 22 + d) }
function adapt(delta, nump, first,   k) {
    delta = first ? int(delta / 700) : int(delta / 2)
    delta += int(delta / nump)
    k = 0
    while (delta > 455) { delta = int(delta / 35); k += 36 }
    return k + int(36 * delta / (delta + 38))
}
function puny_encode(s,   cps, n, i, b, h, out, cur, delta, bias, m, q, k, t) {
    n = utf8_cps(s, cps); if (n <= 0) return ""
    out = ""; b = 0
    for (i = 1; i <= n; i++) if (cps[i] < 128) { out = out sprintf("%c", cps[i]); b++ }
    h = b; if (b > 0) out = out "-"
    cur = 128; delta = 0; bias = 72
    while (h < n) {
        m = 1114112
        for (i = 1; i <= n; i++) if (cps[i] >= cur && cps[i] < m) m = cps[i]
        delta = delta + (m - cur) * (h + 1); cur = m
        for (i = 1; i <= n; i++) {
            if (cps[i] < cur) delta++
            if (cps[i] == cur) {
                q = delta
                for (k = 36; ; k += 36) {
                    if (k <= bias) t = 1; else if (k >= bias + 26) t = 26; else t = k - bias
                    if (q < t) break
                    out = out pdigit(t + (q - t) % (36 - t)); q = int((q - t) / (36 - t))
                }
                out = out pdigit(q)
                bias = adapt(delta, h + 1, (h == b)); delta = 0; h++
            }
        }
        delta++; cur++
    }
    return out
}
{ print puny_encode($0) }
PUNYAWK
    } > "$PUNY_AWK"
    return 0
}

# URL → 主机名（去协议/账号/端口/路径，转小写）
host_of_url() {
    printf '%s' "$1" | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#^[^/@]*@##' \
        -e 's#[/?#].*$##' -e 's#:[0-9]*$##' | tr 'A-Z' 'a-z'
}

# 主机名 → punycode（含中文也能转），失败返回空
to_ascii_host() {
    raw="$(host_of_url "$1")"
    raw="${raw%.}"
    [ -z "$raw" ] && return 1
    case "$raw" in
        *[!A-Za-z0-9.-]*) ;;   # 含非 ASCII，需要转
        *) printf '%s\n' "$raw"; return 0 ;;
    esac
    ensure_puny
    printf '%s\n' "$raw" | tr '.' '\n' | while IFS= read -r lab; do
        case "$lab" in
            '' ) continue ;;
            *[!A-Za-z0-9-]*)
                enc="$(printf '%s\n' "$lab" | awk -f "$PUNY_AWK" 2>/dev/null)"
                [ -n "$enc" ] && printf 'xn--%s\n' "$enc" || printf '%s\n' "$lab" ;;
            *) printf '%s\n' "$lab" ;;
        esac
    done | tr '\n' '.' | sed 's/\.$//;s/^\.//'
    echo
}

# ---------- 网络 ----------
wait_net() {
    n="${1:-60}"; i=0
    while [ "$i" -lt "$n" ]; do
        if ip route 2>/dev/null | grep -q '^default' || ping -c1 -W2 223.5.5.5 >/dev/null 2>&1; then
            logi "网络已就绪（等待 ${i}s）"; return 0
        fi
        sleep 2; i=$((i+2))
    done
    logw "等待网络超时（${n}s），继续执行"
    return 1
}

doh_resolve() {
    d="$1"; c="$(find_curl 2>/dev/null)"
    [ -z "$c" ] && return 1
    for u in "https://dns.alidns.com/resolve?name=${d}&type=A" "https://doh.pub/dns-query?name=${d}&type=A" "https://1.1.1.1/dns-query?name=${d}&type=A"; do
        out=$("$c" -sk --max-time 8 -H 'accept: application/dns-json' "$u" 2>/dev/null)
        ips=$(echo "$out" | tr '{}[]' '\n\n\n\n' | tr ',' '\n' \
              | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)".*/\1/p' \
              | grep -vE '^(0\.|10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | sort -u)
        [ -n "$ips" ] && { echo "$ips"; return 0; }
    done
    return 1
}

tcp_probe() {
    h="$1"; p="${2:-443}"; sni="${3:-}"
    c="$(find_curl 2>/dev/null)"
    [ -z "$c" ] && { echo 9999; return 1; }
    if [ -n "$sni" ]; then
        r=$("$c" -sk -o /dev/null --max-time 7 --connect-timeout 5 --resolve "${sni}:${p}:${h}" -w '%{http_code} %{time_total}' "https://${sni}/" 2>/dev/null)
    else
        r=$("$c" -sk -o /dev/null --max-time 7 --connect-timeout 5 -w '%{http_code} %{time_total}' "https://${h}:${p}/" 2>/dev/null)
    fi
    code=${r%% *}; tc=${r##* }
    if [ -z "$r" ] || [ "$code" = "000" ] || [ -z "$tc" ]; then echo 9999; else echo "$tc"; fi
}

# ---------- 引擎探测 ----------
detect_engine() {
    ENGINE=""; CONF=""; SVC=""; BIN=""

    if [ -f /data/adb/box/settings.ini ]; then
        ENGINE="box"
        CONF="${BOX_DIR:-/data/adb/box}/mihomo/config.yaml"
        SVC="${BOX_DIR:-/data/adb/box}/scripts/box.service"
        BIN="${BOX_DIR:-/data/adb/box}/bin/mihomo"
    elif [ -f /data/adb/agh/scripts/config.prop ]; then
        ENGINE="agh"
        CONF="$(ls -1 /data/adb/box/mihomo/config.yaml /data/adb/agh/*/config.yaml 2>/dev/null | head -1)"
        SVC="$(ls -1 /data/adb/agh/scripts/restart.sh 2>/dev/null | head -1)"
    else
        ENGINE="generic"
        for c in /data/adb/clash/config.yaml /data/adb/akasha/config.yaml \
                 /data/adb/surfing/clash/config.yaml /data/adb/mihomo/config.yaml; do
            [ -f "$c" ] && { CONF="$c"; break; }
        done
        [ -z "$CONF" ] && CONF="$(find /data/adb -maxdepth 4 -type f -name 'config.yaml' 2>/dev/null | grep -Ei 'mihomo|clash|box|akasha|surfing' | head -1)"
        SVC="$(ls -1 /data/adb/modules/*/*.service 2>/dev/null | head -1)"
        BIN="$(find /data/adb -maxdepth 4 -type f -name 'mihomo' 2>/dev/null | head -1)"
    fi
    [ -n "$BIN" ] && [ ! -x "$BIN" ] && BIN=""
    printf '%s|%s|%s|%s\n' "$ENGINE" "$CONF" "$SVC" "$BIN"
}

# 单实例锁（防止 boot / watch 同时跑出两份）
acquire_lock() {
    _ld="${SUBG_DATA}/run"
    mkdir -p "$_ld" 2>/dev/null
    _lp="${_ld}/subguard.lock"
    if [ -f "$_lp" ]; then
        _old=$(cat "$_lp" 2>/dev/null | tr -d ' ')
        case "$_old" in ''|*[!0-9]*) _old=0 ;; esac
        if [ "$_old" -gt 0 ] && [ "$_old" != "$$" ] && kill -0 "$_old" 2>/dev/null; then
            return 1
        fi
    fi
    echo $$ > "$_lp"
    return 0
}

# 当前内核 pid 列表（mihomo / sing-box）
core_pids() {
    _p=""
    # 直接读 /proc/<pid>/cmdline，不依赖 ps 的列顺序（Android 与 Linux 表现不同）
    for _d in /proc/[0-9]*; do
        [ -r "${_d}/cmdline" ] || continue
        _c=""
        IFS= read -r _c < "${_d}/cmdline" 2>/dev/null
        case "$_c" in
            *mihomo*|*sing-box*) _p="$_p ${_d#/proc/}" ;;
        esac
    done
    echo $_p
}
core_count() { _c=0; for _i in $(core_pids); do _c=$((_c+1)); done; echo "$_c"; }

# 等 box 自己把内核拉起来（开机时用，避免我们抢先启动第二个实例）
wait_core_ready() {
    _t="${1:-150}"; _i=0
    while [ "$_i" -lt "$_t" ]; do
        core_running && { logi "内核已就绪（等待 ${_i}s，pid $(core_pids)）"; return 0; }
        sleep 3; _i=$((_i+3))
    done
    logw "等待内核就绪超时（${_t}s），当前内核进程数 $(core_count)"
    return 1
}

core_running() {
    [ -n "$(core_pids)" ] && return 0
    if [ -f /data/adb/box/run/box.pid ]; then
        p=$(cat /data/adb/box/run/box.pid 2>/dev/null | tr -d ' \n')
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    fi
    return 1
}

control_core() {
    ACT="$1"
    # 已经在跑就绝不重复 start —— 这是开机端口冲突的根因
    if [ "$ACT" = "start" ] && core_running; then
        logd "内核已在运行（pid $(core_pids)），跳过 start"
        return 0
    fi
    if [ -n "$SVC" ] && [ -x "$SVC" ]; then
        "$SVC" "$ACT" >/dev/null 2>&1 && { logi "box.service $ACT 已执行"; return 0; }
    fi
    [ -f /data/adb/box/scripts/box.service ] && { sh /data/adb/box/scripts/box.service "$ACT" >/dev/null 2>&1 && return 0; }
    logw "无法控制内核（未找到 box.service），请手动重启模块"
    return 1
}

# ---------- AGH ----------
agh_yaml() {
    for f in /data/adb/agh/bin/AdGuardHome.yaml /data/adb/modules/AdGuardHome/bin/AdGuardHome.yaml; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
agh_running() {
    ps -A 2>/dev/null | grep -q '[A]dGuardHome' && return 0
    for p in /proc/[0-9]*; do
        c=""; IFS= read -r c < "$p/cmdline" 2>/dev/null
        case "$c" in *AdGuardHome*) return 0 ;; esac
    done
    return 1
}
agh_restart() {
    if [ -f /data/adb/agh/scripts/restart.sh ]; then
        sh /data/adb/agh/scripts/restart.sh agh >/dev/null 2>&1 && { logi "AdGuardHome 已重启（新规则生效）"; return 0; }
    fi
    logw "未找到 restart.sh，AGH 规则将在下次重启后生效"
    return 1
}

# ---------- proxy-providers 解析 ----------
parse_providers() {
    cfg="$1"
    [ -f "$cfg" ] || return 1
    awk '
        BEGIN{inb=0; n=""; u=""; p=""}
        /^proxy-providers:[[:space:]]*$/ {inb=1; next}
        inb && /^[^[:space:]#]/ {inb=0}
        inb && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
            n=$0; sub(/^[[:space:]]+/,"",n); sub(/:[[:space:]]*$/,"",n); next
        }
        inb && /^[[:space:]]+url:/ {
            u=$0; sub(/^[[:space:]]+url:[[:space:]]*/,"",u); gsub(/^["'\'']|["'\'']$/,"",u); next
        }
        inb && /^[[:space:]]+path:/ {
            p=$0; sub(/^[[:space:]]+path:[[:space:]]*/,"",p); gsub(/^["'\'']|["'\'']$/,"",p);
            if (n != "") { print n "|" u "|" p; n=""; u=""; p="" }
            next
        }
    ' "$cfg"
}

abs_provider_path() {
    cfg="$1"; p="$2"
    base="$(dirname "$cfg")"
    case "$p" in
        ./*) echo "${base}/${p#./}" ;;
        /*)  echo "$p" ;;
        *)   echo "${base}/${p}" ;;
    esac
}

# 取 KEY="value" 形式配置值（去掉引号）
conf_value() {
    [ -f "$1" ] || return 1
    sed -n "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | head -1 | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//'
}

# 过滤掉本机/内网/纯 IP 等不该写进规则的目标
is_real_domain() {
    case "$1" in
        ''|localhost|127.*|0.0.0.0|::1|*.local|*.lan) return 1 ;;
    esac
    case "$1" in *:*) return 1 ;; esac
    echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && return 1
    echo "$1" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || return 1
    echo "$1" | grep -q '\.' || return 1
    return 0
}

# ============================================================
#  订阅源自动发现（核心：不写死任何一条订阅）
#  输出: name \t url \t path(可空) \t source
# ============================================================
discover_sources() {
    # 1) 内核 config.yaml 里的全部 proxy-providers（天然支持多订阅）
    if [ -n "$CONF" ] && [ -f "$CONF" ]; then
        parse_providers "$CONF" | while IFS='|' read -r n u p; do
            [ -z "$u" ] && continue
            case "$u" in http*) ;; *) continue ;; esac
            ap=""
            [ -n "$p" ] && ap="$(abs_provider_path "$CONF" "$p")"
            printf '%s|%s|%s|%s\n' "$n" "$u" "$ap" "config.yaml"
        done
    fi

    # 2) Box settings.ini 的订阅数组 / sing-box 订阅
    if [ -f /data/adb/box/settings.ini ]; then
        awk '
            /^subscription_url_mihomo=\(/ {inb=1; buf=$0; if ($0 ~ /\)/) {print buf; inb=0}; next}
            inb {buf=buf " " $0; if ($0 ~ /\)/) {print buf; inb=0}}
        ' /data/adb/box/settings.ini 2>/dev/null | tr -d '"' | tr -d "'" | tr '(),' '    ' | tr ' ' '\n' | \
        grep -E '^https?://' | while IFS= read -r u; do
            [ -n "$u" ] && printf '%s|%s|%s|%s\n' "settings_sub" "$u" "" "settings.ini"
        done
        su="$(conf_value /data/adb/box/settings.ini subscription_url_singbox)"
        [ -n "$su" ] && printf '%s|%s|%s|%s\n' "singbox" "$su" "" "settings.ini"
    fi

    # 3) AGH 的 config.prop -> PROXY_URL
    au="$(conf_value /data/adb/agh/scripts/config.prop PROXY_URL)"
    [ -n "$au" ] && printf '%s|%s|%s|%s\n' "agh_proxy" "$au" "" "config.prop"
}

# 按 URL 去重，保留首次出现
discover_unique() {
    discover_sources | awk -F'|' '!seen[$2]++ {print}'
}

# 所有需要直连的域名（手写 + 自动发现），punycode 化 + 过滤 + 去重
collect_domains() {
    {
        for d in $PROTECT_DOMAINS; do
            h="$(to_ascii_host "$d" 2>/dev/null)"
            [ -n "$h" ] && is_real_domain "$h" && echo "$h"
        done
        discover_unique | while IFS='|' read -r n u p s; do
            h="$(to_ascii_host "$u" 2>/dev/null)"
            [ -n "$h" ] && is_real_domain "$h" && echo "$h"
        done
    } | sed '/^$/d' | sort -u
}


# ============================================================
#  主逻辑
# ============================================================


# ---------------- 默认配置 ----------------
DEFAULT_CONF='# ===== subguard v1.1 配置（改完直接生效，无需重启）=====
# 【1】需要强制直连的域名（空格分隔，中英文都行；punycode 会自动转）
#     订阅域名会被自动发现，不需要写在这里；这里主要写「面板/官网」域名
PROTECT_DOMAINS="xn--9kqs1lo79d.com"

# 【2】额外订阅链接（一般留空：会自动从 config.yaml / settings.ini / config.prop 读）
SUBS=""

# 【3】关闭自动发现（1=开启自动发现；0=只用手写列表）
AUTO_DISCOVER=1

# 【4】拉订阅时依次尝试的 UA（很多机场/CF 只放行常见客户端 UA）
UA_LIST="clash.meta/v1.19.0 ClashMetaForAndroid/2.10.4.Meta clash-verge/v2.0.0 ClashforWindows/0.20.39 v2rayN/6.31"

# 【5】1=把域名固定到实测最快的真实 IP（写入内核 hosts），0=关闭
PIN_IP=1
PIN_MAX=8

# 【6】Cloudflare cf_clearance（可选；绑定 IP+UA，容易过期）
CF_CLEARANCE=""
CF_UA=""

# 【7】1=拉取被拦时自动开关飞行模式换 IP 重试（谨慎，会短暂断网）
ALLOW_IP_ROTATE=0
ROTATE_TRIES=1

# 【8】1=接管订阅更新（把 Box settings.ini 的 update_subscription 设为 false，
#      因为模块自带更新在解析失败时会 rm 掉 provider 文件 → 直接断网）
TAKE_OVER_UPDATE=1

# 【9】AGH 联动：1=自动往 AdGuardHome 的 user_rules 注入放行规则（防止广告规则误杀面板域名）
AGH_EXCEPT=1
#      1=再额外用 $dnsrewrite 把域名钉到固定 IP（AGH 层 DNS 固化，可选）
AGH_REWRITE=0

# 【10】守护参数
CHECK_INTERVAL=120
# 开机后多少秒内不介入内核启停（防与 box_service.sh 抢启动；太小会端口冲突）
BOOT_GRACE=180
UPDATE_INTERVAL=21600
PIN_INTERVAL=43200
FAIL_OPEN=1
'

load_conf() {
    init_dirs
    [ -f "$SUBG_CONF" ] || { printf '%s\n' "$DEFAULT_CONF" > "$SUBG_CONF" 2>/dev/null; logi "已生成默认配置：$SUBG_CONF"; }
    . "$SUBG_CONF" 2>/dev/null
    [ -z "$PROTECT_DOMAINS" ] && PROTECT_DOMAINS=""
    [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=120
    [ -z "$BOOT_GRACE" ] && BOOT_GRACE=180
    [ -z "$UPDATE_INTERVAL" ] && UPDATE_INTERVAL=21600
    [ -z "$PIN_INTERVAL" ] && PIN_INTERVAL=43200
    [ -z "$PIN_MAX" ] && PIN_MAX=8
    [ -z "$UA_LIST" ] && UA_LIST="clash.meta/v1.19.0 ClashMetaForAndroid/2.10.4.Meta"
    [ -z "$AUTO_DISCOVER" ] && AUTO_DISCOVER=1
    [ -z "$AGH_EXCEPT" ] && AGH_EXCEPT=1
    [ -z "$AGH_REWRITE" ] && AGH_REWRITE=0
    DOMFILE="${SUBG_STATE}/domains.txt"
    return 0
}

detect() {
    _d="$(detect_engine)"
    ENGINE="${_d%%|*}";  _rest="${_d#*|}"
    CONF="${_rest%%|*}"; _rest="${_rest#*|}"
    SVC="${_rest%%|*}";  BIN="${_rest#*|}"
    CURL="$(find_curl 2>/dev/null)"
}

module_disabled() {
    for d in /data/adb/modules/box* /data/adb/modules/AdGuardHome* /data/adb/modules/mihomo* /data/adb/modules/akasha*; do
        [ -d "$d" ] && [ -f "${d}/disable" ] && return 0
    done
    return 1
}

# ============================================================
#  YAML 块重写引擎（带标记，幂等：改多少次都只有一份）
# ============================================================
RB_AWK="${SUBG_STATE}/rewrite.awk"
RB_AWK_VER="v3"
ensure_rb_awk() {
    if [ -s "$RB_AWK" ] && grep -q "SUBG_AWK_${RB_AWK_VER}" "$RB_AWK" 2>/dev/null; then return 0; fi
    { printf '# SUBG_AWK_%s\n' "$RB_AWK_VER"; cat <<'RBAWK'
function emit(  l) {
    while ((getline l < blk) > 0) print l
    close(blk); printed = 1
}
BEGIN {
    while ((getline l < domfile) > 0) if (l != "") DOM[l] = 1
    close(domfile)
    skip = 0; printed = 0
}
{
    if (index($0, "# >>> subguard:" tag ":begin >>>") > 0) { skip = 1; next }
    if (skip == 1) { if (index($0, "# <<< subguard:" tag ":end <<<") > 0) skip = 0; next }

    if (kind == "rule") {
        t = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", t)
        if (t ~ /^DOMAIN-SUFFIX,/) {
            n = split(t, a, ","); d = a[2]; gsub(/[[:space:]]/, "", d)
            if (d in DOM) next
        }
    } else if (kind == "host") {
        t = $0; gsub(/["'\'']/, "", t); sub(/^[[:space:]]*/, "", t)
        if (t ~ /^[^:]+:/) { split(t, a, ":"); d = a[1]; gsub(/[[:space:]]/, "", d); if (d in DOM) next }
    } else if (kind == "agh") {
        t = $0
        if (t ~ /\|\|/) {
            for (d in DOM) if (index(t, "||" d "^") > 0) next
        }
    }

    print
    if (!printed && anchor != "" && $0 ~ anchor) emit()
}
END { if (!printed) emit() }
RBAWK
    } > "$RB_AWK"
    return 0
}

# apply_block <file> <anchor-regex> <block-file> <kind>   → 0=有改动 1=无改动
apply_block() {
    f="$1"; anchor="$2"; blk="$3"; kind="$4"
    [ -f "$f" ] || return 1
    ensure_rb_awk
    tmp="${f}.subg.old.$$"
    cp -f "$f" "$tmp" 2>/dev/null
    awk -v anchor="$anchor" -v blk="$blk" -v kind="$kind" -v tag="$kind" \
        -v domfile="$DOMFILE" -f "$RB_AWK" "$f" > "${f}.subg.new" 2>/dev/null
    if [ ! -s "${f}.subg.new" ]; then rm -f "${f}.subg.new" "$tmp"; return 1; fi
    mv -f "${f}.subg.new" "$f"
    if cmp -s "$tmp" "$f" 2>/dev/null; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"; return 0
}

pick_ips() {
    dom="$1"; n="${2:-2}"
    ips="$(doh_resolve "$dom")"
    [ -z "$ips" ] && return 1
    for ip in $ips; do
        t="$(tcp_probe "$ip" 443 "$dom")"
        [ "$t" = "9999" ] && continue
        printf '%s %s\n' "$t" "$ip"
    done | sort -n | head -"$n" | awk '{print $2}'
}

# ============================================================
#  apply —— 重建「自动例外」
# ============================================================
cmd_apply() {
    detect
    [ -z "$CONF" ] || [ ! -f "$CONF" ] && { loge "没找到内核配置文件，无法写入直连例外"; return 1; }

    mkdir -p "$SUBG_STATE" 2>/dev/null
    if [ "${AUTO_DISCOVER:-1}" = "1" ]; then
        collect_domains > "$DOMFILE"
    else
        for d in $PROTECT_DOMAINS; do to_ascii_host "$d"; done | sed '/^$/d' | sort -u > "$DOMFILE"
    fi
    if [ ! -s "$DOMFILE" ]; then
        loge "没有可用的域名（PROTECT_DOMAINS 为空且未发现订阅源）"
        return 1
    fi
    DLIST="$(tr '\n' ' ' < "$DOMFILE")"
    logi "本次需要直连的域名（共 $(wc -l < "$DOMFILE" | tr -d ' ') 个）: ${DLIST}"

    changed=0
    AGH_CHANGED=0

    # ---- 1) mihomo rules ----
    rblk="${SUBG_STATE}/.rules.blk"
    printf '  # >>> subguard:rule:begin >>>\n' > "$rblk"
    while IFS= read -r d; do
        [ -n "$d" ] && printf '  - DOMAIN-SUFFIX,%s,DIRECT\n' "$d" >> "$rblk"
    done < "$DOMFILE"
    printf '  # <<< subguard:rule:end <<<\n' >> "$rblk"

    if grep -qE '^[[:space:]]*-[[:space:]]*DST-PORT,53' "$CONF"; then
        anchor='^[[:space:]]*-[[:space:]]*DST-PORT,53'
    else
        grep -qE '^rules:' "$CONF" || printf '\nrules:\n' >> "$CONF"
        anchor='^rules:'
    fi
    backup_file "$CONF" apply
    if apply_block "$CONF" "$anchor" "$rblk" "rule"; then
        logi "已更新 mihomo 直连规则块（$(grep -c 'DOMAIN-SUFFIX' "$rblk" | tr -d ' ') 个域名）"
        changed=1
    else
        logi "mihomo 直连规则块无变化"
    fi

    # ---- 2) mihomo hosts（固定 IP，带缓存：PIN_INTERVAL 内直接复用，避免每次 apply 都变）----
    pin_file="${SUBG_STATE}/pinned.txt"
    pin_ts="${SUBG_STATE}/pin.ts"
    prev_pins=""
    [ -f "$pin_file" ] && prev_pins="$(cat "$pin_file" 2>/dev/null)"
    cache_ok=0
    if [ -s "$pin_file" ] && [ -f "$pin_ts" ]; then
        pts=$(cat "$pin_ts" 2>/dev/null | tr -d ' ')
        nowp=$(date +%s 2>/dev/null || echo 0)
        case "$pts" in ''|*[!0-9]*) pts=0 ;; esac
        [ "$pts" -gt 0 ] && [ $((nowp - pts)) -lt "${PIN_INTERVAL:-43200}" ] && cache_ok=1
    fi

    if [ "${PIN_IP:-1}" = "1" ]; then
        hblk="${SUBG_STATE}/.hosts.blk"
        new_pins="${SUBG_STATE}/.pins.new"
        printf '  # >>> subguard:host:begin >>>\n' > "$hblk"
        : > "$new_pins"
        cnt=0
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            [ "$cnt" -ge "${PIN_MAX:-8}" ] && break
            ip1=""
            if [ "$cache_ok" = "1" ]; then
                ip1=$(echo "$prev_pins" | awk -v dd="$d" '$1==dd {print $2; exit}')
            fi
            if [ -z "$ip1" ]; then
                ip1=$(pick_ips "$d" 1 | sed '/^$/d' | head -1)
                [ -n "$ip1" ] && logi "  测速固定 ${d} -> ${ip1}"
            else
                logd "  复用已固定 IP ${d} -> ${ip1}"
            fi
            [ -z "$ip1" ] && { logw "  ${d} 解析不到可用 IP，跳过固定"; continue; }
            printf '  "%s": %s\n' "$d" "$ip1" >> "$hblk"
            printf '%s %s\n' "$d" "$ip1" >> "$new_pins"
            cnt=$((cnt+1))
        done < "$DOMFILE"
        printf '  # <<< subguard:host:end <<<\n' >> "$hblk"
        [ "$cnt" -gt 0 ] && [ -s "$new_pins" ] && { mv -f "$new_pins" "$pin_file"; date +%s > "$pin_ts" 2>/dev/null; }
        if [ "$cnt" -gt 0 ]; then
            grep -qE '^hosts:' "$CONF" || printf '\nhosts:\n' >> "$CONF"
            if apply_block "$CONF" '^hosts:' "$hblk" "host"; then
                logi "已更新 hosts 固定（${cnt} 条）"
                changed=1
            fi
        fi
    fi

    # ---- 3) AdGuardHome 放行规则 ----
    if [ "${AGH_EXCEPT:-1}" = "1" ]; then
        ay="$(agh_yaml 2>/dev/null)"
        if [ -n "$ay" ] && [ -f "$ay" ]; then
            ablk="${SUBG_STATE}/.agh.blk"
            printf '  # >>> subguard:agh:begin >>>\n' > "$ablk"
            while IFS= read -r d; do
                [ -z "$d" ] && continue
                printf "  - '@@||%s^\$important'\n" "$d" >> "$ablk"
                if [ "${AGH_REWRITE:-0}" = "1" ] && [ -f "$pin_file" ]; then
                    ipx=$(awk -v dd="$d" '$1==dd {print $2; exit}' "$pin_file" 2>/dev/null)
                    [ -n "$ipx" ] && printf "  - '||%s^\$dnsrewrite=%s'\n" "$d" "$ipx" >> "$ablk"
                fi
            done < "$DOMFILE"
            printf '  # <<< subguard:agh:end <<<\n' >> "$ablk"
            if [ -s "$ablk" ]; then
                grep -qE '^user_rules:' "$ay" || printf '\nuser_rules:\n' >> "$ay"
                backup_file "$ay" apply
                if apply_block "$ay" '^user_rules:' "$ablk" "agh"; then
                    logi "已更新 AdGuardHome user_rules（$(grep -c '@@' "$ablk" | tr -d ' ') 条放行）"
                    changed=2
                    AGH_CHANGED=1
                fi
            fi
        fi
    fi

    # ---- 4) 生效 ----
    [ "$changed" -ge 1 ] && reload_core "例外规则更新"
    # 开机模式下先不动 AGH 进程，等内核就绪后统一处理
    [ "$AGH_CHANGED" = "1" ] && [ "${SUBG_BOOT_MODE:-0}" != "1" ] && agh_restart

    # ---- 5) 关掉会删档的官方更新 ----
    [ "${TAKE_OVER_UPDATE:-1}" = "1" ] && [ -f /data/adb/box/settings.ini ] && take_over_box_update
    return 0
}

take_over_box_update() {
    si=/data/adb/box/settings.ini
    changed=0
    for kv in update_subscription renew; do
        cur=$(sed -n "s/^[[:space:]]*${kv}=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*$/\1/p" "$si" | tail -1)
        if [ "$cur" != "false" ] && [ -n "$cur" ]; then
            backup_file "$si" before
            sed -i "s/^[[:space:]]*${kv}=.*/${kv}=\"false\"/" "$si"
            changed=1
            logi "已设置 settings.ini: ${kv}=\"false\"（改由 subguard 安全更新，避免失败删档）"
        fi
    done
    [ "$changed" = "1" ] && logi "提示：settings.ini 改动建议重启一次模块"
    return 0
}

# 只走 API 热重载，绝不启停进程
hot_reload() {
    [ -n "$CURL" ] || return 1
    core_running || return 1
    port=$(sed -n 's/^external-controller:[[:space:]]*//p' "$CONF" 2>/dev/null | head -1 | tr -d '"')
    secret=$(sed -n 's/^secret:[[:space:]]*//p' "$CONF" 2>/dev/null | head -1 | tr -d '"'"'")
    p="${port##*:}"; [ -z "$p" ] && p=9090
    p="${p##* }"
    if [ -n "$secret" ]; then
        "$CURL" -s --max-time 8 -X PUT -H "Authorization: Bearer ${secret}" -H 'Content-Type: application/json' \
            -d "{\"path\":\"${CONF}\"}" "http://127.0.0.1:${p}/configs?force=true" >/dev/null 2>&1 && return 0
    else
        "$CURL" -s --max-time 8 -X PUT -H 'Content-Type: application/json' \
            -d "{\"path\":\"${CONF}\"}" "http://127.0.0.1:${p}/configs?force=true" >/dev/null 2>&1 && return 0
    fi
    return 1
}

reload_core() {
    reason="$1"

    # 开机模式：只写配置，绝不重启内核（重启会与 box_service.sh 抢端口）
    if [ "${SUBG_BOOT_MODE:-0}" = "1" ]; then
        if hot_reload; then
            logi "内核已热重载（${reason}）"
        else
            logi "配置已写入；内核此刻未就绪，本次不动进程（开机模式，下次启动自动生效）"
        fi
        return 0
    fi

    if hot_reload; then
        logi "内核已热重载配置（${reason}）"
        return 0
    fi
    if [ -f /data/adb/agh/scripts/restart.sh ]; then
        sh /data/adb/agh/scripts/restart.sh box >/dev/null 2>&1 && { logi "已通过 restart.sh 重启 box（含配置检测）"; return 0; }
    fi
    control_core restart && logi "已重启内核（${reason}）"
    return 0
}

# ============================================================
#  update —— 安全拉取「所有」订阅
# ============================================================
fetch_once() {
    url="$1"; out="$2"; ua="$3"; ck="$4"; rsv="$5"
    [ -z "$CURL" ] && return 1
    set -- -sL --insecure --http1.1 --compressed --max-time 30 -A "$ua" \
           -H 'Accept: */*' -H 'Accept-Language: zh-CN,zh;q=0.9' -o "$out" -w '%{http_code}'
    [ -n "$rsv" ] && set -- "$@" --resolve "$rsv"
    [ -n "$ck" ] && set -- "$@" -H "Cookie: $ck"
    code=$("$CURL" "$@" "$url" 2>/dev/null)
    echo "${code:-000}"
}

restore_lastgood() {
    name="$1"; target="$2"
    if [ -s "${SUBG_LASTGOOD}/${name}" ] && valid_payload "${SUBG_LASTGOOD}/${name}"; then
        mkdir -p "$(dirname "$target")" 2>/dev/null
        cp -f "${SUBG_LASTGOOD}/${name}" "$target"
        logw "已用 lastgood 缓存恢复 ${target}"
        return 0
    fi
    return 1
}

update_one() {
    name="$1"; url="$2"; target="$3"
    tmp="${target}.subguard.tmp"
    mkdir -p "$(dirname "$target")" 2>/dev/null
    rm -f "$tmp"
    [ -z "$CURL" ] && { loge "没有 curl，无法更新"; return 1; }

    ok=0; why=""
    for ua in $UA_LIST; do
        code=$(fetch_once "$url" "$tmp" "$ua")
        if valid_payload "$tmp"; then ok=1; why="UA=$(echo "$ua" | cut -c1-24) HTTP=$code"; break; fi
        if is_challenge "$tmp"; then why="HTTP=$code Cloudflare挑战页"; else why="HTTP=$code 内容无效"; fi
        logd "尝试失败: UA=$ua -> $why"
    done

    if [ "$ok" != "1" ] && [ -n "$CF_CLEARANCE" ]; then
        ua="${CF_UA:-Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36}"
        code=$(fetch_once "$url" "$tmp" "$ua" "cf_clearance=${CF_CLEARANCE}")
        if valid_payload "$tmp"; then ok=1; why="cf_clearance HTTP=$code"; else why="cf_clearance无效/过期 HTTP=$code"; fi
    fi

    if [ "$ok" != "1" ] && [ "${PIN_IP:-1}" = "1" ] && [ -s "${SUBG_STATE}/pinned.txt" ]; then
        host=$(host_of_url "$url")
        for ip in $(awk -v h="$host" '$1==h {print $2}' "${SUBG_STATE}/pinned.txt" 2>/dev/null); do
            code=$(fetch_once "$url" "$tmp" "$(echo $UA_LIST | awk '{print $1}')" "" "${host}:443:${ip}")
            if valid_payload "$tmp"; then ok=1; why="IP固定 $ip HTTP=$code"; break; fi
        done
    fi

    if [ "$ok" != "1" ] && [ "${ALLOW_IP_ROTATE:-0}" = "1" ]; then
        i=0
        while [ "$i" -lt "${ROTATE_TRIES:-1}" ] && [ "$ok" != "1" ]; do
            i=$((i+1)); logw "尝试换 IP 重试 #$i"
            toggle_airplane; sleep 8; wait_net 30
            for ua in $UA_LIST; do
                code=$(fetch_once "$url" "$tmp" "$ua")
                if valid_payload "$tmp"; then ok=1; why="换IP后成功 UA=$ua"; break; fi
            done
        done
    fi

    if [ "$ok" = "1" ]; then
        maybe_decode "$tmp" "${tmp}.dec"
        if valid_payload "${tmp}.dec"; then mv -f "${tmp}.dec" "$tmp"; else rm -f "${tmp}.dec"; fi
        mv -f "$tmp" "$target"
        mkdir -p "$SUBG_LASTGOOD" 2>/dev/null
        cp -f "$target" "${SUBG_LASTGOOD}/${name}" 2>/dev/null
        logi "订阅 [${name}] 更新成功（${why}，$(wc -c < "$target" | tr -d ' ') 字节）"
        return 0
    fi

    rm -f "$tmp"
    loge "订阅 [${name}] 更新失败：${why:-未知}（原文件保持不动）"
    if [ ! -s "$target" ] || ! valid_payload "$target"; then restore_lastgood "$name" "$target"; fi
    return 1
}

toggle_airplane() {
    cur=$(settings get global airplane_mode_on 2>/dev/null | tr -d ' ')
    if [ "$cur" = "1" ]; then
        settings put global airplane_mode_on 0
        am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
        logi "已关闭飞行模式"
    else
        settings put global airplane_mode_on 1
        am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
        logi "已打开飞行模式（换 IP）"; sleep 3
        settings put global airplane_mode_on 0
        am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
        logi "已关闭飞行模式"
    fi
}

# 解析一条发现记录的落盘路径
target_of() {
    _name="$1"; _path="$2"; _src="$3"
    if [ -n "$_path" ]; then printf '%s\n' "$_path"
    elif [ "$_src" = "config.yaml" ] && [ -n "$CONF" ]; then printf '%s\n' "$(dirname "$CONF")/proxy_provider/${_name}.yaml"
    else printf '%s\n' "${SUBG_DATA}/provider/${_name}.yaml"; fi
}

cmd_update() {
    detect
    [ "$(id -u)" = "0" ] || { loge "更新订阅需要 root"; return 1; }
    mkdir -p "$SUBG_DATA/provider" 2>/dev/null

    pairs="$(discover_unique)"
    if [ -z "$pairs" ]; then
        loge "没有发现任何订阅源，请检查 config.yaml / settings.ini / config.prop，或在 config.conf 里填 SUBS="
        return 1
    fi
    cnt=$(printf '%s\n' "$pairs" | grep -c 'http')
    logi "发现 ${cnt} 个订阅源，开始安全更新"

    rm -f "${SUBG_STATE}/.upd.ok"
    printf '%s\n' "$pairs" | while IFS='|' read -r n u p s; do
        [ -z "$u" ] && continue
        case "$u" in http*) ;; *) continue ;; esac
        tgt="$(target_of "$n" "$p" "$s")"
        logi "→ [${n}] 来源=${s}"
        update_one "$n" "$u" "$tgt" && echo ok >> "${SUBG_STATE}/.upd.ok"
    done

    if [ -f "${SUBG_STATE}/.upd.ok" ]; then
        rm -f "${SUBG_STATE}/.upd.ok"
        date "+%Y-%m-%d %H:%M:%S" > "${SUBG_STATE}/last_update.txt"
        reload_core "订阅已更新"
        # 订阅域可能变了 → 立刻重建例外
        newd="$(collect_domains)"
        [ "$newd" != "$(cat "$DOMFILE" 2>/dev/null)" ] && { logi "检测到订阅域名变化，重建自动例外"; cmd_apply; }
        return 0
    fi
    logw "本次没有任何订阅更新成功（已有订阅仍可正常使用）"
    return 1
}

# ============================================================
#  learn —— 看自动发现了什么
# ============================================================
cmd_learn() {
    detect
    echo "=============================================================="
    echo " 自动发现的订阅源"
    echo "=============================================================="
    if [ -z "$(discover_unique)" ]; then
        echo "  （没有发现，检查 config.yaml 的 proxy-providers）"
    else
        discover_unique | while IFS='|' read -r n u p s; do
            printf '  [%-12s] 来源 %-12s\n' "$n" "$s"
            printf '      url  : %s\n' "$(echo "$u" | sed -E 's#(token|key|pwd|password|auth)=[^&]*#\1=***#g; s#(/[A-Za-z0-9_-]{24,})#/***#g')"
            printf '      域名 : %s\n' "$(to_ascii_host "$u")"
            [ -n "$p" ] && printf '      落盘 : %s\n' "$p"
        done
    fi
    echo
    echo "=============================================================="
    echo " 需要强制直连的域名（自动去重 + punycode 规范化）"
    echo "=============================================================="
    if [ "${AUTO_DISCOVER:-1}" = "1" ]; then collect_domains | sed 's/^/  /'; else
        for d in $PROTECT_DOMAINS; do echo "  $(to_ascii_host "$d")"; done
    fi
    echo
    echo "提示：新增/更换订阅后，执行  sh $0 apply  即可让新域名自动获得例外。"
}

# ============================================================
#  健康检查 / fail-open
# ============================================================
dns_ok() { ping -c1 -W3 www.baidu.com >/dev/null 2>&1 || ping -c1 -W3 cp.cloudflare.com >/dev/null 2>&1; }
ip_ok()  { ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; }

fail_open() {
    logw "===== fail-open：停掉代理内核，恢复系统原生网络 ====="
    control_core stop
    sleep 2
    logw "已完成。网络不再依赖代理；修好订阅后手动启用模块即可。"
    echo "fail-open $(subg_ts)" >> "${SUBG_STATE}/failopen.log"
    date +%s > "${SUBG_STATE}/failopen.ts" 2>/dev/null
}

cmd_watch() {
    detect
    logi "守护启动（间隔 ${CHECK_INTERVAL}s，fail-open=${FAIL_OPEN}）"
    bad=0
    now=$(date +%s 2>/dev/null || echo 0)
    last_upd="$now"; last_pin="$now"; last_dom="$now"
    grace_until=$((now + ${BOOT_GRACE:-180}))

    while :; do
        sleep "$CHECK_INTERVAL"
        module_disabled && { logd "模块被手动禁用，守护暂停"; bad=0; continue; }

        if [ -f "${SUBG_STATE}/failopen.ts" ]; then
            fo=$(cat "${SUBG_STATE}/failopen.ts" 2>/dev/null | tr -d ' ')
            now0=$(date +%s 2>/dev/null || echo 0)
            case "$fo" in ''|*[!0-9]*) fo=0 ;; esac
            if [ "$fo" -gt 0 ] && [ $((now0 - fo)) -lt 900 ]; then logd "fail-open 冷却中"; continue; fi
        fi

        if ! core_running; then
            now0=$(date +%s 2>/dev/null || echo 0)
            if [ "$now0" -lt "$grace_until" ]; then
                logd "开机宽限期内（还剩 $((grace_until - now0))s），不介入内核启动"
                continue
            fi
            bad=$((bad+1)); logw "内核未运行（第 ${bad} 次）"
            if [ "$bad" -le 2 ]; then control_core start || control_core restart
            elif [ "${FAIL_OPEN:-1}" = "1" ]; then fail_open; bad=0; fi
            continue
        fi

        if ip_ok && ! dns_ok; then
            bad=$((bad+1)); logw "网络在但 DNS/出站异常（第 ${bad} 次）——可能节点全挂"
            if [ "$bad" -le 2 ]; then control_core restart
            elif [ "${FAIL_OPEN:-1}" = "1" ]; then fail_open; bad=0; fi
            continue
        fi
        bad=0

        now=$(date +%s 2>/dev/null || echo 0)
        if [ $((now - last_upd)) -ge "${UPDATE_INTERVAL:-21600}" ]; then
            last_upd="$now"; logi "定时安全更新订阅"; ( cmd_update ) >/dev/null 2>&1
        fi
        if [ $((now - last_pin)) -ge "${PIN_INTERVAL:-43200}" ]; then
            last_pin="$now"; ( cmd_apply ) >/dev/null 2>&1
        fi
        # 每 10 分钟检查一次「订阅源有没有变化」（新增/更换订阅 → 自动加例外）
        if [ $((now - last_dom)) -ge 600 ]; then
            last_dom="$now"
            nd="$(collect_domains)"
            if [ -n "$nd" ] && [ "$nd" != "$(cat "$DOMFILE" 2>/dev/null)" ]; then
                logi "检测到订阅域名变化，自动重建例外"; ( cmd_apply ) >/dev/null 2>&1
            fi
        fi
    done
}

# ============================================================
#  体检
# ============================================================
cmd_doctor() {
    detect
    L="${SUBG_LOG_DIR}/doctor-$(date +%Y%m%d-%H%M%S 2>/dev/null).txt"
    {
    echo "=============================================================="
    echo " subguard doctor  v${SUBG_VERSION}    $(date 2>/dev/null)"
    echo "=============================================================="
    echo "[1] 运行环境"
    echo "    root          : $(id -u 2>/dev/null)"
    echo "    机型/系统     : $(getprop ro.product.model 2>/dev/null) / Android $(getprop ro.build.version.release 2>/dev/null)"
    echo "    代理模块      : ${ENGINE:-未知}"
    echo "    内核配置      : ${CONF:-未找到}"
    _cc=$(core_count)
    echo "    内核进程      : $([ "$_cc" -gt 0 ] && echo "运行中（${_cc} 个）" || echo 未运行)$([ "$_cc" -gt 1 ] && echo "  ⚠️ 有重复进程，会抢端口！执行 restart-core")"
    echo "    AdGuardHome   : $(agh_yaml 2>/dev/null || echo 未找到) / $(agh_running && echo 运行中 || echo 未运行)"
    echo "    curl          : ${CURL:-未找到}"
    echo
    echo "[2] 自动发现的订阅源（不写死，任意订阅都会被抓到）"
    if [ -z "$(discover_unique)" ]; then
        echo "    （无）"
    else
        discover_unique | while IFS='|' read -r n u p s; do
            printf '    [%-12s] %-12s %s\n' "$n" "$s" "$(to_ascii_host "$u")"
            printf '        %s\n' "$(echo "$u" | sed -E 's#(token|key|pwd|password|auth)=[^&]*#\1=***#g; s#(/[A-Za-z0-9_-]{24,})#/***#g')"
        done
    fi
    echo
    echo "[3] 需要直连的域名（自动发现 + 手写）"
    if [ "${AUTO_DISCOVER:-1}" = "1" ]; then collect_domains | sed 's/^/    /'; else
        for d in $PROTECT_DOMAINS; do echo "    $(to_ascii_host "$d")"; done
    fi
    [ -s "${SUBG_STATE}/pinned.txt" ] && while read -r l; do echo "    已固定: $l"; done < "${SUBG_STATE}/pinned.txt"
    echo "    subguard 最后更新: $(cat "${SUBG_STATE}/last_update.txt" 2>/dev/null || echo 从未)"
    echo
    echo "[4] 例外是否已写入"
    if [ -f "$CONF" ]; then
        nb=$(sed -n '/# >>> subguard:rule:begin >>>/,/# <<< subguard:rule:end <<</p' "$CONF" 2>/dev/null | grep -c 'DOMAIN-SUFFIX')
        hb=$(sed -n '/# >>> subguard:host:begin >>>/,/# <<< subguard:host:end <<</p' "$CONF" 2>/dev/null | grep -c '":')
        if [ "$nb" -gt 0 ]; then echo "    ✔ mihomo 直连规则块：${nb} 条"; else echo "    ✘ 没有直连规则块 → 执行 sh $0 apply"; fi
        [ "$hb" -gt 0 ] && echo "    ✔ mihomo hosts 固定：${hb} 条"
    fi
    ay="$(agh_yaml 2>/dev/null)"
    if [ -n "$ay" ]; then
        ab=$(sed -n '/# >>> subguard:agh:begin >>>/,/# <<< subguard:agh:end <<</p' "$ay" 2>/dev/null | grep -c 'important')
        if [ "$ab" -gt 0 ]; then echo "    ✔ AGH user_rules 放行：${ab} 条"; else echo "    · AGH 放行块未写入（AGH_EXCEPT=0 或未执行 apply）"; fi
    fi
    echo
    echo "[5] 连通性"
    echo "    直连 IP 223.5.5.5 : $(ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 && echo 通 || echo 不通)"
    echo "    域名解析 baidu.com: $(ping -c1 -W3 www.baidu.com >/dev/null 2>&1 && echo 正常 || echo 失败)"
    echo
    echo "[6] 逐域名拉取实测（关键：能过就不需要任何绕过）"
    if [ -z "$(discover_unique)" ]; then echo "    （无订阅源）"; else
        discover_unique | while IFS='|' read -r n u p s; do
            [ -z "$u" ] && continue
            tmp="${SUBG_STATE}/.probe"
            h=$(to_ascii_host "$u")
            echo "    --- [${n}] ${h}"
            ok=0
            for ua in $UA_LIST; do
                code=$(fetch_once "$u" "$tmp" "$ua")
                if valid_payload "$tmp"; then
                    echo "        UA=$(echo "$ua" | cut -c1-22) → HTTP $code  ✔ 可取到订阅"; ok=1; break
                fi
                if is_challenge "$tmp"; then
                    echo "        UA=$(echo "$ua" | cut -c1-22) → HTTP $code  ✘ CF 挑战页"
                else
                    echo "        UA=$(echo "$ua" | cut -c1-22) → HTTP $code  ✘ 无效($(wc -c < "$tmp" 2>/dev/null | tr -d ' ')B)"
                fi
            done
            [ "$ok" = "0" ] && echo "        → 该源拉不到；脚本会保留旧订阅，不影响现有网络"
            rm -f "$tmp"
        done
    fi
    echo
    echo "[7] 结论"
    echo "    · 只要 [6] 里有 ✔，日常更新就没问题；全 ✘ 也不会断网（保留 lastgood + fail-open）"
    echo "    · 新增/更换订阅后：sh $0 apply   （watch 也会每 10 分钟自动检测）"
    echo "    · 报告已保存: $L"
    echo "=============================================================="
    } | tee "$L"
    return 0
}

cmd_status() {
    detect
    echo "模块: ${ENGINE:-未知}   内核: $(core_running && echo 运行中 || echo 未运行)"
    discover_unique | while IFS='|' read -r n u p s; do
        f="$(target_of "$n" "$p" "$s")"
        if [ -s "$f" ]; then
            v="$(valid_payload "$f" && echo ✔ || echo ✘)"
            printf '  %-14s %8sB %s  %s\n' "$n" "$(wc -c < "$f" | tr -d ' ')" "$v" "$(host_of_url "$u")"
        else
            printf '  %-14s %8s  %s\n' "$n" "缺失!" "-"
        fi
    done
    echo "  最后更新: $(cat "${SUBG_STATE}/last_update.txt" 2>/dev/null || echo 从未)"
}

cmd_test_url() {
    u="$1"; [ -z "$u" ] && { echo "用法: sh $0 test-url <URL>"; return 1; }
    detect
    tmp="${SUBG_STATE}/.probe"
    for ua in $UA_LIST; do
        code=$(fetch_once "$u" "$tmp" "$ua")
        if valid_payload "$tmp"; then echo "✔ UA=$ua HTTP=$code 可正常获取"; return 0; fi
        if is_challenge "$tmp"; then echo "✘ UA=$ua HTTP=$code → CF 挑战页"; else echo "✘ UA=$ua HTTP=$code → 无效内容"; fi
    done
    rm -f "$tmp"
    return 1
}

# 清掉重复内核进程并干净地重起一次（用于修复已经发生的端口冲突）
cmd_restart_core() {
    detect
    n=$(core_count)
    logi "当前内核进程数: ${n}"
    if [ "$n" -gt 0 ]; then
        for _pid in $(core_pids); do
            logi "  结束 mihomo/sing-box 进程 ${_pid}"
            kill -TERM "$_pid" 2>/dev/null
        done
        sleep 3
        for _pid in $(core_pids); do
            logw "  强制结束 ${_pid}"
            kill -KILL "$_pid" 2>/dev/null
        done
    fi
    rm -f /data/adb/box/run/box.pid 2>/dev/null
    SUBG_BOOT_MODE=0; export SUBG_BOOT_MODE
    logi "重新启动内核…"
    control_core start
    sleep 4
    if core_running; then
        logi "✔ 内核已恢复，进程 $(core_pids)"
    else
        loge "✘ 内核未起来，看日志: tail -n 40 /data/adb/box/run/mihomo.log"
    fi
}

cmd_rollback() {
    detect
    [ -n "$CONF" ] && [ -f "$CONF" ] || { loge "找不到配置文件"; return 1; }
    last=$(ls -1t "${SUBG_BACKUP}/$(basename "$CONF")."* 2>/dev/null | head -1)
    [ -z "$last" ] && { loge "没有可用备份"; return 1; }
    backup_file "$CONF" before-rollback
    cp -f "$last" "$CONF" && logi "已回滚配置：$last -> $CONF"
    reload_core "rollback"
}

cmd_boot() {
    load_conf; detect
    acquire_lock || { loge "已有 subguard 在运行，本次启动退出"; return 0; }
    SUBG_BOOT_MODE=1
    export SUBG_BOOT_MODE
    logi "===== subguard boot v${SUBG_VERSION}（开机模式：只写配置，不启停内核）====="
    wait_net 90
    cmd_apply
    if [ -n "$CONF" ] && [ -f "$CONF" ]; then
        discover_unique | while IFS='|' read -r n u p s; do
            t="$(target_of "$n" "$p" "$s")"
            if [ ! -s "$t" ] || ! valid_payload "$t"; then restore_lastgood "$n" "$t"
            else cp -f "$t" "${SUBG_LASTGOOD}/${n}" 2>/dev/null; fi
        done
    fi
    # 等 box_service.sh 把内核拉起来，再解除开机模式（这一步是防端口冲突的关键）
    wait_core_ready 150
    SUBG_BOOT_MODE=0
    export SUBG_BOOT_MODE
    # 内核就绪后补一次热重载（若它在我们写配置之前就读过了）
    if core_running; then
        hot_reload && logi "内核已加载新配置（开机补热重载）"
    fi
    [ "${AGH_CHANGED:-0}" = "1" ] && agh_restart
    ( sleep 20; cmd_update ) >/dev/null 2>&1 &
    cmd_watch
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }


# ============================================================
#  install / uninstall —— 单文件自安装（不产生 Magisk 模块）
# ============================================================
SELF_PATH="${SUBG_SELF:-/data/adb/subguard/subguard.sh}"

service_dirs() {
    # 输出所有需要放启动器的 service.d 目录
    echo "/data/adb/service.d"
    if [ -d /data/adb/ksu/service.d ] && [ ! -L /data/adb/ksu/service.d ]; then
        echo "/data/adb/ksu/service.d"
    fi
}

cmd_install() {
    [ "$(id -u)" = "0" ] || { echo "需要 root（Termux 里用 su）"; return 1; }
    init_dirs
    load_conf

    # 定位自身（可能从 /sdcard 运行）
    src=""
    for c in "$0" "$SELF_PATH" /data/adb/subguard/subguard.sh; do
        [ -f "$c" ] && [ -s "$c" ] && { src="$c"; break; }
    done
    [ -z "$src" ] && { loge "找不到脚本自身，无法安装"; return 1; }

    mkdir -p /data/adb/subguard
    if [ "$(readlink -f "$src" 2>/dev/null)" != "$(readlink -f "$SELF_PATH" 2>/dev/null)" ]; then
        cp -f "$src" "$SELF_PATH" || { loge "复制到 $SELF_PATH 失败"; return 1; }
    fi
    chmod 0755 "$SELF_PATH"
    logi "已安装: $SELF_PATH"

    # 开机启动器（zz_ 前缀保证在 box_service.sh 之后执行）
    for d in $(service_dirs); do
        [ -d "$d" ] || continue
        cat > "${d}/zz_subguard.sh" <<'HOOK'
#!/system/bin/sh
# subguard 开机入口（由 subguard.sh install 生成）
sleep 8
[ -x /data/adb/subguard/subguard.sh ] && exec sh /data/adb/subguard/subguard.sh boot
HOOK
        chmod 0755 "${d}/zz_subguard.sh"
        logi "已写开机入口: ${d}/zz_subguard.sh"
    done

    # 防止 box 自带更新删档
    [ -f /data/adb/box/settings.ini ] && take_over_box_update

    logi "安装完成，立即执行一次 apply"
    cmd_apply
    echo
    echo "下一步："
    echo "  1) 重启手机（或直接后台跑：nohup sh $SELF_PATH boot >/dev/null 2>&1 &）"
    echo "  2) 查看自动识别到的订阅： sh $SELF_PATH learn"
    echo "  3) 体检：                 sh $SELF_PATH doctor"
    return 0
}

cmd_uninstall() {
    for d in $(service_dirs); do
        rm -f "${d}/zz_subguard.sh" 2>/dev/null && logi "已移除 ${d}/zz_subguard.sh"
    done
    # 停掉守护循环
    ps -A 2>/dev/null | grep '[s]ubguard.sh watch' | awk '{print $2}' | while read -r p; do
        kill -TERM "$p" 2>/dev/null
    done
    # 从 box start.sh 里摘掉可能存在的 hook 行
    if [ -f /data/adb/box/scripts/start.sh ] && grep -q "subguard" /data/adb/box/scripts/start.sh 2>/dev/null; then
        sed -i '/# >>> subguard hook >>>/,/# <<< subguard hook <<</d' /data/adb/box/scripts/start.sh
        logi "已从 box start.sh 摘掉 hook"
    fi
    [ -f "$SELF_PATH" ] && rm -f "$SELF_PATH"
    echo "已卸载（配置/日志保留在 ${SUBG_DATA}，彻底清除: rm -rf ${SUBG_DATA}）"
    return 0
}

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

case "$1" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    doctor)    need_root "$@"; load_conf; cmd_doctor ;;
    apply)     need_root "$@"; load_conf; cmd_apply ;;
    update)    need_root "$@"; load_conf; cmd_update ;;
    learn)     load_conf; cmd_learn ;;
    status)    load_conf; cmd_status ;;
    boot)      need_root "$@"; cmd_boot ;;
    watch)     need_root "$@"; load_conf; cmd_watch ;;
    test-url)  need_root "$@"; load_conf; cmd_test_url "$2" ;;
    rollback)  need_root "$@"; load_conf; cmd_rollback ;;
    restart-core) need_root "$@"; load_conf; cmd_restart_core ;;
    *)         usage ;;
esac
