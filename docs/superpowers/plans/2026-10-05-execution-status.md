# 2026-10-05 三份计划执行状态报告

> **⚠️ 本文件是 2026-10-05 当晚的状态快照，已被后续进展取代，其中的结论多数已失效。**
> 具体失效项：「计划三 5/7」「任务 6–7 未开始」「现有 OCR 与导入后端从 UI 不可达」「构建为红
> （19 张表断言 + 2 条 analyzer info）」「131 文件全部未提交」——2026-10-06 已全部改变：任务 6–7
> 完成，654/654 测试通过、`flutter analyze` 无问题，两个缺陷已修，改动也已按主题提交（自
> `d9d100b` 起）。
> **当前状态请看提交历史，以及**
> [任务三台账](../../../.superpowers/sdd/2026-10-05-local-timetable-import/progress.md)、
> [提交分组与落库结果](2026-10-06-commit-grouping.md)。
> 保留本文件只为记录当时的判断依据——「后端从 UI 不可达」等结论在当时确实成立。

复核时间：2026-10-05 23:26（Asia/Shanghai）
复核对象：

- [任务分类与最早开始约束](2026-10-05-task-classification-and-start-constraint.md)
- [重复规则与学业日历](2026-10-05-recurrence-and-academic-calendar.md)
- [本地课表导入](2026-10-05-local-timetable-import.md)

复核方式：读取三份 SDD 台账、逐任务比对代码与测试是否存在、重跑 `flutter analyze --no-pub` 与全套 `flutter test --no-pub`，并对课表计划未记录的任务 4–5 单独重跑聚焦测试。

---

## 0. 一个必须先说清楚的前提：实现不在主仓库

主仓库 `G:\best-planing`（分支 `main`）只有 **1 个提交**（`8b2838e docs: define personal planner requirements and technical plan`），根目录没有 `lib/`——那里只有文档、工具链和发布产物。

三份计划对应的全部实现位于链接工作树：

| 项 | 值 |
| --- | --- |
| 工作树 | `G:\best-planing\.worktrees\native-implementation` |
| 分支 | `feature/native-implementation` |
| HEAD | `94f4bde docs: plan task areas recurrence and timetable import`（仍是「写计划」那个提交） |
| 未提交改动 | 131 个文件，+14660 / −5831 |
| 其中本主题相关 | `lib/data/database/**`、`lib/domain/**`、`lib/scheduling/**`、`lib/features/tasks/**`、`lib/application/**` 等 |

也就是说：**三份计划的代码一行都没有提交**，全部堆积在工作树的未提交状态里。台账对此有明确裁定——工作树中已存在用户自己的未提交改动，为免把无关改动一起提交，逐任务的产品提交被跳过。代价是回滚粒度变粗，但台账与测试证据仍按任务可追溯。

## 1. 结论速览

| 计划 | 任务数 | 状态 | 依据 |
| --- | --- | --- | --- |
| 任务分类与最早开始约束 | 7 | ✅ 全部完成并验证 | 台账 7/7；阶段验证 570 测试通过、analyze 干净 |
| 重复规则与学业日历 | 6 | ✅ 全部完成并验证 | 台账 6/6；阶段验证 609 测试通过、analyze 干净 |
| 本地课表导入 | 7 | 🔶 5/7，中断未完成 | 任务 1–5 代码落地；任务 6–7 未开始；**当前构建为红** |

当前全套测试实测：**639 通过、1 失败**。失败项为课表计划任务 1 引入的过期断言（见 §4）。

## 2. 计划一：任务分类与最早开始约束 —— ✅ 完成

台账逐任务记录（`.superpowers/sdd/2026-10-05-task-classification-and-start-constraint/progress.md`），代码侧已核对：

| 任务 | 内容 | 落地证据 |
| --- | --- | --- |
| 1 | schema v4 + `tasks.areaId` / `availableFromUtc` | `planner_tables.dart:47,54`；`task.dart:49,56,92,99`；`schemaVersion => 6` 链上含 `_upgradeToV4` |
| 2 | 五个默认领域 + 文案 | `workspace_service.dart:13-17`（学业/科研/竞赛/工作/生活，仅生活 `isLife: true`）；`workspace_management_page.dart:189,327`「计入个人生活时间」 |
| 3 | `TaskService` 领域/项目校验 | `task_service.dart:16,21,32,37`；UTC 校验 `198-201` |
| 4 | 领域优先的任务编辑器 | `task_editor_page.dart:422`（`task-area`）、`440`（`task-project`）、`480`（`task-available-from`）、`628`「新建该领域项目」 |
| 5 | 排程最早开始下界 | `schedule_problem.dart:16,29`；`candidate_generator.dart:40` 起用 `availableFromUtc`；台账记录 10:03 → 10:05 上取整 |
| 6 | 直接领域驱动的统计与生活配额 | `drift_life_area_lookup.dart:21` 直接 join `areas.id = tasks.areaId` |
| 7 | 深色主题与设置间距 | `task_detail_page.dart` 已无 `Colors.black*`；`settings_hub_page.dart` 显式 12px 间距 |

