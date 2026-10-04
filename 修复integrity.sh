#!/system/bin/sh
# ============================================================
#  修复 Play Integrity 限流(-8 TOO_MANY_REQUESTS)  v2
#  思路: 公共DoH拿不到Google国内边缘记录(实测1.12.12.12/223.5.5.5
#        均返回全球IP 172.217.x, 直连不通), 改用 AGH $dnsrewrite 把
#        playintegrity/safetynet 钉到 Google 中国移动边缘 IP
#        (120.253.253.x, 实测TLS+404正常, 国内境内路径不过GFW),
#        mihomo 对这2个域名走国内直连, 让 Integrity 请求从本机
#        真实IP发出, 绕开机场共享出口的限流。
#  特性: 全程备份, AGH解析验证/mihomo配置检测/端到端连通性三重
#        失败自动回滚。
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
rollback_all() {
    cp -f "$bak" "$YAML" 2>/dev/null
    cp -f "$bakc" "$CFG" 2>/dev/null
    kill_agh; wait_agh
    "$BOX_DIR/scripts/box.service" restart 2>/dev/null
}

[ -f "$YAML" ] || { echo "未找到 $YAML"; exit 1; }
[ -f "$CFG" ] || { echo "未找到 $CFG"; exit 1; }
port=$(sed -n '/^dns:/,/^[^[:space:]]/s/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML" | head -n 1)
[ -n "$port" ] || port=53

bak="$YAML.bak.integrity.$(date +%m%d%H%M)"
bakc="$CFG.bak.integrity.$(date +%m%d%H%M)"

hr; echo "[1] AGH: 把 playintegrity/safetynet 钉到国内边缘IP"
cp -f "$YAML" "$bak"
if grep -q "dnsrewrite=120.253.253" "$YAML"; then
    echo "  已存在, 跳过"
else
    "$BB" awk '
        !done && /^user_rules:/ {
            print
            print "  - '"'"'||playintegrity.googleapis.com^$dnsrewrite=120.253.253.226'"'"'"
            print "  - '"'"'||playintegrity.googleapis.com^$dnsrewrite=120.253.253.34'"'"'"
            print "  - '"'"'||safetynet.googleapis.com^$dnsrewrite=120.253.253.226'"'"'"
            print "  - '"'"'||safetynet.googleapis.com^$dnsrewrite=120.253.253.34'"'"'"
            done=1; next
        } { print }' "$YAML" > "$YAML.tmp" && mv "$YAML.tmp" "$YAML" \
        && echo "  已注入 4 条 dnsrewrite(每域名2个边缘IP互备)"
fi
kill_agh; wait_agh
chk=$("$BB" nslookup playintegrity.googleapis.com "127.0.0.1:$port" 2>/dev/null | grep -o "120\.253\.253\.[0-9.]*" | head -n 1)
if [ -n "$chk" ]; then
    echo "  AGH 验证通过: playintegrity.googleapis.com -> $chk"
else
    echo "  !! AGH 解析未见 120.253.253.x, 回滚"
    cp -f "$bak" "$YAML"; kill_agh; wait_agh
    exit 1
fi

hr; echo "[2] mihomo: Integrity 域名改为国内直连"
cp -f "$CFG" "$bakc"
if grep -q "playintegrity.googleapis.com,国内直连" "$CFG"; then
    echo "  已存在, 跳过"
else
    if grep -q "DST-PORT,53" "$CFG"; then
        "$BB" awk '
            !done && /DST-PORT,53/ {
                print
                print "  - DOMAIN,playintegrity.googleapis.com,国内直连"
                print "  - DOMAIN,safetynet.googleapis.com,国内直连"
                done=1; next
            } { print }' "$CFG" > "$CFG.tmp"
    else
        "$BB" awk '
            !done && /MATCH,/ {
                print "  - DOMAIN,playintegrity.googleapis.com,国内直连"
                print "  - DOMAIN,safetynet.googleapis.com,国内直连"
                done=1
            } { print }' "$CFG" > "$CFG.tmp"
    fi
    mv "$CFG.tmp" "$CFG"
    echo "  已插入 2 条直连规则(位于最前部)"
fi
if [ -x "$BOX_DIR/bin/mihomo" ]; then
    if ! timeout 15 "$BOX_DIR/bin/mihomo" -t -d "$BOX_DIR/mihomo" -f "$CFG" > /dev/null 2>&1; then
        echo "  !! 配置检测失败, 回滚"
        cp -f "$bakc" "$CFG"
        exit 1
    fi
fi
"$BOX_DIR/scripts/box.service" restart
bin_name=$(sed -n 's/^bin_name="\([^"]*\)".*/\1/p' "$BOX_DIR/settings.ini" 2>/dev/null)
[ -n "$bin_name" ] || bin_name="mihomo"
sleep 4
if ! pidof "$bin_name" > /dev/null 2>&1; then
    echo "  !! mihomo 启动失败, 回滚"
    rollback_all
    exit 1
fi
echo "  mihomo 重启成功"

hr; echo "[3] 端到端验证(AGH解析->直连国内边缘)"
# 期望任意 HTTP 码(通常 404); 000/超时说明直连路径不通
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 12 \
    "https://playintegrity.googleapis.com/" 2>/dev/null)
case "$code" in
    000|"") 
        echo "  !! playintegrity 直连不通(HTTP $code), 全量回滚"
        rollback_all
        echo "  已回滚到修改前状态。此网络环境下直连方案不可用,"
        echo "  只能: 换节点 或 等限流自然过期(10-30分钟)。"
        exit 1
        ;;
    *)
        echo "  直连验证通过: playintegrity.googleapis.com -> HTTP $code"
        ;;
esac

hr
echo "修复已应用: Integrity 请求现在从本机真实IP直连Google国内边缘。"
echo "  等 10-30 分钟(限流记录过期)再打开之前报错的应用重试。"
echo "  若仍报 -8, 运行: sh 重启.sh box  或在面板换节点后重试。"
echo "备份: $bak / $bakc"
hr
