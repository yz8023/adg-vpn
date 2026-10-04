#!/system/bin/sh
# ============================================================
#  AdGuard Home user_rules 修复脚本
#  读取原配置 → 输出到当前目录，不修改原文件
#
#  用法:
#     sh fix_agh.sh
#     sh fix_agh.sh /data/adb/agh/bin/AdGuardHome.yaml ./my_fixed.yaml
# ============================================================

SRC="${1:-/data/adb/agh/bin/AdGuardHome.yaml}"
DST="${2:-./AdGuardHome.fixed.yaml}"

[ -f "$SRC" ] || { echo "错误: 找不到源文件 $SRC" >&2; exit 1; }

TMP="./.agh_fix_$$"
mkdir -p "$TMP" || { echo "无法创建临时目录" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------- 1. 提取 user_rules 段的所有规则 ----------
awk '
/^user_rules:[[:space:]]*$/ { f=1; next }
f && /^[a-zA-Z_]/         { f=0 }
f && /^  - / {
    body = substr($0, 5)
    if (substr(body,1,1) == "\047") body = substr(body, 2)
    if (substr(body,length(body),1) == "\047") body = substr(body, 1, length(body)-1)
    print body
}
' "$SRC" > "$TMP/rules.raw"

# ---------- 2. 找出「既拦截又放行」的域名 ----------
grep -E '^\|\|'   "$TMP/rules.raw" | sed 's/^||//'   | sed 's/\^.*//' | sed 's/\$.*//' | sort -u > "$TMP/blk_d"
grep -E '^@@\|\|' "$TMP/rules.raw" | sed 's/^@@||//' | sed 's/\^.*//' | sed 's/\$.*//' | sort -u > "$TMP/alw_d"

awk 'NR==FNR { a[$0]=1; next } $0 in a { print }' \
    "$TMP/blk_d" "$TMP/alw_d" > "$TMP/conflict_d"

# ---------- 3. 逐行修复并输出 ----------
awk -v cf="$TMP/conflict_d" '
BEGIN {
    Q = sprintf("%c", 39)                    # 单引号
    while ((getline line < cf) > 0) conflict[line] = 1
    close(cf)
    in_rules = 0
    # Google 下载/登录依赖域名，强制放行（$important 白名单可压过任何 $important 拦截）
    GOOGLE_ALLOW = "googleapis.com android.clients.google.com accounts.google.com accounts.gstatic.com ssl.gstatic.com www.gstatic.com connectivitycheck.gstatic.com gvt1.com"
}

/^user_rules:[[:space:]]*$/ {
    in_rules = 1
    print
    n = split(GOOGLE_ALLOW, ga, " ")
    for (gi = 1; gi <= n; gi++) {
        r = "@@||" ga[gi] "^$important"
        if (!(r in seen)) {
            seen[r] = 1
            print "  # [Google-放行] Play下载/账号登录依赖域名"
            print "  - " Q r Q
        }
    }
    next
}

/^user_rules:[[:space:]]*$/ { in_rules = 1; print; next }
in_rules && /^[a-zA-Z_]/    { in_rules = 0 }

in_rules && /^  - / {
    raw  = $0
    body = substr(raw, 5)
    if (substr(body,1,1) == Q) body = substr(body, 2)
    if (substr(body,length(body),1) == Q) body = substr(body, 1, length(body)-1)

    # 空行 / YAML 注释行
    if (body == "" || body ~ /^#/) { print raw; next }

    original = body

    # ---------- 语法修复 ----------
    sub(/\$importa$/,    "$important", body)   # $importa   -> $important
    sub(/\$importat$/,   "$important", body)   # $importat  -> $important
    gsub(/\$importantnt/,"$important", body)   # $importantnt -> $important
    sub(/\^important$/,  "^$important", body)  # ^important -> ^$important
    if (body ~ /^@@[^|]/) sub(/^@@/, "@@||", body)   # @@xxx -> @@||xxx

    syntax_fixed = (body != original)

    # ---------- Google Play 修复 ----------
    if (body == "||update.googleapis.com^$important") {
        print "  # [GooglePlay-Fix] 原拦截规则已注释，改为放行"
        print "  - " Q "@@||update.googleapis.com^$important" Q
        next
    }

    # ---------- 冲突: 注释掉拦截 ----------
    if (body ~ /^\|\|/) {
        d = body
        sub(/^\|\|/, "", d); sub(/\^.*/, "", d); sub(/\$.*/, "", d)
        if (d in conflict) {
            print "  # [冲突-同域名已放行] " body
            next
        }
    }

    # ---------- 去重 ----------
    if (body in seen) {
        print "  # [重复规则] " body
        next
    }
    seen[body] = 1

    # ---------- 输出 ----------
    if (syntax_fixed) {
        print "  # [语法已修复] " body
    } else {
        print "  - " Q body Q
    }
    next
}

{ print }
' "$SRC" > "$DST"

# ---------- 4. 汇总 ----------
echo "============================================"
echo " 修复完成"
echo "============================================"
echo " 源文件 (未改): $SRC"
echo " 新配置:        $DST"
echo ""
echo " 冲突域名总数:  $(wc -l < "$TMP/conflict_d" | tr -d ' ')"
echo " 语法修复条数:  $(grep -c '\[语法已修复\]' "$DST" 2>/dev/null || echo 0)"
echo " 冲突注释条数:  $(grep -c '\[冲突'       "$DST" 2>/dev/null || echo 0)"
echo " 重复注释条数:  $(grep -c '\[重复规则\]' "$DST" 2>/dev/null || echo 0)"
 echo " GooglePlay修复: $(grep -c '\[GooglePlay-Fix\]' "$DST" 2>/dev/null || echo 0)"
 echo " Google放行注入: $(grep -c '\[Google-放行\]' "$DST" 2>/dev/null || echo 0)"
echo ""
echo " 提示: 打开 $DST 用 grep 搜索关键词即可查看被改动的行。"