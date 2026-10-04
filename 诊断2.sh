#!/system/bin/sh
# ============================================================
#  adg-vpn 二轮定向诊断 - 针对 "AGH 解析全失败"
#  运行: su -c "sh 诊断2.sh"
# ============================================================
AGH_DIR="/data/adb/agh"
BOX_DIR="/data/adb/box"
hr() { echo ""; echo "=================================================="; }

BB=$(command -v busybox 2>/dev/null)
[ -x "$BB" ] || BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/data/adb/ksu/bin/busybox

hr; echo "[A] 系统时间 (时间错误会导致 AGH 上游证书校验全挂)"
date

hr; echo "[B] 系统 DNS 路径测试 (ping 走系统解析器, 排除 nslookup 语法干扰)"
ping -c1 -W3 www.baidu.com 2>&1 | head -2 | sed 's/^/  /'

hr; echo "[C] AGH 是否真的在监听 DNS 端口"
yaml_port=$(sed -n '/^dns:/,/^[^[:space:]]/s/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$AGH_DIR/bin/AdGuardHome.yaml" | head -n 1)
hex=$(printf "%04X" "$yaml_port" 2>/dev/null)
echo "  DNS 端口: $yaml_port (hex $hex)"
grep -i ":$hex" /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '{s=s"    state="$4" local="$2"\n"} END{printf "%s", s}' || echo "  !! /proc/net 中未找到监听"

hr; echo "[D] 多解析器交叉测试 www.baidu.com"
if [ -x "$BB" ]; then
    echo "$BB" | sed 's/^/  (busybox: /;s/$/)/'
    "$BB" nslookup www.baidu.com "127.0.0.1:$yaml_port" 2>&1 | tail -5 | sed 's/^/  [busybox->AGH直查] /'
else
    echo "  无 busybox，跳过"
fi
nslookup www.baidu.com 127.0.0.1 2>&1 | tail -5 | sed 's/^/  [nslookup->53劫持] /'
nslookup www.baidu.com 127.0.0.1:1053 2>&1 | tail -5 | sed 's/^/  [nslookup->mihomo DNS 1053] /'

hr; echo "[E] AGH 上游 DoH 直连可达性 (400/405=通, 000=不通)"
for u in 1.12.12.12 120.53.53.53; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://$u/dns-query" 2>/dev/null)
    echo "  https://$u/dns-query -> HTTP ${code:-000}"
done
code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://www.baidu.com" 2>/dev/null)
echo "  https://www.baidu.com      -> HTTP ${code:-000} (普通直连参考)"

hr; echo "[F] nat/mangle OUTPUT 规则顺序 (看 53 端口被谁接管)"
iptables -t nat -S OUTPUT 2>/dev/null | head -12 | sed 's/^/  nat /'
echo "  ---"
iptables -t mangle -S OUTPUT 2>/dev/null | head -12 | sed 's/^/  mangle /'

hr; echo "[G] AGH 查询日志尾部 (看 AGH 收没收到查询、回了什么)"
if [ -f "$AGH_DIR/bin/data/querylog.json" ]; then
    tail -c 2500 "$AGH_DIR/bin/data/querylog.json" 2>/dev/null | sed 's/^/  /'
else
    echo "  无 querylog.json，data 目录内容:"
    ls -la "$AGH_DIR/bin/data/" 2>/dev/null | sed 's/^/  /'
fi

hr; echo "[H] mihomo 日志尾部 40 行 (含启动与 DNS 信息)"
tail -n 40 "$BOX_DIR/run/mihomo.log" 2>/dev/null | sed 's/^/  /' || echo "  无日志"

hr; echo "二轮诊断完成，请把全部输出发回"
