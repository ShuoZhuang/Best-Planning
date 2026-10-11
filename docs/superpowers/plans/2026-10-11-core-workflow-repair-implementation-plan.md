# Personal Planner 1.8.0 Core Workflow Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Do not use parallel agents for this plan: the tasks intentionally converge on routing, persistence, scheduling, and composition-root files. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修正时间、通知、托盘和调整计划的可靠性，并补齐课程管理、自定义保护时间、分单位延后和可解释排程，使核心工作流在失败时保持原计划不变、在成功时只产生可预期的最小改动。

**Architecture:** 先修复不需要 schema 的确定性缺陷，再统一路由与编辑器骨架；随后以 `CalendarEventKind` 扩展现有日历模型，复用重复规则承载保护时间；最后把“延后”从全局 pending 状态改成 proposal 绑定的显式调整请求，并在排程器中加入局部修复、短空档评分和结构化失败证据。所有行为以同一时区服务、同一通知对账器和同一计划验证器为准。

**Tech Stack:** Flutter / Dart、Riverpod、GoRouter、Drift / SQLite、Windows C++ runner、Windows Shell 通知区、IANA 时区、现有确定性排程引擎、MSIX。

**Spec:** `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md`

## Global Constraints

- 当前基线是已发布的 `1.7.1+42`，提交 `e84a16f2`。开始前若基线不同，先记录差异，不得强行 reset 用户改动。
- 本计划全部工作属于一个 `1.8.0` 发布批次。Task 1～15 都不改单独版本号，不创建阶段性 GitHub Release。
- 只有 Task 16 冻结发布候选时才改 `pubspec.yaml`、备份版本、MSIX 版本和 build ledger。
- 单个实现代理、单个工作树、严格按任务编号串行执行。每个任务独立提交；前一任务测试未绿，不进入下一任务。
- 开始每个任务前运行 `git status --short`。若目标文件有不属于本计划的改动，停止并报告，不覆盖、不暂存、不清理。
- 生产代码改动必须先有失败测试。测试必须因目标行为缺失而失败，不能因夹具、编译或路径错误而失败。
- 生成文件只能由项目既有生成命令更新；不得手改 `app_database.g.dart`。
- 不提交 `build/`、`.dart_tool/`、用户数据库、日志、`.pfx`、临时证书私钥、下载的 Release 资产或个人课表图片。
- 所有时间在持久层使用 UTC；所有日期、星期、按天延后和 UI 展示使用事项的 IANA 时区。
- 调整失败、预览取消或应用失败时，确认计划和用户任务数据必须保持不变。
- 任何事项名称缺失时显示“已删除的任务/日程”，禁止显示 UUID。
- 每个交给用户体验的最终版本都要有安装包。本计划只产生一个对外版本 `1.8.0`，但代码变化后的候选重建必须递增全局 build。

## Review Focus

- 时间转换是否只发生一次；位置、文字、提示和语义是否来自同一值。
- 通知关闭后是否立即清掉系统待处理项，并在重启、重排后仍保持关闭。
- 托盘单击是否处理 `WM_LBUTTONUP`，且双击不会变成“打开后又隐藏”。
- schema v9 是否只新增带默认值的 `calendar_events.kind`，旧日程是否全部保持为 fixed。
- 保护时间是否只进入 protected windows，不重复进入 fixed events 或统计。
- 课程“仅本次 / 此次及以后 / 整个课程”的范围是否准确，是否误伤同名但不同 `logicalCourseId` 的课程。
- 延后请求是否随 proposal 生命周期结束；失败后下一次普通生成不能继续带着旧请求。
- “延后 N 天”是否保留本地钟点；分钟/小时是否按经过时长计算。
- 局部修复是否先最少移动块，再最少总位移；不得为了美观移动锁定事项。
- 短空档惩罚是否只针对确实无法利用的 orphan gap，不能吞掉保护时间或把自由时间排满。
- 结构化失败原因是否来自引擎证据，而不是 UI 猜测。

---

## 0. 依赖顺序与停止条件

```text
Task 1 基线测试
  ├─ Task 2 时间轴
  ├─ Task 3 通知
  └─ Task 4 托盘
Task 5 路由骨架 → Task 6 日期时间控件
Task 7 schema/kind → Task 8 保护时间 → Task 9/10 课程管理
Task 11 调整请求 → Task 12 局部修复 → Task 13 短空档评分 → Task 14 解释
Task 15 全链路验收 → Task 16 发布
```

任一情况立即停止，不进入后续任务：

- 发现需要破坏性迁移或更换 MSIX identity；
- 需要自动修改任务截止时间才能让延后成功；
- 同一失败在修复后仍连续出现三次且没有新的证据；
- 全量测试出现与本任务无关的新失败；
- Windows 实机上出现数据丢失、重复通知、计划静默改写或无法打开主窗口。

### Task 1: 固定基线、失败样本与验收记录

**Files:**
- Create: `docs/testing/v1.8.0-core-workflow-acceptance.md`
- Create: `test/fixtures/core_workflow_repair_scenarios.dart`
- Modify: `docs/testing/manual-windows-checklist.md`

**Interfaces:**
- Produces: 所有后续测试共用的固定时钟、Asia/Shanghai 与 DST 场景、计划块夹具和人工验收表。
- Does not modify: 生产代码、版本号、数据库 schema。

- [ ] **Step 1: 记录干净基线**

