# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### Project Knowledge Entry
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Build Methods]
- Instructions:
  - [Specific knowledge points]

## Entries

[链路排障经验 - AGH+box 共存架构]
- Date: 2026-10-05
- Context: Agent 排查"Play 下载失败/Google 登录弹窗不出现/网速跑不满"三天会话后确认
- Category: Troubleshooting & Debugging
- Instructions:
  - 排障工具链在仓库根目录：诊断.sh(分层) -> 诊断2.sh -> 诊断3.sh -> 优化网速*.sh，让用户在手机上 su -c "sh 脚本" 后贴回输出
  - MonkeyCode 手机 shell 没有 nslookup 命令，测 DNS 必须用 busybox nslookup(/data/adb/ksu/bin/busybox)，否则误判"解析失败"
  - 国内 DoH 上游(1.12.12.12/120.53.53.53)会被 GFW 污染 Google 域名缓存(update.googleapis.com 曾解析成联通 IP)，修复方法=AGH upstream_dns 加 per-domain 规则走 https://8.8.8.8/dns-query(经代理出站)；直连 53/853 在此架构中被 iptables 封锁，上游只能用 DoH
  - 手机端吞吐瓶颈常是 mihomo tun 的 gvisor 用户态栈，换 stack: system 实测恢复；机场普遍封锁 speed.cloudflare.com 测速端点(TLS 握手被断)，测速用 fast.com/cachefly/tele2
  - AGH 白名单 @@||域名^$important 可压过任何过滤列表拦截；用户可能直接在 Web UI 加规则，脚本检查 yaml 注释标记会误报"旧配置"，以 querylog 的 Rules.Text 为准
  - AGH 端口随机化在 service.sh 开机时执行，改 yaml 后手动重启进程不变端口；三方一致性检查点：yaml dns.port = config.prop redir_port = mihomo nameserver 端口

[模块打包发版流程]
- Date: 2026-10-04
- Context: Agent 执行模块重新打包发布任务时确认
- Category: Build Methods
- Instructions:
  - 本仓库发布两个 Magisk 模块 zip：AGH（AdGuard Home For Android）与 box
  - AGH zip：文件在 zip 根目录（无 META-INF），从解包目录 `zip -r -X` 打包 action.sh bin/ customize.sh module.prop scripts/ service.sh uninstall.sh；bin/AdGuardHome.yaml 可在打包前先用 纠正ad配置.sh 处理，刷入即生效
  - box zip：含 META-INF/com/google/android/，打包 META-INF README.md action.sh box/ box_service.sh customize.sh module.prop uninstall.sh webroot
  - 版本号约定：AGH 用日期（version=YYYYMMDD, versionCode=YYYYMMDD00），box 用 x.y.z(YYYYMMDD)；zip 文件名：AdGuard.Home.For.Android.YYYYMMDD.zip / box_x.y.z.YYYYMMDD.zip
  - 升级行为：AGH 的 customize.sh 会替换手机上的 bin/AdGuardHome.yaml（备份在 /data/adb/agh/backup/）；box 升级会保留用户现有 mihomo/config.yaml，配置变更需用户手动合并
  - AGH 模块内脚本安装后被 chattr +i 锁定，修改前需 chattr -i；脚本运行时 style 为 /system/bin/sh（mksh），避免 bashism
