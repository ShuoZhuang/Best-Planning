# 最初需求 ↔ 代码现状 逐条核对（2026-10-04）

**缘起**：用户在写需求文档与技术设计**之前**提出过一段原始要求（大学生个人待办、自动排程、双层规则、
调整预览等）。本文件把那段原文的 **15 条**要点逐条与代码核对，给出判定与**可执行证据**。

**方法**：每条都落到**代码位置**（文件名:行号）或**可当场重跑的用例名**；对"结构就绪"与"需求兑现"
容易混淆的项（⑥ 远期截止、⑩ 生活配额）**专门查了它是否真接在引擎的生产路径上**，而不是只看有没有
这个类。**不采信"有文件就算实现"。**

**判定口径**：`已实现` = 需求能被用户实际用出来且有证据；`部分实现` = 一部分可用、另一部分未覆盖；
`后续` = **需求文档自己**把它划到了首版之外（规格 §17「后续路线」）。

| # | 需求要点 | 判定 | 可执行证据 |
| --- | --- | --- | --- |
| ① | 按待办 + 预计时长**自动规划** | 已实现 | `lib/scheduling/schedule_engine.dart`（约束求解）＋ `PlanningService.createProposal`；任务侧 `PlannerTask.estimatedMinutes`／`remainingMinutes`；§18 第 1、2 项证据见 `docs/testing/spec-18-acceptance.md` |
| ② | 突发情况可**重算调整** | 已实现 | `lib/application/replanning_coordinator.dart`（生产构造点，提交 `54ebe36`）＋ 领域变化七类 ＋ 调整预览；用例 `test/application/replan_events_test.dart` |
| ③ | 首版 **Windows EXE**；后续手机 APP | 已实现（首版）／**后续**（手机） | 本机实测 `android/`、`ios/`、`macos/`、`linux/`、`web/` **均不存在**（Windows-only）；`pubspec.yaml` 的 `platforms` 只有 windows；手机 App 见规格 **§17 后续路线** |
| ④ | **本地优先**、数据只存本机；后续账号与云同步 | 已实现（本地优先）／**后续**（云端） | 数据库取自 `getApplicationDocumentsDirectory()`＋`personal_planner.sqlite`（`lib/app/backup_assembly.dart:46-48`）；全库**无**账号／登录／上传／云同步代码；**架构门禁** `test/architecture/no_network_test.dart`（含变异验证）；云端见规格 **§17** |
| ⑤ | 固定日程（课程／会议／值班）**按周重复**，排程绕开已占用时间 | 已实现 | `lib/domain/services/recurrence_expander.dart`（数据层有重复规则列）＋ 展开后进入 `fixedIntervals`；提交 `a5231d9` |
| ⑥ | 滚动规划未来 7 天，**同时检查更远截止日期** | 已实现 | `lib/scheduling/pressure_calculator.dart:78`（`PressureCalculator`）**由引擎持有并调用**：`schedule_engine.dart:47`（字段）、`:278`（`calculate(...).targetMinutes`）；解释文案 `explanations.dart:8`（`deadline_and_progress` → 「截止压力与推进进度」） |
| ⑦ | 长任务可**拆分**／可设**必须连续完成** | 已实现 | `lib/domain/models/task.dart:8` `enum TaskSplitMode { splittable, continuous }`；引擎三处消费：`schedule_engine.dart:109`（剩余不足最小块）、`:302`（可放最小值）、`:478`／`:540`（连续模式） |
| ⑧ | 睡眠／用餐／固定休息／**每日任务上限**为**不可侵占的硬约束** | 已实现 | 可用性：`availability_builder.dart:12-19`（`fixedIntervals`／`protectedIntervals`／`chargedMovableBlocks` 都作为"不可用"输入）、`schedule_engine.dart:56-64`；校验：`plan_validator.dart:62`（固定日程）、`:73`（保护时间）、`:177`（超出上限 → `dailyLimitExceeded`，中文「超过每日任务上限」） |
| ⑨ | 临时聚会＝新增固定日程并**触发重排**；生活任务可填**预计时长与期望时间** | 已实现 | 固定日程变化进入协调器（`fixedEventCreated`／`fixedEventChanged`）；任务侧 `estimatedMinutes`、`dueAtUtc`、以及**期望时段** `preferredWindow`（`lib/domain/models/task.dart:58,101`，任务详情页有入口） |
| ⑩ | **双层规则**：先保障每周最低生活娱乐时长；娱乐事项仍有自己的优先级／时长／期望日期并参与排程 | 已实现（口径＝**评分因子**） | 配额可配：`planning_rules.dart:56,69`、默认 360 分钟（`default_settings.dart:39`）、引导页可改（`onboarding_page.dart:126`）；**调度侧真正使用**：`candidate_scorer.dart:141-150`（`ScoringFactor.lifeQuota`，按缺口给分，上限 `maximumLifeQuota`）＋ `schedule_engine.dart:346,357`（算出 `plannedLifeMinutes` 并传目标）＋ `explanations.dart:9`（「生活娱乐配额不足」）；统计侧另有 `analytics_service.dart:126` |
| ⑪ | 一天中的**高／中／低精力区间**＋任务**脑力强度** | 已实现 | 规则侧 `settings_service.dart:67`（校验）、`planning_rule_resolver.dart:26`、进输入哈希 `input_snapshot_builder.dart:82`；任务侧 `TaskEnergyLevel`；评分侧 `ScoringFactor.energyMatch` |
| ⑫ | 先出「**调整预览**」（谁被移动、为何移动）再确认；提供「**信任自动调整**」开关 | 已实现 | 预览页展示差异与解释（`explanations.dart` 的因子→中文）；开关 `trustAutoAdjust`＋`AutoAdjustStore`（提交 `0d72f61`）；§18 有对应项 |
| ⑬ | **约束规则＋评分优化**：先硬约束，再按优先级／精力匹配／生活配额／切换成本算分；可解释、离线可用 | 已实现 | `candidate_scorer.dart` 的 **10 个** `ScoringFactor`：`deadlineRisk`／`priority`／`progressPressure`／`energyMatch`／`preferredTime`／`lifeQuota`／`sameTaskContinuity`／`categorySwitch`／`fragmentation`／`movingExistingBlock`（覆盖你说的优先级、精力匹配、生活配额、切换成本）；可解释＝`explanations.dart`；离线＝纯 Dart 计算，另有 `test/architecture/no_network_test.dart` 门禁 |
| ⑭ | 记录**计划时长与实际时长**，支持**计时器**与**手动修正** | 已实现 | 计划＝`ConfirmedPlan.blocks`；实际＝`FocusService` 计时（`FocusSession.activeMinutes`）；手动修正＝`TaskCorrectionLog`／`task_corrections` 表（`main.dart:433`、`task_service.dart:57`）＋ 任务详情页入口 |
| ⑮ | 统计范围可选**今天／本周／本月／自定义**，并为**学期维度预留空间** | 部分实现 | 四个范围**都在**：按钮 `analytics_page.dart:390-392`（今天／本周／本月），自定义走 `showDateRangePicker`（`:158`、`:169`）；用例 `analytics_page_test.dart:41` 对四个标签断言；**本机时区日界**见 `analytics_page.dart:17-19`（R11）。**学期维度**：规格 **§17 后续路线** 明确写着「学期目标、考试周和假期模板」——属首版之外；且域层的统计范围本就是**任意区间**，当下用「自定义范围」即可表达一个学期 |

