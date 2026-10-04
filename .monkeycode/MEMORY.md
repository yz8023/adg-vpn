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