运行：

```powershell
Set-Location 'G:\best-planing\.worktrees\native-implementation'
git status --short --branch
git rev-parse HEAD
flutter --version
flutter test --no-pub test/app/version_consistency_test.dart
```

Expected: HEAD 与计划基线一致或差异已写入验收文档；版本守卫 PASS。

- [ ] **Step 2: 建立共享场景**

在 fixture 中只放纯数据构造器，不放断言：上海午餐、柏林 DST、跨午夜、通知五类别、被固定事项占用的延后目标、20 分钟 orphan gap、同名不同 logicalCourseId 课程。

- [ ] **Step 3: 扩充人工清单**

新增本规范 §17 的全部场景，每项包含环境、操作、期望、实际、证据路径和通过人。默认实际结果为空，不得预先勾选。

- [ ] **Step 4: 运行 fixture 编译检查**

Run: `flutter test --no-pub test/fixtures/core_workflow_repair_scenarios.dart`

Expected: 文件可被测试环境加载；若它没有测试入口，则在一个最小 smoke test 中导入并构造全部场景。

- [ ] **Step 5: Commit**

```powershell
git add docs/testing/v1.8.0-core-workflow-acceptance.md docs/testing/manual-windows-checklist.md test/fixtures/core_workflow_repair_scenarios.dart
git commit -m "test: define 1.8 core workflow acceptance baseline"
```

### Task 2: 消除时间轴二次时区转换

**Files:**
- Modify: `lib/features/calendar/week_view/timeline_day_column.dart`
- Modify: `lib/features/calendar/week_view/schedule_view_models.dart`
- Modify: `test/features/calendar/week_timeline_test.dart`
- Modify: `test/features/calendar/timeline_layout_test.dart`
- Create: `test/features/calendar/week_timeline_time_zone_test.dart`

**Interfaces:**
- Consumes: 已转换的本地日内分钟。
- Produces: 卡片布局和显示共用的 `TimelineMinuteRange`。

- [ ] **Step 1: 写上海时区失败测试**

输入 UTC `04:00–05:00`、时区 Asia/Shanghai，断言卡片 top 对应 12:00、文字与语义均为 `12:00–13:00`。测试不得把 `toLocal` 注入成恒等函数。

- [ ] **Step 2: 写跨午夜与 DST 测试**

覆盖 23:30–00:30 切片，以及 Europe/Berlin DST 切换日。断言每段的位置、标签、tooltip 和 semantics 一致。

- [ ] **Step 3: 观察失败**

Run: `flutter test --no-pub test/features/calendar/week_timeline_test.dart test/features/calendar/timeline_layout_test.dart test/features/calendar/week_timeline_time_zone_test.dart`

Expected: 新测试因标签再次偏移而 FAIL。

- [ ] **Step 4: 改为分钟直出**

移除 `_clockAt(startMinute)` → `_local()` 链。新增或复用：

```dart
String formatLocalMinute(int minute);
```

0 显示 `00:00`，1440 仅作为区间终点显示 `24:00`；不能把 1440 回绕成 `00:00` 而丢失跨日含义。

- [ ] **Step 5: 运行专项与相关视图测试**

```powershell
flutter test --no-pub test/features/calendar/week_timeline_test.dart test/features/calendar/timeline_layout_test.dart test/features/calendar/week_timeline_time_zone_test.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart
```

Expected: 全部 PASS。

- [ ] **Step 6: Commit**

```powershell
git add lib/features/calendar/week_view/timeline_day_column.dart lib/features/calendar/week_view/schedule_view_models.dart test/features/calendar
git commit -m "fix: render week timeline from one local time source"
```

### Task 3: 让通知关闭立即且持续生效

**Files:**
- Modify: `lib/application/settings_service.dart`
- Modify: `lib/application/notification_service.dart`
- Modify: `lib/features/settings/planning_rules/planning_rules_page.dart`
- Modify: `lib/features/settings/notifications/notification_preferences_section.dart`
- Modify: `lib/app/planner_app.dart`
- Modify: `lib/main.dart`
- Modify: `test/application/notification_service_test.dart`
- Modify: `test/application/recurring_notification_service_test.dart`
- Modify: `test/features/settings/notification_preferences_section_test.dart`
- Create: `test/features/settings/notification_reconciliation_test.dart`

**Interfaces:**
- Add: `NotificationPreferences.enabled`。
- Add: `Future<NotificationSyncResult> reconcile(NotificationPreferences preferences)`。

- [ ] **Step 1: 写总开关失败测试**

预置五类 `planner.*` 和一个非本应用通知；关闭总开关后断言只取消五类本应用通知。再次 reconcile 不重复取消、不抛错。

- [ ] **Step 2: 写分类和周期目标失败测试**

关闭周期目标但保持任务通知开启，断言只取消周期目标；保存后重启服务再同步，周期目标仍不回来。

- [ ] **Step 3: 写页面编排失败测试**

点击保存后必须等待“保存 + reconcile”完成才显示成功；reconcile 抛错时显示部分失败和重试按钮。

- [ ] **Step 4: 观察失败**

Run: `flutter test --no-pub test/application/notification_service_test.dart test/application/recurring_notification_service_test.dart test/features/settings/notification_preferences_section_test.dart test/features/settings/notification_reconciliation_test.dart`

- [ ] **Step 5: 实现单一对账入口**

