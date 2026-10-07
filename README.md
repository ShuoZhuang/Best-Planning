# 智能日程（personal_planner）

本地优先的个人智能日程规划工具。把任务、固定日程、保护时间（睡眠／用餐／固定休息）与精力区间
放在一起，滚动生成**未来七天**的计划；排不下时**如实报告**逾期风险、所缺时间和冲突来源，
而不是伪造一份看起来可行的计划。

Windows 桌面应用（Flutter + Drift/SQLite）。**首版本地优先**：没有账号、没有云同步、
**不上传任何数据**——最后这一条不是口号，而是由一条会失败的测试守着的，见
[`test/architecture/no_network_test.dart`](test/architecture/no_network_test.dart)。

排程由确定性的约束+评分引擎完成（不由大模型直接决定日程）：相同输入、相同设置、相同引擎版本
产生可复现的结果。

---

## 快速开始

### 环境前提

1. **Flutter SDK**：本机在 `G:\best-planing\.tooling\flutter-bundle\flutter\bin`。
2. **`flutter test` 之前必须重定向临时目录**，并把 SDK 加进 `PATH`：

   ```powershell
   New-Item -ItemType Directory -Force G:\best-planing\.flutter-tmp | Out-Null
   $env:TEMP = "G:\best-planing\.flutter-tmp"
   $env:TMP  = "G:\best-planing\.flutter-tmp"
   $env:Path = "G:\best-planing\.tooling\flutter-bundle\flutter\bin;" + $env:Path
   ```

   不做这一步会得到极具误导性的两行（`null. The flutter tool cannot access the file or
   directory.` ＋ 提示 SDK 或项目缺权限），真正原因与项目无关。

3. **开发人员模式**（Windows 构建插件需要符号链接支持）。**在确认它已开启之前不要跑
   `flutter clean`**——clean 会删掉 `windows/flutter/ephemeral`，权限不足时重建不出来。

其余本机特有的坑（遥测会让 `flutter analyze` 与 `flutter test` 一起失败、派生进程建不了符号
链接等）与处置办法逐条记在技术设计 §13.0.9，**遇到"莫名其妙全线失败"先看那一节**。

### 常用命令

```powershell
flutter analyze                 # 静态分析（每次改动后先看它）
flutter test                    # 全部单元与 widget 测试
flutter run -d windows          # 本机运行

# 端到端流程：**逐条单独跑**。批量一次跑会在第 2 条起于 loading 阶段报
# "Error waiting for a debug connection"——那是测试装置与应用连接的偶发问题，不在断言上。
flutter test integration_test/first_plan_flow_test.dart -d windows
flutter test integration_test/emergency_replan_flow_test.dart -d windows
flutter test integration_test/backup_restore_flow_test.dart -d windows
```

### 打包与安装（MSIX）

发布必须用 MSIX：可靠的通知取消与查询能力依赖 Windows **包身份**，只有 release EXE 时
通知行为不可靠。

从 `1.4.1+21` 起，每个交给用户体验的版本必须同时提供便携目录、ZIP、已签名 MSIX、签名公钥
证书和使用说明，不能再只导出 EXE。

```powershell
dart run msix:create
```

签名配置在 `pubspec.yaml` 的 `msix_config` 段。**两处容易踩的坑**（都已实测并记在发布文档里）：
包内自带的测试证书是 X.509 v1、无扩展，会被 signtool 拒绝；而自己签的证书用
`/f <pfx> /p <密码>` 也会失败（旧 signtool 导不进新代 CNG 私钥），因此这里改用
**按指纹从证书库选取**。私钥与公钥都放在**仓库之外**，所以密码不出现在任何文件或命令里。

完整流程、签名机制、安装与卸载命令见
[`docs/release/windows-release.md`](docs/release/windows-release.md)。

---

## 文档地图

需求是**唯一权威**；实现与需求冲突时改实现，不改文档。

| 文档 | 内容 |
| --- | --- |
| [`docs/superpowers/specs/…-design.md`](docs/superpowers/specs/2026-10-01-personal-intelligent-scheduling-design.md) | **需求规格**：功能需求 FR-*、排程策略、隐私、§18 首版验收清单 |
| [`docs/superpowers/plans/…technical-design.md`](docs/superpowers/plans/2026-10-01-personal-intelligent-scheduler-technical-design.md) | **技术设计与实施登记**：每个任务的验收标准，以及 §13.0「实施状态与偏差登记」——**开工前先读 §13.0** |
| [`docs/testing/spec-18-acceptance.md`](docs/testing/spec-18-acceptance.md) | **§18 逐项证据记录**：每项给出可当场重跑的"文件路径 :: 用例名" |
| [`docs/testing/manual-windows-checklist.md`](docs/testing/manual-windows-checklist.md) | 手工验收清单（**尚未执行**） |
| [`docs/release/windows-release.md`](docs/release/windows-release.md) | Windows 发布流程、签名与安装 |

**约定**：文档里区分四级——**结构就绪 / 有服务入口 / 界面可用 / 需求兑现**，四者不可互相
替代。"代码写了"不等于"用户能用"，也不等于"需求兑现"；**声称未验证的东西是明确的错误**。

---

## 目录结构

```
lib/
  app/             组合根装配（main 的依赖装配、路由、外壳）
  application/     应用服务：任务、日历、排程、专注、统计、偏好、备份/导出/清除
  domain/          领域模型与仓库接口（不依赖 Flutter）
  data/            Drift 数据库、DAO、仓库实现、迁移
  scheduling/      排程引擎：可用时间、候选生成、评分、校验、差异、压力
  features/        界面（今日、任务、日历、统计、设置、专注、规划预览…）
  platform/        平台适配：Windows 通知、应用锁、文件选择、SQLite 生命周期
drift_schemas/     schema 快照（每次 schemaVersion 变化都要重新导出）
integration_test/  三条端到端流程；**逐条单独跑**
tool/              核对脚本（如包身份核对）
```

---

## 已知限制与未验证项（不因发布而淡化）

- **手工验收清单尚未执行**：需求 §18 的 19 项已用自动化证据勾选 18 项；唯一未勾选的是
  「普通任务可在一分钟内完成快速录入」——"一分钟内"是**操作耗时**主张，自动化证明不了，
  需要人工计时（清单 `2.1`／`2.2`）。
- **通知点击的真实 toast 交互未验证**：它需要人真的点一下通知。
- **`hasPackageIdentity` 的两个分支都已用真实 kernel32 调用验证**（非打包 → false；
  本包内 → true，见 [`tool/verify-package-identity.ps1`](tool/verify-package-identity.ps1)）；
  但"读应用自己的返回值"需要在应用内加日志才能做到。
- **`interruption:`（中断按原因分类）的口径是"默认选定"而非需求推导**：原规格没有定义
  "中断"是什么。口径写在规格 §8.9，**待产品确认**。
- **两处刻意的设计取舍**：`FocusService.pause` 让界面**先问中断原因、再暂停**，因此暂停时刻
  晚一次对话交互；`FocusEvidenceRecorder` 对"特殊日"的判定只覆盖**存在按日例外**的日子
  （"特殊日"页声明的晚归等**没有持久化成按日事实**，因此还进不了那个信号）。

上述每一条在技术设计 §13.0 里都有编号与提交号——**不要只信本文件**。