## 结论

- **13 条已实现**（① ② ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ ⑪ ⑫ ⑬ ⑭ 及 ③/④ 的本地/首版部分）；
- **3 条属"需求文档已划到首版之外"**（③ 手机 App、④ 账号与云同步、⑮ 学期维度）：**规格 §17
  「后续路线」逐条列着**，因而是**范围决定**而不是实现缺口；
- **未发现"结构就绪但需求未兑现"的项**。两处最容易被这个标准抓到的地方**专门查过**：⑥ 的远期压力
  计算器**确实由引擎持有并调用**（不是只写了个类）、⑩ 的生活配额**确实进了评分**（不是只在统计页
  显示）。

## 怎么重跑这次核对

```powershell
cd G:\best-planing\.worktrees\native-implementation
# 1) 评分因子清单（应为 10 个）
Select-String -Path lib\scheduling\candidate_scorer.dart -Pattern "enum ScoringFactor" -Context 0,12
# 2) 远期压力是否接在引擎上（应看到字段与调用）
Select-String -Path lib\scheduling\schedule_engine.dart -Pattern "PressureCalculator"
# 3) 每日上限是不是硬约束（应看到 dailyLimitExceeded）
Select-String -Path lib\scheduling\plan_validator.dart -Pattern "dailyLimitExceeded"
# 4) 统计范围（应看到今天/本周/本月三按钮 + 自定义选择器）
Select-String -Path lib\features\analytics\analytics_page.dart -Pattern "今天|本周|本月|showDateRangePicker"
# 5) 规格把哪些划到了后续
Select-String -Path docs\superpowers\specs\2026-10-01-personal-intelligent-scheduling-design.md -Pattern "后续路线" -Context 0,8
```