所有启动、计划应用和设置保存调用同一 `reconcile`。禁止页面直接逐项 cancel。总开关关闭时不读取计划来重新排通知。

- [ ] **Step 6: 补齐周期目标加载/保存/渲染**

确保 `PlanningRulesPage` 初始化、保存和 `NotificationPreferencesSection` 参数完整对称。

- [ ] **Step 7: 运行测试**

```powershell
flutter test --no-pub test/application/notification_service_test.dart test/application/recurring_notification_service_test.dart test/features/settings/notification_preferences_section_test.dart test/features/settings/notification_reconciliation_test.dart test/application/settings_service_test.dart
```

- [ ] **Step 8: Commit**

```powershell
git add lib/application/settings_service.dart lib/application/notification_service.dart lib/features/settings/planning_rules/planning_rules_page.dart lib/features/settings/notifications/notification_preferences_section.dart lib/app/planner_app.dart lib/main.dart test
git commit -m "fix: reconcile notification switches with pending alerts"
```

### Task 4: 托盘左键单击打开主窗口

**Files:**
- Modify: `windows/runner/tray_icon.h`
- Modify: `windows/runner/tray_icon.cpp`
- Modify: `windows/runner/flutter_window.cpp`
- Modify: `windows/runner/CMakeLists.txt`
- Create: `windows/runner/tray_icon_message_policy.h`
- Create: `windows/runner/tray_icon_message_policy_test.cpp`
- Modify: `docs/testing/v1.8.0-core-workflow-acceptance.md`

**Interfaces:**
- Add pure function: `TrayAction ActionForTrayMessage(UINT message)`。
- Keep: `TrayIcon::RestoreMainWindow()` is idempotent。

- [ ] **Step 1: 写原生消息策略测试**

断言 `WM_LBUTTONUP`、`WM_LBUTTONDBLCLK`、`NIN_SELECT`、`NIN_KEYSELECT` 都映射为 open；`WM_RBUTTONUP` / `WM_CONTEXTMENU` 映射为 menu；其他消息为 none。

- [ ] **Step 2: 把原生测试接入 CMake**

测试目标不得链接 Flutter 引擎，只测试纯消息映射。先运行
`flutter build windows --debug --no-pub` 生成 CMake 构建目录，再运行
`cmake --build build/windows/x64 --config Debug --target tray_icon_message_policy_test`，最后执行生成的测试 exe。

Expected before implementation: 编译或断言失败；不能只有人工验证。

- [ ] **Step 3: 实现单击与键盘选择**

`HandleMessage` 对 open 类消息只调用一次 `RestoreMainWindow()`。不得实现左键切换隐藏。

- [ ] **Step 4: 加强恢复顺序**

恢复/显示/前台请求按规范 §6 执行；前台失败时 `FlashWindowEx`，不创建新窗口。

- [ ] **Step 5: 构建并人工检查**

```powershell
flutter build windows --debug --no-pub
```

依次验证：窗口正常、最小化、关闭到托盘、被其他窗口遮挡、应用锁开启、连续双击。结果和录屏/截图路径写入验收文档。

- [ ] **Step 6: Commit**

```powershell
git add windows/runner docs/testing/v1.8.0-core-workflow-acceptance.md
git commit -m "fix: open the main window on tray left click"
```

### Task 5: 统一新建入口和侧栏归属

**Files:**
- Modify: `lib/app/router.dart`
- Modify: `lib/features/tasks/task_type_chooser.dart`
- Create: `lib/design/planner_editor_scaffold.dart`
- Modify: `test/app/app_smoke_test.dart`
- Modify: `test/app/calendar_event_route_test.dart`
- Modify: `test/app/recurring_task_route_test.dart`
- Create: `test/app/new_item_navigation_test.dart`

**Interfaces:**
- Add route: `/new`。
- Add: `int? plannerRailIndexForLocation(String location)` pure helper。

- [ ] **Step 1: 写路由归属表测试**

覆盖规范 §7.2 的全部前缀、`/new`、深链返回和未知路径。`/tasks/new/task` 必须是任务，`/calendar/protected/new` 必须是日历。

- [ ] **Step 2: 写 chooser 分组测试**

断言标题“新建事项”，两组标题存在，四张卡分别进入正确路径；保护时间不得进入设置。

- [ ] **Step 3: 观察失败**

Run: `flutter test --no-pub test/app/new_item_navigation_test.dart test/app/app_smoke_test.dart test/app/calendar_event_route_test.dart test/app/recurring_task_route_test.dart`

- [ ] **Step 4: 提取纯路由映射并迁移入口**

保留旧 `/tasks/new` 重定向到 `/new`，避免旧深链失效。`NavigationRail.selectedIndex` 对 `/new` 使用 null。

- [ ] **Step 5: 增加共享编辑器骨架**

只抽布局、返回、保存栏和错误摘要，不强迫四类事项共享同一字段模型。

- [ ] **Step 6: 运行测试并提交**

```powershell
flutter test --no-pub test/app/new_item_navigation_test.dart test/app/app_smoke_test.dart test/app/calendar_event_route_test.dart test/app/recurring_task_route_test.dart
git add lib/app/router.dart lib/features/tasks/task_type_chooser.dart lib/design/planner_editor_scaffold.dart test/app
git commit -m "fix: align new item routes with their owning modules"
```

### Task 6: 用选择器统一固定日程日期与时间