台账另记录一项超出计划的收尾：今日页 1280×600 时间轴溢出回归已修，Windows 集成测试三个流程单独运行均通过；整目录一次性运行会撞上 Flutter 的 Windows debug-log 重连问题（失败项从未进入应用断言）。

## 3. 计划二：重复规则与学业日历 —— ✅ 完成

台账记录 6/6 任务（`.superpowers/sdd/2026-10-05-recurrence-and-academic-calendar/progress.md`），代码侧已核对：

| 任务 | 内容 | 落地证据 |
| --- | --- | --- |
| 1 | schema v5：`interval_weeks` + 学业学期 + 作息模板 | `planner_tables.dart:103`（`intervalWeeks` 带约束）；`drift_schemas/app_database/` 含 v1–v6；`_upgradeToV5` 存在 |
| 2 | 按周间隔展开（本地周一锚点） | `calendar_event.dart:126,140`（1–52 校验）；`recurrence_expander.dart:111`（`weekOffset % intervalWeeks == 0`） |
| 3 | 学业日历领域服务与仓储 | `academic_calendar.dart`、`drift_academic_calendar_repository.dart`、`academic_calendar_service.dart` 均存在；台账 14 测试 |
| 4 | 草稿携带完整重复边界 | `calendar_service.dart:28,29,42,43`；`280-281` 起校验区间 |
| 5 | 「本次及以后」系列拆分 | `calendar_event_deletion.dart:84,96`；`day_view_page.dart:348,356,364` 暴露仅本次／本次及以后／整个系列 |
| 6 | 重复与学业日历设置 UI | `router.dart:38,97,479-481`（`settings-academic-calendar`）；`event_editor_form.dart:218-221`（每两周／单周／双周／自定义）；`academic_calendar_page.dart`、`period_template_editor.dart` 存在 |

台账记录的阶段验证：`flutter analyze --no-pub` 无问题；全套 609 测试通过；schema/迁移检查 v1–v5 共 17 测试通过；三个 Windows 集成流程单独通过。全跑期间发现的 schema 校验回归（区间与学期边界在「新建库」与「迁移」两条路径上表达方式不一致）已修复。

## 4. 计划三：本地课表导入 —— 🔶 5/7，中断

### 已完成

| 任务 | 内容 | 状态与证据 |
| --- | --- | --- |
| 1 | schema v6 + 导入批次持久化 | ✅ 台账已记；`planner_tables.dart:169`（`TimetableImportBatches`）、`202-207`（location/notes/sourceKind/importBatchId/logicalCourseId）；`calendar_event.dart:4-6`（`timetableImport`）；26 迁移/往返测试通过 |
| 2 | Windows 本地 OCR 适配器 | ✅ 台账已记；`lib/domain/ocr/timetable_ocr.dart:1,24`；`windows/runner/timetable_ocr_channel.cpp:96,154,177,179,196`（含 `MaxImageDimension`、`RecognizeAsync`、`TextAngle`）；9 契约/通道测试 + 真实 debug 构建通过 |
| 3 | OCR 几何 → 可编辑课程草稿 | ✅ 台账已记；`timetable_parser.dart:6,68,73,85`；两个合成 fixture；3 测试通过 |
| 4 | 无写入预览 / 冲突 / 重复检测 | ⚠️ 代码完成、测试通过，**台账未记** |
| 5 | 批次提交与回滚（原子） | ⚠️ 代码完成、测试通过，**台账未记** |

任务 4–5 是本次复核新验证的部分：`timetable_conflict_detector_test.dart`、`timetable_import_preview_test.dart`、`timetable_import_repository_test.dart`、`timetable_import_commit_test.dart`、`timetable_import_rollback_test.dart` 共 **12/12 通过**，覆盖精确重复默认跳过、教师/地点差异视为可能更新、冲突区间、提交时整事务回滚、同图同批次重复识别、回滚保护被用户改过或新增例外的日程。`timetable_import_service.dart:81-123` 也按计划发出恰好一次 `ScheduleInputChange`（提交与回滚各一次）。

**异常**：台账最后一条停在任务 3（21:26），而任务 4–5 的文件写于 21:30–21:47，随后中断，没人回写台账。因此这两个任务的「运行并确认失败」（RED）**没有留存证据**——我在计划文件里把这两步保持为未勾选，只勾了实现与验证通过的步骤。

### 未开始

