#!/system/bin/sh
# ============================================================
#  adg-vpn 三轮定向诊断 - Google 域名拦截真凶 + mihomo 节点健康
#  运行: su -c "sh 诊断3.sh"
# ============================================================
AGH_DIR="/data/adb/agh"
BOX_DIR="/data/adb/box"
CFG="$BOX_DIR/mihomo/config.yaml"
hr() { echo ""; echo "=================================================="; }
BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=/data/adb/magisk/busybox

hr; echo "[A] AGH 对 Google 域名的实际解析结果"
port=$(sed -n '/^dns:/,/^[^[:space:]]/s/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$AGH_DIR/bin/AdGuardHome.yaml" | head -n 1)
for d in accounts.google.com play.googleapis.com android.clients.google.com update.googleapis.com gvt1.com; do
    r=$("$BB" nslookup "$d" "127.0.0.1:$port" 2>&1 | awk '/^Address/{printf "%s ", $NF}')
    echo "  $d -> ${r:-无解析记录}"
done

hr; echo "[B] 查询日志中 Google 域名的拦截真凶 (最近 20 条, 看 Rules.Text 就是拦它的规则)"
grep -E '"QH":"[^"]*(google|gvt1|gstatic|googleapis)' "$AGH_DIR/bin/data/querylog.json" 2>/dev/null \
    | tail -n 20 \
    | sed 's/.*"QH":"\([^"]*\)".*"Rules":\[[^]]*"Text":"\([^"]*\)".*"IsFiltered":\([a-z]*\).*/  \1  拦截=\3  规则=\2/' \
    | tail -n 20
n=$(grep -cE '"QH":"[^"]*(google|gvt1|gstatic|googleapis)' "$AGH_DIR/bin/data/querylog.json" 2>/dev/null)
echo "  (日志中 Google 相关查询共 ${n:-0} 条)"

hr; echo "[C] 设备实际 mihomo 配置关键段"
echo "  -- 端口与控制器 --"
grep -nE "^(mixed-port|redir-port|tproxy-port|external-controller|secret):" "$CFG" | sed 's/^/  /'
echo "  -- DNS 模式 --"
grep -nE "enhanced-mode|fake-ip-range|listen:" "$CFG" | head -n 6 | sed 's/^/  /'
echo "  -- tun 开关 --"
sed -n '/^tun:/,/^[a-z]/p' "$CFG" | grep -E "enable|stack|device" | sed 's/^/  /'
echo "  -- sniffer --"
grep -n -A1 "^sniffer:" "$CFG" | sed 's/^/  /'
echo "  -- 规则条数与最后 5 条 --"
grep -cE "^  - " "$CFG" | sed 's/^/  规则相关行数: /'
grep -E "^  - (RULE-SET|MATCH|DOMAIN|IP-CIDR|DST-PORT|GEOIP)" "$CFG" | tail -n 5 | sed 's/^/  /'

hr; echo "[D] mihomo API 状态 (config + 策略组当前节点与延迟)"
SECRET=$(grep -E "^secret:" "$CFG" | sed 's/secret:[[:space:]]*["]*\([^"]*\)["]*/\1/' | tr -d ' ')
ctrl=$(grep -E "^external-controller:" "$CFG" | sed 's/external-controller:[[:space:]]*//;s/"//g' | tr -d ' ')
[ -n "$ctrl" ] || ctrl="127.0.0.1:9090"
AUTH=""; [ -n "$SECRET" ] && AUTH="Authorization: Bearer $SECRET"
echo "  控制器: $ctrl"
echo "  -- 运行模式 --"
curl -s -m 5 -H "$AUTH" "http://$ctrl/configs" 2>/dev/null \
    | tr ',' '\n' | grep -E '"mode"|"tun"|"enable"' | head -n 6 | sed 's/^/  /'
[ -z "$(curl -s -m 5 -H "$AUTH" "http://$ctrl/configs")" ] && echo "  !! API 无响应(可能端口/密钥不同)"
echo "  -- 策略组与节点延迟 --"
curl -s -m 5 -H "$AUTH" "http://$ctrl/proxies" 2>/dev/null \
    | tr '{' '\n' \
    | grep -E '国外代理|国内直连|漏网之鱼|自动选择' \
    | tr ',' '\n' | grep -E '"name"|"now"|"alive"|"delay"' | head -n 40 | sed 's/^/  /'

hr; echo "[E] 代理路径实测"
mp=$(grep -E "^mixed-port:" "$CFG" | grep -o "[0-9]*")
[ -n "$mp" ] || mp=7890
echo "  mixed-port: $mp"
code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -x "http://127.0.0.1:$mp" "https://cp.cloudflare.com/generate_204" 2>/dev/null)
echo "  经代理 -> cloudflare 204测试 : HTTP ${code:-000}"
code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 -x "http://127.0.0.1:$mp" "https://accounts.google.com" 2>/dev/null)
echo "  经代理 -> accounts.google.com: HTTP ${code:-000}"

hr; echo "[F] tproxy/路由标记 (mihomo 接管流量的方式)"
iptables -t mangle -S PREROUTING 2>/dev/null | head -n 12 | sed 's/^/  /'
ip rule 2>/dev/null | head -n 8 | sed 's/^/  /'

hr; echo "三轮诊断完成，请把全部输出发回"
