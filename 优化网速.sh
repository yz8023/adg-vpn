#!/system/bin/sh
# ============================================================
#  一键网速优化脚本 - 不需要懂原理，跑完看结果
#  自动: 测速(改前) -> 备份 -> tun栈 gvisor 换 system -> 重启 -> 测速(改后)
#  启动失败会自动回滚备份，放心跑
#  运行: su -c "sh 优化网速.sh"
# ============================================================
BOX_DIR="/data/adb/box"
CFG="$BOX_DIR/mihomo/config.yaml"
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
hr() { echo ""; echo "=================================================="; }

[ -f "$CFG" ] || { echo "未找到 $CFG"; exit 1; }
command -v curl > /dev/null 2>&1 || { echo "设备无 curl，无法测速"; exit 1; }

mp=$(grep -E "^mixed-port:" "$CFG" | grep -o "[0-9]*")
[ -n "$mp" ] || mp=7890

speed_test() {
    echo "  测速中(约 20 秒，手机别锁屏)..."
    r=$(curl -x "http://127.0.0.1:$mp" -o /dev/null -s \
        -w "%{speed_download}" -m 20 \
        "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)
    case "$r" in ""|0) echo "  测速失败(代理没通?)";; *) "$BB" awk -v s="$r" 'BEGIN{printf "  下载速度: %.1f Mbps\n", s*8/1000000}';; esac
}

hr; echo "[1] 改造前测速(gvisor 栈，当前状态)"
speed_test

cur=$(sed -n '/^tun:/,/^[a-z]/s/.*stack:[[:space:]]*//p' "$CFG" | head -n 1 | tr -d ' ')
echo ""
echo "  当前 tun 栈: ${cur:-未设置}"

if [ "$cur" = "system" ]; then
    echo "  已经是 system 栈，无需修改，直接看上面速度"
    hr; exit 0
fi

hr; echo "[2] 备份并切换栈"
BAK="$CFG.bak.$(date +%m%d%H%M)"
cp -f "$CFG" "$BAK" && echo "  已备份到: $BAK"
sed -i '/^tun:/,/^[a-z]/s/stack:[[:space:]]*[a-z]*/stack: system/' "$CFG"
echo "  配置已改为: stack: system"

if [ -x "$BOX_DIR/bin/mihomo" ]; then
    if ! timeout 15 "$BOX_DIR/bin/mihomo" -t -d "$BOX_DIR/mihomo" -f "$CFG" > /dev/null 2>&1; then
        echo "  !! 配置检测未通过，已还原，什么都没动"
        cp -f "$BAK" "$CFG"
        exit 1
    fi
fi

hr; echo "[3] 重启 mihomo"
"$BOX_DIR/scripts/box.service" restart
sleep 4
if ! pidof mihomo > /dev/null 2>&1; then
    echo "  !! 启动失败，自动回滚原配置..."
    cp -f "$BAK" "$CFG"
    "$BOX_DIR/scripts/box.service" restart
    sleep 4
    pidof mihomo > /dev/null 2>&1 && echo "  已回滚，代理恢复原样" || echo "  回滚后仍未运行，请重启手机"
    exit 1
fi
echo "  mihomo 重启成功(system 栈已生效)"

hr; echo "[4] 改造后测速(system 栈)"
speed_test

hr
echo "完成。把[1]和[4]两个速度数字发回来对比。"
echo "如果[4]比[1]明显快: 收工。"
echo "如果差不多: 瓶颈在机场节点，需要换节点测试，告诉我数字即可。"
hr