| 任务 | 缺失内容 |
| --- | --- |
| 6 五步导入向导 | `lib/features/calendar/timetable_import/` 整个目录不存在（page / controller / upload / review / term / period / preview 七个文件全缺）；`router.dart` 无 `/calendar/import`；`week_view_page.dart` 无 `import-timetable` 入口；`main.dart` **没有**构造 `TimetableOcrEngine`、`TimetableImportService`、`DriftTimetableImportRepository` |
| 7 隐私与端到端验证 | `test/application/timetable_import_privacy_test.dart`、`integration_test/timetable_import_flow_test.dart` 不存在；`docs/智能日程使用教程.md` 与 `docs/testing/manual-windows-checklist.md` 均无课表导入/OCR 章节；发布版本号与打包验证未做 |

**最关键的后果**：任务 1–5 建成的 OCR 与导入后端目前**从 UI 完全不可达**。用户界面上没有任何入口能触发识别、预览或提交；`main.dart` 里连服务实例都没有装配。换句话说，这条链路「能跑测试，但用不了」。

### 阻断绿灯的两个缺陷

1. **全套测试有 1 个失败（过期断言）**
   `test/data/database_schema_test.dart:14`「创建全部十九张核心表并启用外键」仍断言 19 张表，而任务 1 已新增第 20 张表 `timetable_import_batches`。
   实测：`639 通过 / 1 失败`，报错 `Which: larger than expected`。
   漏网原因：任务 1 的验证命令只跑 `schema_migration_test.dart` 与 `repository_round_trip_test.dart`，恰好没覆盖这个文件。

2. **`flutter analyze` 不再干净（2 条 info，均出自本计划代码）**
   - `lib/application/timetable_import_service.dart:72` — `prefer_initializing_formals`
   - `test/platform/windows_timetable_ocr_test.dart:1` — `unnecessary_import`

   计划二的阶段验证曾是「无问题」，所以这是本计划引入的回归；任务 7 明确要求 analyzer 无问题。

## 5. 文档本身的记录状态

| 文档 | 勾选情况（复核后） |
| --- | --- |
| 任务分类与最早开始约束 | 29 / 36 已勾选（余 7 项均为各任务的 **Commit** 步骤） |
| 重复规则与学业日历 | 25 / 31 已勾选（余 6 项均为 Commit 步骤） |
| 本地课表导入 | 20 / 39 已勾选（余 19 项 = 7 个 Commit + 任务 4/5 各 1 个 RED 步骤 + 任务 6 的 5 步 + 任务 7 的 5 步） |

复核前三份文件的勾选框**一个都没勾**（0/36、0/31、0/39），进度只存在于 `.superpowers/sdd/*/progress.md` 与代码里。本次已按上述口径回写，并在每份计划顶部加了状态说明。

保留 Commit 步骤未勾选是有意的：台账裁定跳过逐任务提交，把它们勾上会变成假记录。

## 6. 环境坑（复现验证必读）

在 `G:\best-planing` 下重跑验证时：

1. **必须用 README 指定的 SDK**：`G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat`。
   另一个 `.tooling\flutter` 缺少 `flutter_tools.snapshot` 与 stamp，每次调用都会重新执行 `pub upgrade`，需要网络并长时间挂起。
2. **必须把临时目录指到工作区内**：

   ```powershell
   $env:TEMP = 'G:\best-planing\.flutter-tmp'
   $env:TMP  = 'G:\best-planing\.flutter-tmp'
   ```

   否则每条 `flutter test` 都会立刻以
   `null. The flutter tool cannot access the file or directory.`
   失败。根因：Dart 无法在 `C:\Users\zs200\AppData\Local\Temp` 下建临时目录（OS error 5，拒绝访问），而 `flutter test` 会在 `TestGoldenComparator` 构造时读 `Directory.systemTemp`。工作区根下已有的 `.flutter-tmp` 目录正是此前会话留下的同一处规避。
   （`flutter analyze` 不受影响，可用它快速验证「工具能用」。）
3. 建议加 `--no-version-check`，与既有台账中的调用方式一致。

## 7. 要把三份计划真正收口，还剩什么

按依赖顺序：

1. **修绿构建**：更新 `database_schema_test.dart` 的表数断言（19 → 20，并去掉标题里的「十九」），清掉 2 条 analyzer info。
2. **完成任务 6**：实现五步向导与控制器，接上 `/calendar/import` 路由、周视图导入入口，并在 `main.dart` 装配 OCR 引擎与导入仓储——这是让已完成后端真正可用的关键一步。
3. **完成任务 7**：补隐私测试（无网络、图像不进库/导出/日志）与端到端集成测试，更新两份文档，最后一次全套验证 + Windows release 打包。
4. **回写台账**：把任务 6–7 的证据补进 `.superpowers/sdd/2026-10-05-local-timetable-import/progress.md`。
5. **决定提交策略**：目前 131 文件、约 1.5 万行改动全部未提交，横跨三个计划与其他主题。建议先与用户确认哪些改动归属本主题，再按计划粒度拆分提交，避免把无关改动混进去。
