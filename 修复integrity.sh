#!/system/bin/sh
# ============================================================
#  修复 Play Integrity 限流(-8 TOO_MANY_REQUESTS)
#  思路: Integrity 域名改走 国内DoH解析 + mihomo直连国内边缘节点
#  自动检测国内DoH解析是否干净, 干净才套用, 全程带备份回滚
#  运行: su -c "sh 修复integrity.sh"
# ============================================================
AGH_DIR="/data/adb/agh"
BOX_DIR="/data/adb/box"
YAML="$AGH_DIR/bin/AdGuardHome.yaml"
CFG="$BOX_DIR/mihomo/config.yaml"
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
hr() { echo ""; echo "=================================================="; }
BIN="$AGH_DIR/bin/AdGuardHome"
kill_agh() {
    for p in /proc/[0-9]*; do
        c=
        IFS= read -r c < "$p/cmdline"
        case "$c" in
            "$BIN"*) kill "${p#/proc/}" 2>/dev/null ;;
        esac
    done
}
wait_agh() {
    # AGH 由 iptables.sh 守护循环自动拉起(每5秒), 最多等 12 秒, 超时手动拉起
    i=0
    while [ $i -lt 12 ]; do
        pidof AdGuardHome > /dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    if ! pidof AdGuardHome > /dev/null 2>&1; then
        export SSL_CERT_DIR="/system/etc/security/cacerts/"
        "$BIN" --no-check-update &
        sleep 3
    fi
}

port=$(sed -n '/^dns:/,/^[^[:space:]]/s/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML" | head -n 1)
[ -n "$port" ] || port=53
DS="checking.play.googleapis.com playintegrity.googleapis.com safetynet.googleapis.com"

hr; echo "[1] 国内 DoH(1.12.12.12) 对 Integrity 域名的解析检测"
allclean=1
for d in $DS; do
    json=$(curl -s -m 8 -H "accept: application/dns-json" \
        "https://1.12.12.12/dns-query?name=$d&type=A" 2>/dev/null)
    ips=$(echo "$json" | grep -o '"data":"[^"]*"' | sed 's/"data":"//;s/"//' | tr '\n' ' ')
    clean=0
    case "$ips" in
        *203.208.*|*120.253.*|*180.163.*) clean=1 ;;
    esac
    [ "$clean" = "1" ] && tag="干净(国内边缘)" || tag="不干净/被污染"
    [ "$clean" = "1" ] || allclean=0
    echo "  $d"
    echo "    解析: ${ips:-无应答} -> $tag"
done

hr; echo "[2] 检测结论与处理"
if [ "$allclean" != "1" ]; then
    echo "  国内 DoH 解析不干净, 直连方案不可用。"
    echo "  限流是机场共享出口 IP 触发的, 只能:"
    echo "    a) mihomo 面板(127.0.0.1:9090/ui)换一个节点, 等 10 分钟重试"
    echo "    b) 或等限流自然过期(通常 10-30 分钟)"
    echo "  未对系统做任何修改。"
    exit 0
fi
echo "  国内 DoH 解析干净, 自动套用直连方案..."

hr; echo "[3] AGH: Integrity 域名解析改回国内 DoH"
bak="$YAML.bak.integrity.$(date +%m%d%H%M)"
cp -f "$YAML" "$bak"
NEWUP="[\/checking.play.googleapis.com\/playintegrity.googleapis.com\/safetynet.googleapis.com\/]https://1.12.12.12/dns-query"
if grep -q "checking.play.googleapis.com" "$YAML"; then
    echo "  已存在, 跳过"
else
    "$BB" awk -v ins="    - '$NEWUP'" '
        !done && /^  upstream_dns:/ { print; print ins; done=1; next } { print }' \
        "$YAML" > "$YAML.tmp" && mv "$YAML.tmp" "$YAML" && echo "  已插入(位于 googleapis 宽规则之前)"
fi
# kill AGH 后由守护循环自动拉起
kill_agh
wait_agh
chk=$("$BB" nslookup checking.play.googleapis.com "127.0.0.1:$port" 2>/dev/null | grep -o "203\.208\.[0-9.]*\|120\.253\.[0-9.]*\|180\.163\.[0-9.]*" | head -n 1)
if [ -n "$chk" ]; then
    echo "  AGH 已生效: checking.play.googleapis.com -> $chk (国内边缘)"
else
    echo "  !! AGH 解析未见国内边缘 IP, 回滚 AGH 配置"
    cp -f "$bak" "$YAML"
    kill_agh
    wait_agh
    exit 1
fi

hr; echo "[4] mihomo: Integrity 域名改为国内直连"
bakc="$CFG.bak.integrity.$(date +%m%d%H%M)"
cp -f "$CFG" "$bakc"
if grep -q "playintegrity.googleapis.com,国内直连" "$CFG"; then
    echo "  已存在, 跳过"
else
    if grep -q "DST-PORT,53" "$CFG"; then
        "$BB" awk '
            !done && /DST-PORT,53/ {
                print
                print "  - DOMAIN,playintegrity.googleapis.com,国内直连"
                print "  - DOMAIN,checking.play.googleapis.com,国内直连"
                print "  - DOMAIN,safetynet.googleapis.com,国内直连"
                done=1; next
            } { print }' "$CFG" > "$CFG.tmp"
    else
        "$BB" awk '
            !done && /MATCH,/ {
                print "  - DOMAIN,playintegrity.googleapis.com,国内直连"
                print "  - DOMAIN,checking.play.googleapis.com,国内直连"
                print "  - DOMAIN,safetynet.googleapis.com,国内直连"
                done=1
            } { print }' "$CFG" > "$CFG.tmp"
    fi
    mv "$CFG.tmp" "$CFG"
    echo "  已插入 3 条直连规则(位于最前部)"
fi
if [ -x "$BOX_DIR/bin/mihomo" ]; then
    if ! timeout 15 "$BOX_DIR/bin/mihomo" -t -d "$BOX_DIR/mihomo" -f "$CFG" > /dev/null 2>&1; then
        echo "  !! 配置检测失败, 回滚 mihomo"
        cp -f "$bakc" "$CFG"
        exit 1
    fi
fi
"$BOX_DIR/scripts/box.service" restart
bin_name=$(sed -n 's/^bin_name="\([^"]*\)".*/\1/p' "$BOX_DIR/settings.ini" 2>/dev/null)
[ -n "$bin_name" ] || bin_name="mihomo"
sleep 4
if pidof "$bin_name" > /dev/null 2>&1; then
    code=$(curl -x "http://127.0.0.1:7890" -s -o /dev/null -w "%{http_code}" -m 8 \
        "https://cp.cloudflare.com/generate_204" 2>/dev/null)
    echo "  mihomo 重启成功, 代理抽查: HTTP $code"
else
    echo "  !! mihomo 启动失败, 回滚"
    cp -f "$bakc" "$CFG"
    "$BOX_DIR/scripts/box.service" restart
    exit 1
fi

hr
echo "修复已应用。Integrity 限流记录在 Google 侧有保留期:"
echo "  等 10-30 分钟再打开之前报错的应用重试。"
echo "  若仍报 -8, 在 mihomo 面板换一个节点(旧出口 IP 可能仍被限流)。"
echo "备份: $bak / $bakc"
hr
