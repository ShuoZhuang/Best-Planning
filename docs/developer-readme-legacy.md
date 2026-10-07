# 智能日程开发者说明（历史 README）

本地优先的个人智能日程规划工具。把任务、固定日程、保护时间（睡眠／用餐／固定休息）与精力区间
放在一起，滚动生成**未来七天**的计划；排不下时**如实报告**逾期风险、所缺时间和冲突来源，
而不是伪造一份看起来可行的计划。

Windows 桌面应用（Flutter + Drift/SQLite）。**首版本地优先**：没有账号、没有云同步、
**不上传任何数据**——最后这一条不是口号，而是由一条会失败的测试守着的，见
[`test/architecture/no_network_test.dart`](test/architecture/no_network_test.dart)。

排程由确定性的约束+评分引擎完成（不由大模型直接决定日程）：相同输入、相同设置、相同引擎版本
产生可复现的结果。

---

### 源码构建与测试

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

面向大学生的本地优先智能日程软件。把课程、学业任务、科研、竞赛、学生工作、社交聚会和个人娱乐放在一起，由程序根据预计时长、截止时间、精力和个人安排偏好生成未来 7 天计划；临时加班、晚归、聚会或其他突发变化发生后，可以重新计算剩余安排。

## 下载

普通用户不需要安装 Flutter、Dart 或其他开发环境，直接从 GitHub Releases 下载并安装即可：

- [下载版本（GitHub Releases）](https://github.com/ShuoZhuang/Best-Planning/releases)
- [查看全部版本](https://github.com/ShuoZhuang/Best-Planning/releases)

每个正式版本的 Releases 页面会提供 Windows 安装包和便携版：

| 文件 | 适用场景 |
| --- | --- |
| `.msix` | 推荐方式，安装后可以从开始菜单启动，并支持后续版本覆盖更新 |
| `.zip` | 便携版，解压后直接运行，不修改系统安装信息 |
| 安装说明 | Windows 安全提示、证书和升级步骤 |

如果 Windows 显示“无法验证发布者”或阻止安装，请先阅读该版本 Release 中附带的安装说明。不要从源码页面寻找 EXE；可执行文件统一放在 Releases 附件中。

## 软件功能

- 自动安排未来 7 天日程，并检查更远的截止日期。
- 区分固定日程、保护时间、可移动任务和生活安排。
- 根据领域、项目、预计时长、截止时间、精力要求和可拆分方式安排任务。
- 突发事件发生后重新规划剩余时间，并支持先预览调整结果再确认。
- 支持“信任自动调整”开关，决定是否允许系统直接应用重排结果。
- 支持从课表图片识别课程，确认学期周数、第一周日期、节次和课程时间后导入。
- 今日时间线、七日历和单日详情使用统一的领域颜色。
- 统计指定时间范围内的学业、科研、竞赛、工作、生活、保护时间和无领域任务。
- 提供无玻璃、克制玻璃、激进玻璃和极致液体玻璃外观模式。
- 本地优先保存任务、计划、课表、设置和统计数据，并支持备份与导出。

## 界面预览

![今日安排](assets/tutorial/01-today.png)

![任务管理](assets/tutorial/02-tasks.png)

![领域与项目](assets/tutorial/03-areas.png)

![七日历](assets/tutorial/04-calendar.png)

![时间统计](assets/tutorial/05-analytics.png)

![设置](assets/tutorial/06-settings.png)

## 第一次使用

1. 从 [Releases](https://github.com/ShuoZhuang/Best-Planning/releases) 下载最新 `.msix` 或 `.zip`。
2. 按 Release 中的安装说明完成安装；便携版解压后直接运行程序。
3. 在“设置”中确认作息、精力区间、保护时间、每日任务上限和生活时间预算。
4. 在“领域”中设置学业、科研、竞赛、工作和生活等领域的颜色；需要时再建立项目。
5. 通过“新建任务”录入任务的预计时长、截止时间、精力要求和是否允许拆分。
6. 在“日历”中导入课表，确认识别结果后生成固定课程安排。
7. 回到“今日”点击“生成计划”，检查安排并确认。

## 数据与隐私

软件默认在本机保存数据，不要求登录，也不会默认把任务、课表或统计上传到服务器。建议定期在“设置”中导出 JSON 备份。更换电脑前先导出备份，安装新版本后再恢复。

安装包、便携版和源码仓库不包含个人任务数据库。请不要把个人数据库、真实课表截图、备份文件、签名私钥或其他个人数据上传到 GitHub。

## 更新方式

- `.msix`：下载新版本后直接安装，Windows 会将其识别为同一应用并覆盖更新；安装前建议先导出备份。
- `.zip`：下载新版本并解压到新的目录，再运行其中的程序；继续使用原来的本地数据位置。

版本号遵循仓库中的 [版本号规则](版本号规则.md)。每个可供用户体验的版本都应在 Releases 中提供安装包，并在 Release 说明中记录版本号、变更内容、已知问题和校验值。

## 获取帮助

遇到安装、启动或计划问题时，请在提交 Issue 前附上软件版本、安装方式、Windows 版本、复现步骤和脱敏后的错误信息。

不要上传任务数据库、备份文件、证书私钥或包含个人信息的课表图片。

---

## 开发者文档

下面的内容面向需要修改源码、运行测试或自行构建安装包的开发者。普通用户不需要配置 Flutter 环境。
