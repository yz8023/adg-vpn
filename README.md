# adg-vpn
广告和代理共存模块

## 当前版本 (20261005)

| 文件 | 说明 |
|------|------|
| `AdGuard.Home.For.Android.20261005.zip` | AGH 模块：Google 放行规则 + Google 域名族走 8.8.8.8 DoH + restart.sh |
| `box_1.2.11.20261005.zip` | Box 模块：Google 分流组 + tun 栈 system（高速） |
| `纠正ad配置.sh` | AGH user_rules 修复/注入脚本 |
| `restart.sh`(模块内) | 修改 yaml 后手动重启生效 |
| `诊断*.sh` | 链路分层诊断脚本 |
| `优化网速*.sh` | 一键提速(gvisor→system)与多目标测速 |

### 20261005 更新（实测有效）

1. **AGH**：upstream_dns 顶部新增 per-domain 上游，`googleapis.com/gvt1.com/google.com/gstatic.com/googleusercontent.com/ggpht.com/googlevideo.com` 全部改走 `https://8.8.8.8/dns-query`——绕开国内 DoH 被 GFW 污染的缓存（`update.googleapis.com` 被污染成联通 IP 是 Play 下载失败的根因）
2. **box**：tun 栈 `gvisor → system`——gvisor 用户态协议栈是手机端吞吐瓶颈，实测换 system 后下载速度恢复正常
3. 注意：system 栈不兼容的设备可改回 `stack: gvisor`；机场普遍封锁 speed.cloudflare.com 测速端点，测速请用 fast.com

### 20261004 更新

1. **AGH 内置 Google 放行规则**：AdGuardHome.yaml 的 user_rules 顶部注入 8 条
   `$important` 白名单（`googleapis.com`、`android.clients.google.com`、
   `accounts.google.com`、`accounts.gstatic.com`、`ssl.gstatic.com`、
   `www.gstatic.com`、`connectivitycheck.gstatic.com`、`gvt1.com`），
   解决 Play 商店能浏览不能下载、网页 Google 登录弹窗不出现的问题
2. **AGH 新增 `scripts/restart.sh`**：修改 yaml 后手动生效，免重启手机
3. **box mihomo 配置新增 Google 分流**：`Google_域` 规则集（geosite google，
   含 googleapis/gstatic/gvt1/googlevideo 等）+ `Google` 策略组，
   与 Discord 分流同结构，可在面板中为 Google 流量单独选节点

### 修改 yaml 后手动生效（免重启手机）

```bash
# 应用 AGH 过滤规则修改（杀进程后由守护循环自动拉起）
sh /data/adb/agh/scripts/restart.sh

# 应用 mihomo 分流配置修改（重启前先做配置检测，检测不过可加 force 强制）
sh /data/adb/agh/scripts/restart.sh box

# 两者都重启
sh /data/adb/agh/scripts/restart.sh all
```

### 升级注意

- AGH 模块升级会替换 `bin/AdGuardHome.yaml`（安装脚本已自动备份到
  `/data/adb/agh/backup/`），自定义 user_rules 需手动合并
- box 模块升级会保留手机上现有的 `mihomo/config.yaml`，需手动把
  `Google_域` 规则集、`Google` 策略组、`RULE-SET,Google_域,Google` 三段
  合并进现有配置，或删除现有配置后重启让新版模板生效