**Files:**
- Modify: `lib/design/planner_pickers.dart`
- Create: `lib/design/planner_date_time_fields.dart`
- Modify: `lib/features/calendar/event_editor/event_editor_form.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `test/features/calendar/event_editor_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Create: `test/design/planner_date_time_fields_test.dart`

**Interfaces:**
- Add widgets: `PlannerDateField`, `PlannerTimeField`。
- Both expose typed `DateTime` / `TimeOfDay`, not text parsing results。

- [ ] **Step 1: 写字段交互和键盘测试**

点击或按 Enter 打开 picker；取消不改值；确认更新值；焦点返回触发字段；语义标签包含当前值。

- [ ] **Step 2: 写时长联动和跨日测试**

开始时间后移时保持原时长；结束不晚于开始时出现明确错误/跨日选择，不能静默保存负时长。

- [ ] **Step 3: 观察失败**

Run: `flutter test --no-pub test/design/planner_date_time_fields_test.dart test/features/calendar/event_editor_test.dart test/features/calendar/day_view_test.dart`

- [ ] **Step 4: 实现 typed fields 并替换两套文本框**

所有 picker 都传 `plannerPickerBuilder`。删除生产路径中的日期/时间字符串解析；格式化只用于显示。

- [ ] **Step 5: 运行测试并提交**

```powershell
flutter test --no-pub test/design/planner_date_time_fields_test.dart test/features/calendar/event_editor_test.dart test/features/calendar/day_view_test.dart test/design/date_picker_selection_test.dart
git add lib/design lib/features/calendar test/design test/features/calendar
git commit -m "fix: replace calendar time text entry with pickers"
```

### Task 7: schema v9 与日历事项种类

**Files:**
- Modify: `lib/domain/models/calendar_event.dart`
- Modify: `lib/application/calendar_service.dart`
- Modify: `lib/data/database/tables/planner_tables.dart`
- Modify: `lib/data/database/app_database.dart`
- Regenerate: `lib/data/database/app_database.steps.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `lib/data/repositories/drift_export_data_source.dart`
- Modify: `lib/app/backup_assembly.dart`
- Regenerate: `lib/data/database/app_database.g.dart`
- Regenerate: `drift_schemas/app_database/drift_schema_v9.json`
- Create: `test/data/calendar_event_kind_migration_test.dart`
- Modify: `test/data/database_schema_test.dart`
- Modify: `test/data/repository_round_trip_test.dart`
- Modify: `test/application/backup_service_test.dart`
- Modify: `test/data/calendar_event_deletion_test.dart`

**Interfaces:**
- Add: `CalendarEventKind { fixed, protected }` with stable storage strings。
- Add: `CalendarEvent.kind` default fixed for source compatibility where appropriate。

- [ ] **Step 1: 写 v8→v9 失败迁移测试**

构造含单次、重复、导入课程和例外的 v8 数据库。迁移后记录数不变、外键有效、所有旧行 kind=`fixed`、出现时间不变。

- [ ] **Step 2: 写模型与仓储往返测试**

fixed/protected 保存、读取、导出、恢复后 kind 不丢失；未知 storage value 不能静默变成 protected。

- [ ] **Step 3: 观察失败**

Run: `flutter test --no-pub test/data/calendar_event_kind_migration_test.dart test/data/database_schema_test.dart test/data/repository_round_trip_test.dart test/application/backup_service_test.dart test/data/calendar_event_deletion_test.dart`

- [ ] **Step 4: 实现迁移**

在单事务中新增非空列，默认 `fixed`。更新 `schemaVersion` 为 9。不得重写时间、id 或 recurrence 关系。

- [ ] **Step 5: 生成代码和 schema**

```powershell
dart run build_runner build --delete-conflicting-outputs
```

`build.yaml` 已为 `app_database` 配置 `schema_dir: drift_schemas/`，上述生成命令必须同时产出
`drift_schemas/app_database/drift_schema_v9.json`。若没有产出，停止并修正生成配置；不得手工造 JSON。

- [ ] **Step 6: 运行数据测试**

```powershell
flutter test --no-pub test/data/calendar_event_kind_migration_test.dart test/data/database_schema_test.dart test/data/repository_round_trip_test.dart test/application/backup_service_test.dart test/data/calendar_event_deletion_test.dart test/app/version_consistency_test.dart
```

- [ ] **Step 7: Commit**

```powershell
git add lib/domain/models/calendar_event.dart lib/application/calendar_service.dart lib/data lib/app/backup_assembly.dart drift_schemas test/data test/application/backup_service_test.dart
git commit -m "feat: distinguish fixed events from protected time"
```

### Task 8: 独立保护时间编辑、显示和排程

**Files:**
- Create: `lib/features/calendar/protected_time/protected_time_editor_page.dart`
- Create: `lib/features/calendar/protected_time/protected_time_list_page.dart`
- Modify: `lib/features/calendar/week_view/schedule_view_source.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/application/analytics_service.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/app/planner_app.dart`
- Create: `test/features/calendar/protected_time_editor_test.dart`
- Create: `test/application/protected_calendar_event_mapping_test.dart`
- Modify: `test/features/calendar/schedule_view_source_test.dart`
- Modify: `test/application/analytics_service_test.dart`

**Interfaces:**
- Reuse: `CalendarService.save()` with `EventDraft.kind`。
- Add: repository query/filter needed to list protected series。

- [ ] **Step 1: 写 one-off 与 recurring 编辑失败测试**

覆盖日期/时间 picker、星期、重复截止日期、标题默认值、跨日错误、保存和取消。

- [ ] **Step 2: 写排程映射失败测试**

protected occurrence 只进入 protected windows，一次且仅一次；同一记录不得同时成为 fixed event。任务不能覆盖该范围。

- [ ] **Step 3: 写统计排除测试**

保护时间不计入领域投入和固定日程投入；保护时间统计仍按既有保护口径展示。

- [ ] **Step 4: 观察失败**

Run: `flutter test --no-pub test/features/calendar/protected_time_editor_test.dart test/application/protected_calendar_event_mapping_test.dart test/features/calendar/schedule_view_source_test.dart test/application/analytics_service_test.dart`

- [ ] **Step 5: 实现页面、路由和数据映射**

`/calendar/protected/new` 高亮日历。更多菜单支持仅本次、此次及以后、整个系列编辑/删除，复用 CalendarService 的范围语义。

- [ ] **Step 6: 运行测试并提交**

```powershell
flutter test --no-pub test/features/calendar/protected_time_editor_test.dart test/application/protected_calendar_event_mapping_test.dart test/features/calendar/schedule_view_source_test.dart test/application/analytics_service_test.dart test/app/calendar_event_route_test.dart test/scheduling/protected_time_expander_test.dart
git add lib/features/calendar/protected_time lib/features/calendar lib/application lib/app test
git commit -m "feat: add editable calendar protection windows"
```

### Task 9: 建立课程管理查询与事务服务

**Files:**
- Create: `lib/domain/models/course_series.dart`
- Create: `lib/domain/repositories/course_series_repository.dart`
- Create: `lib/application/course_management_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `lib/data/repositories/drift_timetable_import_repository.dart`
- Modify: `lib/app/backup_assembly.dart`
- Create: `test/data/course_series_repository_test.dart`
- Create: `test/application/course_management_service_test.dart`

