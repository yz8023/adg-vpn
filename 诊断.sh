#!/system/bin/sh
# ============================================================
#  adg-vpn 一键诊断脚本
#  在手机上以 root 运行:  su -c "sh 诊断.sh"
#  把全部输出发回来即可定位断在哪一层
# ============================================================
AGH_DIR="/data/adb/agh"
BOX_DIR="/data/adb/box"

hr() { echo ""; echo "=================================================="; }

hr; echo "[1] 进程状态"
for name in AdGuardHome mihomo sing-box xray v2fly hysteria; do
    if pidof "$name" > /dev/null 2>&1; then
        echo "[运行中] $name (pid $(pidof "$name"))"
    else
        echo "[未运行] $name"
    fi
done

hr; echo "[2] AGH 端口一致性"
YAML="$AGH_DIR/bin/AdGuardHome.yaml"
yaml_port=$(sed -n '/^dns:/,/^[^[:space:]]/s/^[[:space:]]*port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$YAML" | head -n 1)
prop_port=$(sed -n 's/^redir_port=\([0-9][0-9]*\).*/\1/p' "$AGH_DIR/scripts/config.prop")
echo "  AGH yaml dns 端口      : ${yaml_port:-读取失败}"
echo "  config.prop redir_port : ${prop_port:-读取失败}"
[ -n "$yaml_port" ] && [ "$yaml_port" = "$prop_port" ] && echo "  结论: 一致" || echo "  结论: !! 不一致，DNS 劫持会失效"

if [ -f "$BOX_DIR/mihomo/config.yaml" ]; then
    mihomo_ports=$(grep -o "127\.0\.0\.1:[0-9]*" "$BOX_DIR/mihomo/config.yaml" | sort | uniq -c | tr '\n' ' ')
    echo "  mihomo 配置内 127.0.0.1:端口 出现情况: ${mihomo_ports:-无}"
    case "$mihomo_ports" in
        *":$yaml_port"*) echo "  结论: mihomo DNS 上游已指向 AGH" ;;
        *)               echo "  结论: !! mihomo DNS 上游未指向 AGH 端口 $yaml_port" ;;
    esac
else
    echo "  !! 未找到 $BOX_DIR/mihomo/config.yaml"
fi

hr; echo "[3] iptables DNS 劫持规则"
if iptables -t nat -S ADGUARD 2>/dev/null | grep -q .; then
    iptables -t nat -S ADGUARD 2>/dev/null | sed 's/^/  /'
else
    echo "  !! ADGUARD 链不存在 (AGH 的 iptables.sh 未生效)"
fi

hr; echo "[4] AGH Google 放行规则"
echo "  白名单(@@)规则条数: $(grep -c '^  - .@@||' "$YAML" 2>/dev/null)"
grep -q "Google-放行" "$YAML" && echo "  已包含本次发布的 Google 放行段" || echo "  !! 未包含 Google 放行段 (还是旧 yaml)"

hr; echo "[5] DNS 解析测试 (0.0.0.0=被拦截, 空=解析失败)"
for srv in "127.0.0.1:${yaml_port:-53}|AGH直查" "127.0.0.1|系统53劫持路径"; do
    server="${srv%%|*}"; label="${srv##*|}"
    echo "  -- 经 $label ($server) --"
    for d in accounts.google.com play.googleapis.com gvt1.com www.baidu.com; do
        r=$(nslookup "$d" "$server" 2>/dev/null \
            | awk '/^Address/ && $NF !~ /^127\.0\.0\.1/ {printf "%s ", $NF}')
        case "$r" in
            *0.0.0.0*) echo "    $d -> 被拦截" ;;
            "")        echo "    $d -> 解析失败" ;;
            *)         echo "    $d -> $r" ;;
        esac
    done
done

hr; echo "[6] mihomo 错误日志(最近 15 条)"
if [ -f "$BOX_DIR/run/mihomo.log" ]; then
    n=$(grep -icE "error|fail|fatal|panic" "$BOX_DIR/run/mihomo.log" 2>/dev/null)
    if [ "${n:-0}" -gt 0 ]; then
        grep -iE "error|fail|fatal|panic" "$BOX_DIR/run/mihomo.log" | tail -n 15 | sed 's/^/  /'
    else
        echo "  无错误记录"
    fi
else
    echo "  无 mihomo 日志文件"
fi

hr; echo "[7] 代理连通性测试(设备有 curl 才执行)"
if command -v curl > /dev/null 2>&1; then
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "https://www.google.com/generate_204" 2>/dev/null)
    echo "  直连 google generate_204  : HTTP ${code:-超时}"
    code2=$(curl -s -o /dev/null -w "%{http_code}" -m 8 -x "http://127.0.0.1:7890" "https://www.google.com/generate_204" 2>/dev/null)
    echo "  经 mihomo 7890 端口代理   : HTTP ${code2:-超时}"
else
    echo "  设备无 curl，跳过"
fi

hr; echo "诊断完成，请把以上全部输出发回"
