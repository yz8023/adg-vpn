#!/system/bin/sh
# ============================================================
#  网速诊断二轮 - 换测速目标 + 确认 system 栈正常
#  先验代理是否存活(失败自动回滚), 再用 3 个不同目标测速
#  运行: su -c "sh 优化网速2.sh"
# ============================================================
BOX_DIR="/data/adb/box"
CFG="$BOX_DIR/mihomo/config.yaml"
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
hr() { echo ""; echo "=================================================="; }

mp=$(grep -E "^mixed-port:" "$CFG" | grep -o "[0-9]*")
[ -n "$mp" ] || mp=7890

speed_one() {
    # $1=名称 $2=URL $3=直连(1)或代理(0)
    x=""
    [ "$3" = "0" ] && x="-x http://127.0.0.1:$mp"
    out=$(curl $x -sS -o /dev/null -m 15 \
        -w "%{http_code} %{speed_download}" "$2" 2>&1)
    ec=$?
    code=$(echo "$out" | "$BB" awk '{print $1}')
    spd=$(echo "$out" | "$BB" awk '{print $2}')
    err=$(echo "$out" | grep -iv "^[0-9]" | head -n 1)
    if [ "$ec" != "0" ] || [ "$code" != "200" ] || [ "$spd" = "0" ] || [ -z "$spd" ]; then
        echo "  $1: 失败 (HTTP $code, curl错误码 $ec) ${err:+原因: $err}"
    else
        "$BB" awk -v s="$spd" -v n="$1" 'BEGIN{printf "  %s: %.1f Mbps\n", n, s*8/1000000}'
    fi
}

hr; echo "[1] 代理存活确认 (system 栈)"
if ! pidof mihomo > /dev/null 2>&1; then
    echo "  !! mihomo 没在运行，先回滚再排查"
    bak=$(ls -t "$CFG".bak.* 2>/dev/null | head -n 1)
    [ -n "$bak" ] && cp -f "$bak" "$CFG" && "$BOX_DIR/scripts/box.service" restart && sleep 4
    pidof mihomo > /dev/null 2>&1 && echo "  已回滚 $bak" || echo "  回滚后仍未运行，请重启手机"
    exit 1
fi
code=$(curl -x "http://127.0.0.1:$mp" -s -o /dev/null -w "%{http_code}" -m 8 \
    "https://cp.cloudflare.com/generate_204" 2>/dev/null)
echo "  mihomo 运行中, 经代理 204 测试: HTTP $code"
if [ "$code" != "204" ]; then
    echo "  !! 代理路径不通, 可能 system 栈与设备不兼容, 自动回滚 gvisor..."
    bak=$(ls -t "$CFG".bak.* 2>/dev/null | head -n 1)
    if [ -n "$bak" ]; then
        cp -f "$bak" "$CFG"
        "$BOX_DIR/scripts/box.service" restart
        sleep 4
        code2=$(curl -x "http://127.0.0.1:$mp" -s -o /dev/null -w "%{http_code}" -m 8 \
            "https://cp.cloudflare.com/generate_204" 2>/dev/null)
        [ "$code2" = "204" ] && echo "  已回滚并恢复正常($bak)" || echo "  回滚后仍不通, 请重启手机后告诉我"
    else
        echo "  找不到备份文件, 请重启手机"
    fi
    exit 1
fi
echo "  代理正常"

hr; echo "[2] 手机直连带宽基线 (不经过代理, 腾讯国内CDN)"
speed_one "直连-腾讯CDN" "https://dldir1v6.qq.com/weixin/Windows/WeChatSetup.exe" 1

hr; echo "[3] 经代理多目标测速 (哪个成功用哪个)"
speed_one "代理-cloudflare" "https://speed.cloudflare.com/__down?bytes=50000000" 0
speed_one "代理-cachefly " "http://cachefly.cachefly.net/50mb.test" 0
speed_one "代理-tele2    " "http://speedtest.tele2.net/10MB.zip" 0

hr; echo "[4] mihomo 最近 8 行日志"
tail -n 8 "$BOX_DIR/run/mihomo.log" 2>/dev/null | sed 's/^/  /'

hr
echo "完成。把 [2] 和 [3] 的全部结果发回来。"
echo "判读: 直连快+代理慢 = 节点瓶颈(换节点); 代理全部失败 = 节点封锁测速或节点故障。"
hr