**Interfaces:**
- Implement `CourseSeriesRepository` from spec §10.3。
- Add commands: editOccurrence, editFollowing, editWholeCourse, pauseFrom, previewDelete, deleteCourse。

- [ ] **Step 1: 写聚合查询失败测试**

同一 logicalCourseId 的单双周/分段规则聚合成一门课程；同名不同 id 分开；按 termId 过滤；普通手工固定日程不出现。

- [ ] **Step 2: 写范围修改失败测试**

分别验证仅本次、此次及以后、整个课程。整个课程只操作相同 logicalCourseId 且属于当前学期的系列。

- [ ] **Step 3: 写暂停、删除和回滚测试**

暂停保留历史；删除先返回影响次数和冲突；事务中任一写入失败时全部回滚。撤销导入仍按 batch，不与删单门混用。

- [ ] **Step 4: 观察失败**

Run: `flutter test --no-pub test/data/course_series_repository_test.dart test/application/course_management_service_test.dart`

- [ ] **Step 5: 实现端口和服务**

页面不可拿数据库对象。服务完成范围解析、冲突预览、事务、重排事件和通知对账触发。

- [ ] **Step 6: 运行测试并提交**

```powershell
flutter test --no-pub test/data/course_series_repository_test.dart test/application/course_management_service_test.dart test/application/timetable_import_commit_test.dart test/application/timetable_import_preview_test.dart test/application/timetable_import_rollback_test.dart test/data/calendar_event_deletion_test.dart
git add lib/domain/models/course_series.dart lib/domain/repositories/course_series_repository.dart lib/application/course_management_service.dart lib/data/repositories lib/app/backup_assembly.dart test
git commit -m "feat: add course series management service"
```

### Task 10: 增加课程管理页面和卡片入口

**Files:**
- Create: `lib/features/calendar/courses/course_management_page.dart`
- Create: `lib/features/calendar/courses/course_detail_page.dart`
- Create: `lib/features/calendar/courses/course_edit_dialog.dart`
- Modify: `lib/features/calendar/week_view/week_view_page.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/app/planner_app.dart`
- Create: `test/features/calendar/course_management_page_test.dart`
- Create: `test/app/course_management_route_test.dart`

**Interfaces:**
- Routes: `/calendar/courses`, `/calendar/courses/:logicalCourseId`。

- [ ] **Step 1: 写列表与深链失败测试**

按当前学期展示；无课程空状态可导入；卡片“管理这门课”按 id 深链；同名课程不会打开错项。

- [ ] **Step 2: 写编辑范围和删除确认测试**

三种范围显示影响说明；删除必须显示课程名和次数并二次确认；服务失败时列表不假装删除。

- [ ] **Step 3: 写冲突预览测试**

修改时间后先显示冲突，再允许返回修改；硬冲突不能直接保存。

- [ ] **Step 4: 实现页面与入口**

复用日期时间字段和共享编辑器骨架。周视图工具栏增加“管理课程”。

- [ ] **Step 5: 运行测试并提交**

```powershell
flutter test --no-pub test/features/calendar/course_management_page_test.dart test/app/course_management_route_test.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart
git add lib/features/calendar/courses lib/features/calendar/week_view/week_view_page.dart lib/features/calendar/day_view/day_view_page.dart lib/app test
git commit -m "feat: add term based course management"
```

### Task 11: 把延后改为 proposal 绑定的类型化请求

**Files:**
- Create: `lib/domain/models/plan_adjustment.dart`
- Create: `lib/features/today/defer_plan_block_dialog.dart`
- Modify: `lib/application/planning_service.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/application/pending_moves.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/app/today_route_test.dart`
- Create: `test/features/today/defer_plan_block_dialog_test.dart`
- Modify: `test/application/requested_move_test.dart`
- Create: `test/application/plan_adjustment_lifecycle_test.dart`

**Interfaces:**
- Add: `DeferUnit`, `DeferPlanBlockRequest`, `PlanAdjustmentRequest`。
- Add: `PlanningService.createAdjustmentProposal(adjustment)`。
- Keep drag/drop requests working; migrate them to the same lifecycle or isolate them explicitly。

- [ ] **Step 1: 写分钟/小时/天 UI 失败测试**

验证全部快捷值、自定义边界、5 分钟实际对齐提示、原时间→最早时间预览、取消无副作用。

- [ ] **Step 2: 写 DST 和单位语义测试**

分钟/小时按 elapsed duration；天按 IANA 本地日历并保持钟点。覆盖春季跳时和秋季重复小时。

- [ ] **Step 3: 写生命周期失败测试**

生成失败、预览取消、应用成功、应用失败四种结果后，下一次普通生成都不含上次调整。

- [ ] **Step 4: 观察失败**

Run: `flutter test --no-pub test/features/today/defer_plan_block_dialog_test.dart test/application/requested_move_test.dart test/application/plan_adjustment_lifecycle_test.dart test/app/today_route_test.dart`

- [ ] **Step 5: 实现显式请求链**

路由不得先写全局 draft 再调用普通 `createProposal()`。proposal 元数据记录用户请求，预览可显示。

- [ ] **Step 6: 运行测试并提交**

```powershell
flutter test --no-pub test/features/today/defer_plan_block_dialog_test.dart test/application/requested_move_test.dart test/application/plan_adjustment_lifecycle_test.dart test/app/today_route_test.dart
git add lib/domain/models/plan_adjustment.dart lib/features/today/defer_plan_block_dialog.dart lib/application lib/app/router.dart test
git commit -m "feat: model plan deferral as a scoped adjustment"
```

### Task 12: 实现延后后的最小改动局部修复

**Files:**
- Create: `lib/scheduling/local_schedule_repair.dart`
- Modify: `lib/scheduling/schedule_problem.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/plan_validator.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Create: `test/scheduling/local_schedule_repair_test.dart`
- Modify: `test/scheduling/schedule_engine_test.dart`
- Modify: `test/scheduling/schedule_engine_time_zone_test.dart`
- Modify: `test/application/requested_move_test.dart`

**Interfaces:**
- Add: `LocalRepairResult repair(LocalRepairInput input)` pure deterministic service。
- Result includes changed blocks, unscheduled evidence, and lexicographic cost tuple。

- [ ] **Step 1: 写“目标点被占仍能延后”失败测试**

原块 15:10–15:25，延后 30 分钟，15:40 被占。断言目标块落到其后最近完整合法时段，而不是报“可用时间不足”。

- [ ] **Step 2: 写同日级联和跨日测试**

只移动必要的后续未锁定块；同日不足才跨日；不移动过去、固定、保护、睡眠和锁定块。

- [ ] **Step 3: 写最小改动字典序测试**

方案 A 移 1 个块 60 分钟，方案 B 移 2 个块各 5 分钟时选 A；移动块数相同再比较总位移；前两项相同再选离目标最近。

- [ ] **Step 4: 写失败原子性测试**

无解时返回原因，confirmed plan、repository、pending state 都不变。硬截止不得被自动延长。

- [ ] **Step 5: 观察失败**

Run: `flutter test --no-pub test/scheduling/local_schedule_repair_test.dart test/scheduling/schedule_engine_test.dart test/scheduling/schedule_engine_time_zone_test.dart test/application/requested_move_test.dart`

- [ ] **Step 6: 实现纯局部修复器**

使用稳定排序：本地日期、开始时刻、block id 作为最终 tie-break。所有候选交 `PlanValidator` 复核。

- [ ] **Step 7: 提升算法版本并运行测试**

算法输出变化必须提升 `DeterministicScheduleEngine.algorithmVersion`。运行上述测试及 proposal 应用测试。

- [ ] **Step 8: Commit**

```powershell
git add lib/scheduling lib/application/repository_schedule_problem_source.dart test/scheduling test/application/requested_move_test.dart
git commit -m "feat: repair deferred plans with minimal displacement"
```

### Task 13: 识别并减少无法利用的短空档

**Files:**
- Modify: `lib/scheduling/candidate_scorer.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/explanations.dart`
- Create: `lib/scheduling/gap_classifier.dart`
- Create: `test/scheduling/gap_classifier_test.dart`
- Modify: `test/scheduling/candidate_scorer_test.dart`
- Modify: `test/scheduling/schedule_engine_test.dart`

**Interfaces:**
- Add: `GapKind { intentionalBreak, usable, orphan, freeTime }`。
- Add four scoring factors from spec §12.2。

- [ ] **Step 1: 写 gap 分类失败测试**

20 分钟能否利用取决于剩余任务的最小合法片段，不得用全局固定阈值。保护时间和规则休息必须归 intentional。

- [ ] **Step 2: 写候选比较失败测试**

两方案硬约束、截止和移动代价相同，选择 orphan gap 更少者；若任务已全部安排，剩余 20 分钟归 freeTime，不受惩罚。

- [ ] **Step 3: 写不挤占休息测试**

不能为了消除视觉空白缩短 minBreak、覆盖保护时间或超过每日可移动上限。

- [ ] **Step 4: 观察失败**

Run: `flutter test --no-pub test/scheduling/gap_classifier_test.dart test/scheduling/candidate_scorer_test.dart test/scheduling/schedule_engine_test.dart`

- [ ] **Step 5: 实现纯分类器和评分项**

分类器只读当前计划、剩余任务和规则；评分 breakdown 必须能解释为何选择更紧凑方案。

- [ ] **Step 6: 提升算法版本、运行测试并提交**

```powershell
flutter test --no-pub test/scheduling/gap_classifier_test.dart test/scheduling/candidate_scorer_test.dart test/scheduling/schedule_engine_test.dart test/scheduling/plan_validator_test.dart
git add lib/scheduling test/scheduling
git commit -m "feat: avoid unusable gaps without consuming free time"
```

### Task 14: 把延后失败接入现有标题与结构化解释链

**Files:**
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/scheduling/unscheduled_reason_test.dart`
- Modify: `test/features/planning/unscheduled_display_test.dart`
- Modify: `test/features/planning/plan_preview_test.dart`
- Modify: `test/application/plan_generation_flow_test.dart`

**Interfaces:**
- Reuse: existing `UnscheduledReasonCode`, `UnscheduledReason`, `TaskTitleLookup.titlesFor()`。
- Add only if evidence proves necessary: one adjustment-specific reason/evidence field; do not create a parallel reason model。

- [ ] **Step 1: 先运行现有结构化原因与标题测试**

Run: `flutter test --no-pub test/scheduling/unscheduled_reason_test.dart test/features/planning/unscheduled_display_test.dart`

Expected: 基线 PASS，证明现有普通生成路径已经有结构化原因和批量标题解析。若失败，先修基线，不能在本任务另造接口绕过。

- [ ] **Step 2: 写延后失败的预览标题测试**

延后请求无解时，已知任务显示标题；已删除任务显示现有占位名；调整摘要、未安排组和冲突组的任何可见文本都不含 UUID 格式。

- [ ] **Step 3: 写延后证据复用测试**

目标点之后连续空档不足、截止越界、锁定块阻塞分别复用现有 reason code 和数字证据。N 个未安排任务仍只调用一次 `titlesFor()`，避免 N+1。

- [ ] **Step 4: 观察失败**

Run: `flutter test --no-pub test/scheduling/unscheduled_reason_test.dart test/features/planning/unscheduled_display_test.dart test/features/planning/plan_preview_test.dart test/application/plan_generation_flow_test.dart`

- [ ] **Step 5: 把调整路径接到同一装配链**

普通 proposal 和 adjustment proposal 共用标题解析、`unscheduledReasonLabel()` 与预览模型构造。
UI 只翻译 reason 和 evidence，不重新推导原因。若现有证据足够，不修改枚举和持久层。

- [ ] **Step 6: 运行测试并提交**

```powershell
flutter test --no-pub test/scheduling/unscheduled_reason_test.dart test/features/planning/unscheduled_display_test.dart test/features/planning/plan_preview_test.dart test/application/plan_generation_flow_test.dart test/application/requested_move_test.dart
git add lib/scheduling lib/features/planning/plan_preview_page.dart lib/app/router.dart test/scheduling/unscheduled_reason_test.dart test/features/planning test/application/plan_generation_flow_test.dart test/application/requested_move_test.dart
git commit -m "feat: explain scheduling failures without internal ids"
```

### Task 15: 全链路回归、可访问性和真实数据库验证

**Files:**
- Modify: `integration_test/first_plan_flow_test.dart`
- Create: `integration_test/core_workflow_repair_test.dart`
- Modify: `docs/testing/v1.8.0-core-workflow-acceptance.md`
- Modify: `docs/testing/manual-windows-checklist.md`
- Modify: `README.md`

**Interfaces:**
- No new production interfaces。

- [ ] **Step 1: 建立端到端场景**

依次覆盖：新建任务归属、固定日程 picker、自定义保护时间、课程管理改写、生成计划、延后分钟/小时/天、失败后原计划不变、关闭通知、托盘恢复。

- [ ] **Step 2: 运行格式和静态检查**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --no-pub
```

- [ ] **Step 3: 运行全量单测**

Run: `flutter test --no-pub`

Expected: 全部 PASS；不得用 skip 掩盖新增失败。

- [ ] **Step 4: 逐条运行 Windows 集成测试**

```powershell
flutter test --no-pub integration_test/first_plan_flow_test.dart -d windows
flutter test --no-pub integration_test/core_workflow_repair_test.dart -d windows
```

按现有发布文档要求逐条运行，避免批量 debug connection 问题。

- [ ] **Step 5: 用 v8 副本验证迁移**

只复制测试数据，绝不直接操作用户唯一数据库。记录迁移前后 fingerprint、记录数、外键检查、课程数、保护时间数和计划数。

- [ ] **Step 6: 完成人工清单**

在 Windows 10/11 x64 至少一台真实机器逐项填写实际结果。托盘、系统通知、覆盖安装无法只靠 widget test 判定，缺少实机证据即不通过。

- [ ] **Step 7: 回归 1.7.1 已有能力**

重点验证周期目标均匀分布、今日详情、更新检查、统计、课表导入、备份恢复、应用锁和颜色规则没有倒退。

- [ ] **Step 8: Commit**

```powershell
git add integration_test docs/testing README.md
git commit -m "test: verify 1.8 core workflows end to end"
```

### Task 16: 冻结 `1.8.0`、构建安装包并正式发布

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/app/backup_assembly.dart`
- Modify: `docs/release/version-policy.md`
- Modify: `docs/release/build-ledger.md`
- Modify: `docs/release/windows-release.md`
- Create: `docs/release/1.8.0-buildNN-user-guide.md`
- Create: `docs/release/1.8.0-github-release-body.md`
- Modify: `README.md`
- Create outside git tracking as release artifacts: `release/PersonalPlanner-1.8.0-buildNN-windows-x64-YYYYMMDD/`

**Interfaces:**
- Version source: `pubspec.yaml` only。
- `NN`: 执行时从 `build-ledger.md` 读取并分配严格大于 42 的下一个未使用全局 build；不要在代码修改前预占。

- [ ] **Step 1: 冻结提交并确认工作树**

```powershell
git status --short --branch
git log -1 --oneline
```

除本计划已审查的文档改动外必须干净。记录候选 commit。

- [ ] **Step 2: 按规则改版本三处**

设置 `version: 1.8.0+NN`，MSIX `1.8.0.0`，output name 与备份清单版本一致。不得沿用 `1.7.1.1`，不得为了代码变化只抬 MSIX 第四段。

- [ ] **Step 3: 运行版本守卫**

Run: `flutter test --no-pub test/app/version_consistency_test.dart`

Expected: PASS，且测试明确核对 Dart、MSIX 和备份清单。

- [ ] **Step 4: 最终验证**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release --no-pub
dart run msix:create
```

任何命令失败都停止；不得先打 tag 或上传资产。

- [ ] **Step 5: 组装唯一发布目录**

必须包含：

- 可直接运行的 Release 目录及依赖 DLL；
- 便携 ZIP；
- 已签名 MSIX；
- `PersonalPlanner-signing-cert.cer` 公钥证书，不含 `.pfx` 和私钥；
- `installer/install-planner.ps1` 与 `installer/安装.cmd`；
- 用户指南、安装说明、Release Notes；
- 每个资产的 SHA-256 清单。

- [ ] **Step 6: 验证签名和覆盖安装**

`Get-AuthenticodeSignature` 必须为 Valid；从已安装 `1.7.1` 覆盖安装成功；启动后数据、课程、计划和设置保留；卸载策略符合文档。

- [ ] **Step 7: 验证全新机器体验**

在未安装 Flutter 的 Windows 10/11 x64 环境用 MSIX 安装；无需配置开发环境即可启动。验证托盘、通知开关、迁移/全新库、检查更新和卸载。

- [ ] **Step 8: 写台账和最终文档**

所有文件名、版本、build、commit、大小、SHA-256 和验证时间逐字一致。README 的下载按钮指向本次 GitHub Release，不指向源码构建说明。

- [ ] **Step 9: 发布提交**

```powershell
git add pubspec.yaml lib/app/backup_assembly.dart docs/release README.md
git commit -m "chore(release): prepare Personal Planner 1.8.0 build NN"
```

- [ ] **Step 10: tag 与 GitHub Release**

仅在提交已推送且所有资产复核后：

```powershell
git tag -a v1.8.0-buildNN -m "Personal Planner 1.8.0 build NN"
git push origin HEAD
git push origin v1.8.0-buildNN
```

随后创建 GitHub Release 并上传完整资产。GitHub Release 页面、tag、build ledger 和用户指南全部一致后，才把台账状态改为“已发布”。

## 1.8.0 完成定义

只有以下条件全部满足，才能对用户说“修复完成”：

- Task 1～16 全部勾选，且每个任务有独立、可回退的提交；
- 全量单测、静态检查、Windows 集成测试通过；
- schema v8→v9 的自动化与真实副本迁移都通过；
- 人工验收矩阵没有“不通过”或空白的阻断项；
- 延后失败不会改变确认计划，也不会污染下一次生成；
- 关闭通知后系统待处理通知已被实际取消；
- 托盘左键在隐藏、最小化和遮挡三种状态均能打开；
- 安装包在无 Flutter 环境可安装、可启动、可从 1.7.1 覆盖升级；
- GitHub Release 资产齐全、签名有效、SHA-256 一致；
- `git status --short` 干净，最终 tag 指向已验证的发布提交。

## 实施完成后的审查问题

实现代理交付前必须逐条回答，并给出测试或代码位置：

1. 哪个函数现在是 UTC→本地时间的唯一转换边界？
2. 通知总开关关闭后，哪些调用保证旧通知取消且不会被重建？
3. Windows 单击实际对应哪些消息，为什么双击仍幂等？
4. protected event 如何避免同时进入 fixed 和 protected 两类占用？
5. 课程整个系列修改如何限定 logicalCourseId 与 termId？
6. 延后请求在四种结束路径中分别何时销毁？
7. 局部修复的 cost tuple 如何保证“少动块”优先于“少动分钟”？
8. orphan gap 如何证明不是用户休息或普通自由时间？
9. 未安排原因的证据由哪里采集，UI 是否只负责翻译？
10. 哪些实机证据证明安装包而不是 debug 构建通过验收？

