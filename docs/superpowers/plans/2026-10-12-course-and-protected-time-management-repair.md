# 课程与保护时间管理修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Do not use parallel agents for this plan: the tasks share calendar mutation contracts, Drift transactions, `router.dart`, settings serialization, and release metadata. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让“管理课程”可以修正真实课程资料和上课规则，让用户创建的保护时间可以重新打开、改名并按正确范围修改，同时补上可配置的早餐保护，且不破坏旧课表、旧保护时间、排程硬约束或备份兼容性。

**Architecture:** 继续复用现有 `CalendarEvent`、`RecurrenceRule` 和 `CalendarEventKind.protected`，不建立第二套课程日历或保护时间表。课程编辑通过课程聚合读模型和一个事务性写网关完成；自定义保护时间通过系列级读模型和统一的创建/编辑表单完成；早餐沿用 `PlanningRules.protectedTimes`。所有写入先校验、再预览、最后在单个事务中提交；任何失败都保持原数据不变。

**Tech Stack:** Flutter / Dart、GoRouter、Drift / SQLite、现有 `CalendarService`、IANA 时区、Flutter widget/integration tests、Windows MSIX。

**Spec:** `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md` §3、§4、§8、§9、§10、§14、§17。本文件是针对已发现实现偏差的实施补充；与该规范 §9、§10 的含糊处冲突时，以本文件“产品裁定”与“验收矩阵”为准。

## Global Constraints

- 只修复课程资料管理、自定义保护时间编辑和早餐保护；不顺带重做课表导入、排程评分、统计页面或通知系统。
- 继续使用 `calendar_events` 与 `recurrence_rules`；数据库 schema 保持 v9，不新增表或列，不手改 `app_database.g.dart`。
- 课程教师继续存放在导入课程锚点的 `notes` 字段；本批次不引入“课程备注”这一新概念，避免把教师和备注混成两个含义。
- 所有持久化时刻使用 UTC；星期、周次、日期选择和显示使用事项自己的 IANA 时区。禁止用固定 24 小时替代本地日历日。
- 保护时间始终是硬约束，只进入 `protectedIntervals`；不得同时进入固定日程投入、领域投入或任务完成统计。
- 课程和保护时间的单次、此次及以后、整个系列操作必须使用真实锚点与真实发生时间；没有锚点时不显示范围入口。
- 任何跨多行写入必须包在同一个 Drift 事务中。冲突、过期快照、异常或校验失败时不得留下半条课程、孤儿规则或无锚点例外。
- 页面不得显示 UUID、数据库异常或内部枚举名。错误必须包含事项标题、失败字段和下一步操作。
- 新入口支持键盘、Esc 返回、可见焦点、非空语义标签和至少 44×44 的点击区域。
- 不覆盖用户工作树中的无关改动；每个任务只提交本任务列出的文件。
- 当前正式版仍是 `1.6.2+37`；`1.8.0+43` 是未发布候选。本计划完成后仍属于 `1.8.0` 发布批次，首个候选使用 `1.8.0+44` / MSIX `1.8.0.1`。若候选源码再次变化，构建号和 MSIX revision 必须继续递增。
- 每个交给用户体验的候选都必须产出便携目录、ZIP、已签名 MSIX、一键安装器、安装说明与 SHA-256 清单；不得提交或打包 `.pfx`、私钥、用户数据库、日志或个人课表图片。

## Review Focus

- 一门课程有多个星期、单双周片段或同名课程时，编辑不能把多个片段压成同一天、误伤另一门课或只改到一半。
- 用户在编辑期间遇到课表被其它窗口修改、课程被删除或保护时间系列被拆分时，保存必须返回“内容已变化，请重新打开”，不能覆盖新数据。
- 重复保护时间在管理页只能显示一个系列条目；从日历某次发生进入时才显示“仅本次 / 此次及以后 / 整个系列”。
- 整个保护系列改名后，未来正常发生与未来非删除例外都显示新名称；过去记录不被追溯改写。
- 早餐与睡眠、午餐或其它保护窗口重叠时必须在保存前指出具体重叠区间；不能静默合并或重复计算保护分钟。

---

## 1. 已确认的问题与根因

### 1.1 课程管理只做了“查看 + 改钟点”

当前 `CourseDetailPage` 展示课程名、教师、地点和系列片段，但操作只有改时间、暂停、删除。`CourseEditDialog` 只返回开始与结束分钟，名称、教师、地点、星期、周次、单双周、领域、项目都没有输入或写入接口。

页面上的 `CourseEditScope` 选择器也没有接进 `_editTime()`；无论用户选择哪一项，代码都调用 `editWholeCourse()`。这不是文案问题，而是作用范围没有落地。

### 1.2 自定义保护时间能创建，不能完整编辑

`ProtectedTimeEditorPage` 创建时可填写标题，但每次保存都生成新的 `CalendarEvent`。`ProtectedTimeListPage` 读取未来 180 天的展开结果，因此重复保护时间会按发生次数出现，页面只提供删除，没有编辑。

日视图的“改这一次”对话框只编辑日期与时间，保存时把原 `item.title` 原样传回，所以用户无法改名。现有“编辑既有事项时原备注被原样写回”测试只证明初始备注会被再次创建，并没有证明更新了原记录。

### 1.3 早餐没有进入规则模型

`ProtectedTimeKind` 只有 `lunch`、`dinner`、`fixedRest`。设置页、默认设置、首次引导、统计标签和计划预览均按这三个值写死，因此不存在可被界面打开的早餐规则。

## 2. 产品裁定

### 2.1 课程资料与上课安排分开编辑

“编辑课程资料”作用于当前学期内相同 `logicalCourseId` 的全部锚点，字段固定为：

- 课程名称，必填，去掉首尾空白；
- 教师，可空；
- 地点，可空；
- 所属领域，可空；
- 所属项目，可空，但非空项目必须属于所选领域；
- 上课安排列表，至少保留一行；允许新增、修改和删除片段。

每条上课安排包含星期集合、开始时间、结束时间、起始周、结束周和频率。频率只允许“每周、单周、双周”；起始周与单双周不相符时，保存前明确报错，不自动把第 2 周改成第 3 周。

课程安排是当前学期的权威资料，不是只改未来的临时调整：删除一行会删除该锚点、重复规则及其全部例外，并让该行对应的过去课次也不再出现在日历历史中；新增一行会按完整周次范围出现。预览必须明确列出新增/删除片段数、受影响课次数和会删除的例外数，用户二次确认后才能应用。若用户只想改一次或只改未来，必须走 §2.2 的具体课次入口。

课程管理页的“编辑课程”保存的是整个课程快照，不显示“仅本次”。用户要修改某一次或从某一次开始修改，必须从日历上的具体课次进入，因为只有那里拥有真实发生时间。课程详情页删除当前无效的全局范围选择器。

### 2.2 日历课次的范围语义

点开一节具体课程后可以选择：

- **仅本次**：写一条例外，只修改该次的标题、地点、开始、结束；不改教师、领域、项目和系列规则。
- **此次及以后**：以该次本地日期拆分当前锚点，只修改当前上课序列，不改同一逻辑课程的其它星期或单双周片段。
- **整个上课序列**：修改当前锚点及其重复规则，不代表整门课的其它片段。

整门课程的名称、教师、领域和项目只在“编辑课程资料”中统一修改。这样不会再出现详情页选了“仅本次”，后台却修改全部片段的情况。

### 2.3 自定义保护时间的两个入口

“管理保护时间”按系列列出用户创建的保护时间，一条锚点只显示一行；点行或点“编辑”打开预填表单。管理页编辑默认修改整个系列。

从日历上的某次保护时间进入时，重复系列提供“仅本次 / 此次及以后 / 整个系列”；一次性保护时间只显示“编辑这段保护时间”。三种范围都允许修改标题、备注、日期与时间。整个系列还允许修改重复星期和结束日期。

规则生成的睡眠、早餐、午餐、晚餐、固定休息没有 `CalendarEvent` 锚点，日历卡片不显示删除或系列编辑；卡片操作跳转到设置中的长期规则区域。

### 2.4 早餐保护的兼容策略

增加 `ProtectedTimeKind.breakfast`，建议时间为 07:30–08:00。设置页始终显示“早餐保护”一行，既有用户升级后默认关闭，避免安装更新后直接改变已经确认的计划。

首次引导新增早餐开关并默认开启；用户完成引导时才保存早餐规则。旧用户如果主动打开设置并启用早餐，从下一次生成或调整计划开始生效。早餐不与睡眠自动合并；两者重叠时阻止保存并指出冲突。

## 3. 文件与职责

### 新建

- `lib/domain/models/calendar_event_edit.dart`：日历事项的可编辑快照、范围请求、乐观并发 token 与结构化写入结果。
- `lib/domain/models/protected_time_series.dart`：自定义保护时间系列摘要与详情，不暴露 Drift 行。
- `lib/domain/repositories/protected_time_repository.dart`：按锚点读取保护时间系列。
- `lib/features/calendar/courses/course_editor_page.dart`：编辑整门课程资料与上课安排。
- `test/domain/calendar_event_edit_test.dart`：草稿校验与不可变值测试。
- `test/data/protected_time_repository_test.dart`：保护时间系列聚合与排序测试。
- `test/features/calendar/course_editor_page_test.dart`：课程完整编辑表单测试。
- `test/application/protected_time_edit_service_test.dart`：保护时间范围修改、失败原子性与重排记录测试。
- `integration_test/course_and_protection_management_test.dart`：课程、保护时间、早餐端到端回归。

### 修改

- `lib/domain/models/course_series.dart`：补足课程快照、片段周次和修订信息。
- `lib/domain/models/planning_rules.dart`：加入 `breakfast`。
- `lib/domain/repositories/course_write_gateway.dart`：增加课程事务更新命令。
- `lib/domain/repositories/calendar_event_deletion.dart`：改写接口接收完整编辑快照，不再只接收时间和旧标题。
- `lib/application/course_management_service.dart`：课程草稿校验、全窗口冲突预览、过期快照防护和事务写入。
- `lib/application/calendar_service.dart`：统一处理保护时间的单次、以后、整个系列修改。
- `lib/data/repositories/drift_course_series_repository.dart`：返回真实起始周、结束周、频率、星期集合与修订 token。
- `lib/data/repositories/drift_calendar_repository.dart`：实现课程事务更新、保护时间系列查询与完整范围改写。
- `lib/app/backup_assembly.dart`：装配新增只读端口和服务；不改备份格式版本。
- `lib/app/router.dart`：增加课程编辑、保护时间编辑深链并修正返回路径。
- `lib/features/calendar/courses/course_detail_page.dart`：增加“编辑课程”，移除无效范围选择器。
- `lib/features/calendar/courses/course_edit_dialog.dart`：只保留具体课次的范围编辑；不再承担整门课程资料编辑。
- `lib/features/calendar/protected_time/protected_time_list_page.dart`：按系列显示并增加编辑入口。
- `lib/features/calendar/protected_time/protected_time_editor_page.dart`：支持 create/edit 两种模式和三种范围。
- `lib/features/calendar/day_view/day_view_page.dart`：标题与备注可编辑；规则来源保护时间跳设置。
- `lib/features/settings/planning_rules/planning_rules_page.dart`：早餐行、重叠校验与锚点滚动定位。
- `lib/features/onboarding/onboarding_page.dart`：早餐时间和开关。
- `lib/domain/services/default_settings.dart`：只增加早餐建议值的公开常量，不把早餐隐式加入既有默认规则列表。
- `lib/data/database/daos/analytics_dao.dart`、`lib/features/planning/plan_preview_page.dart`：补齐早餐标签的穷尽分支。
- `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md`：登记本文件 §2 的裁定。
- `docs/testing/manual-windows-checklist.md`：加入本文件 §7 的人工场景。
- `docs/release/build-ledger.md`、`docs/release/windows-release.md`、版本一致性测试和版本源文件：仅在全部验收通过、准备新候选时更新。

### 明确不改

- 不新增 `breakfast` 数据库列；规则仍以设置 JSON 保存。
- 不改 `ScheduleEngine`、候选评分、算法版本 13 或 `calendar_events.kind`。
- 不把导入课程复制到新表。
- 不让设置页直接编辑某一天的自定义保护时间。
- 不在本批次改变通知策略；课程/保护时间保存只沿用现有日历写入后的重排原因记录，不新增提醒或重复弹窗。

---

### Task 1: 锁定基线与写出失败证据

**Files:**
- Modify: `test/features/calendar/course_detail_page_test.dart`
- Modify: `test/features/calendar/protected_time_list_page_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/features/settings/planning_rules_page_test.dart`
- Modify: `test/app/course_management_route_test.dart`
- Modify: `test/app/protected_time_route_test.dart`

**Interfaces:**
- Consumes: 当前 `CourseDetailPage`、`ProtectedTimeListPage`、`DayViewPage` 与设置页公开 widget 行为。
- Produces: 后续任务必须转绿的失败测试；本任务不改生产代码。

- [ ] **Step 1: 记录干净基线**

Run:

```powershell
git status --short --branch
flutter analyze --no-pub
flutter test --no-pub
```

Expected: 静态分析 0 问题；记录测试总数和既有失败。当前未跟踪的其它计划文件不得加入本计划提交。

- [ ] **Step 2: 写课程编辑入口失败测试**

新增断言：详情页有“编辑课程”；不存在全局 `course-edit-scope`；点入口进入 `/calendar/courses/<logicalCourseId>/edit`；返回仍回到对应详情。

- [ ] **Step 3: 写保护时间系列清单失败测试**

给同一重复锚点返回三次 occurrence，断言列表只显示一行；行内有带标题的“编辑”语义按钮；固定日程和规则来源保护时间不出现。

- [ ] **Step 4: 写保护时间改名失败测试**

从日视图打开自定义保护时间，断言对话框包含预填标题与备注；把标题改为“早餐”后，回调收到新标题，而不是旧 `item.title`。

- [ ] **Step 5: 写早餐设置失败测试**

断言设置页出现“早餐保护”，初始关闭，建议时间 07:30–08:00；启用并保存后 `ProtectedTimeKind.breakfast` 存在；与睡眠重叠时不调用保存服务。

- [ ] **Step 6: 观察预期失败**

Run:

```powershell
flutter test --no-pub test/features/calendar/course_detail_page_test.dart test/features/calendar/protected_time_list_page_test.dart test/features/calendar/day_view_test.dart test/features/settings/planning_rules_page_test.dart test/app/course_management_route_test.dart test/app/protected_time_route_test.dart
```

Expected: 只因入口、字段、去重和早餐尚不存在而失败；不能出现编译错误以外的无关回归。

- [ ] **Step 7: 提交失败测试**

```powershell
git add test/features/calendar/course_detail_page_test.dart test/features/calendar/protected_time_list_page_test.dart test/features/calendar/day_view_test.dart test/features/settings/planning_rules_page_test.dart test/app/course_management_route_test.dart test/app/protected_time_route_test.dart
git commit -m "test: expose course and protected-time management gaps"
```

---

### Task 2: 建立统一日历编辑契约

**Files:**
- Create: `lib/domain/models/calendar_event_edit.dart`
- Modify: `lib/domain/repositories/calendar_event_deletion.dart`
- Modify: `lib/application/calendar_service.dart`
- Create: `test/domain/calendar_event_edit_test.dart`
- Create: `test/application/calendar_service_test.dart`
- Modify: every fake that implements `CalendarEventDeletion`

**Interfaces:**
- Consumes: `CalendarEvent`、`RecurrenceRule`、`EventEditScope`、`IdGenerator`、`Clock`。
- Produces:
  - `CalendarEventEditDraft`：`title`、`startAtUtc`、`endAtUtc`、`timeZoneId`、`notes`、`location`、`areaId`、`projectId`。
  - `RecurrenceEditDraft`：`weekdays`、`intervalWeeks`、`validFromLocalDate`、`validUntilLocalDate`。
  - `CalendarEditTarget`：`anchorId`、可空 `occurrenceStartUtc`、`EventEditScope`、`expectedUpdatedAtUtc`。
  - `CalendarMutationResult`：`saved`、`savedWithWarning`、`missing`、`stale`、`invalid`、`unsupported`，并携带用户可读错误；`savedWithWarning` 只用于数据库已经提交、但提交后的重排原因回调失败。
  - `CalendarService.updateEvent({required CalendarEditTarget target, required CalendarEventEditDraft event, RecurrenceEditDraft? recurrence})`。

- [ ] **Step 1: 写纯模型失败测试**

覆盖空标题、非 UTC、结束不晚于开始、空时区、无效星期、重复间隔不在 1–52、截止早于开始，以及合法跨午夜区间。草稿创建后集合不可被外部修改。

- [ ] **Step 2: 把仓储端口改成完整草稿**

保留删除方法；把三条改写方法改为接收 `CalendarEventEditDraft`。`replaceSeries` 可接 `RecurrenceEditDraft`；`replaceOccurrence` 禁止改变 recurrence；`replaceFollowingOccurrences` 必须同时接新事件、新规则和两个新 id。

- [ ] **Step 3: 在服务层统一分派范围**

`updateEvent` 根据 `target.scope` 调用对应端口。`singleOccurrence` 与 `followingOccurrences` 缺少 `occurrenceStartUtc` 时返回 `invalid`；端口未装配返回 `unsupported`；只有成功写入后才记录重排原因。数据库提交后的重排原因回调如果抛错，捕获并返回 `savedWithWarning`，不能把已经落库的改动报告成“保存失败”。

- [ ] **Step 4: 保留兼容包装器**

现有 `replaceOccurrence`、`replaceFollowingOccurrences`、`replaceSeries` 暂时保留为 deprecated 包装器，内部构造完整草稿并转到 `updateEvent`。等 Task 8 全部调用方迁移后再删除，避免一次提交让整个仓库无法编译。

- [ ] **Step 5: 验证**

Run:

```powershell
dart format lib/domain/models/calendar_event_edit.dart lib/domain/repositories/calendar_event_deletion.dart lib/application/calendar_service.dart test/domain/calendar_event_edit_test.dart test/application/calendar_service_test.dart
flutter test --no-pub test/domain/calendar_event_edit_test.dart test/application/calendar_service_test.dart
flutter analyze --no-pub
```

Expected: 全部通过，0 个分析问题。

- [ ] **Step 6: 提交**

```powershell
git add lib/domain/models/calendar_event_edit.dart lib/domain/repositories/calendar_event_deletion.dart lib/application/calendar_service.dart test/domain/calendar_event_edit_test.dart test/application/calendar_service_test.dart test
git commit -m "refactor: define complete calendar edit contract"
```

---

### Task 3: 修正课程聚合读模型

**Files:**
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/data/repositories/drift_course_series_repository.dart`
- Modify: `test/data/course_series_repository_test.dart`

**Interfaces:**
- Consumes: `AcademicTerm.firstWeekMonday`、`AcademicWeekCalculator`、`RecurrenceRule`。
- Produces:
  - `CourseSeriesSegment.weekdays: Set<int>`，不再用一个代表 weekday 丢失信息。
  - `CourseSeriesSegment.weekSpan: WeekSpan`。
  - `CourseSeriesSegment.updatedAtUtc: DateTime`。
  - `CourseSeriesDetail.sourceRevisions: Map<EntityId, DateTime>`，供保存时发现过期页面。

- [ ] **Step 1: 写真实周次失败测试**

学期第 1 周从 9 月 7 日开始，规则从第 5 周开始、到第 12 周结束时，读模型必须返回 `startWeek=5`、`endWeek=12`，不能继续写死为 1。

- [ ] **Step 2: 写多星期与单双周失败测试**

规则 weekday 为 `{monday, thursday}` 时两天都保留；间隔 2 且起点为学期第 5 周时返回 odd，第 6 周返回 even。未知学期只允许显示日期范围，不允许伪造“第 1 周开始”。

- [ ] **Step 3: 写确定排序与修订 token 测试**

排序依次比较最早星期、开始分钟、间隔周数、事件 id；`sourceRevisions` 必须覆盖每个锚点且使用数据库 `updated_at_utc`。

- [ ] **Step 4: 实现读模型**

`_weekSpanOf` 用学期第一周周一计算真实 offset；如果规则有效期超过学期总周数，读模型保留原日期并标记 `outsideTerm=true`，编辑页必须提示修正，不能在读取时静默夹紧。

- [ ] **Step 5: 验证与提交**

```powershell
dart format lib/domain/models/course_series.dart lib/data/repositories/drift_course_series_repository.dart test/data/course_series_repository_test.dart
flutter test --no-pub test/data/course_series_repository_test.dart
git add lib/domain/models/course_series.dart lib/data/repositories/drift_course_series_repository.dart test/data/course_series_repository_test.dart
git commit -m "fix: preserve complete imported course schedule data"
```

---

### Task 4: 增加整门课程事务编辑

**Files:**
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/domain/repositories/course_write_gateway.dart`
- Modify: `lib/application/course_management_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/application/course_management_service_test.dart`
- Create: `test/data/course_update_transaction_test.dart`

**Interfaces:**
- Consumes: Task 3 的 `CourseSeriesDetail.sourceRevisions`。
- Produces:
  - `CourseEditDraft`：课程资料、`List<CourseSegmentEditDraft>`、`sourceRevisions`。
  - `CourseSegmentEditDraft`：可空 `anchorEventId`、星期集合、钟点、周次范围、频率。
  - `CourseUpdatePreview`：结构化字段错误、冲突列表、新增/更新/删除片段数、受影响课次数、将删除的全部例外数、是否重写历史日历、草稿指纹。
  - `CourseWriteGateway.replaceCourse({required CourseSeriesDetail original, required CourseEditDraft draft, required DateTime updatedAtUtc}) -> CourseWriteResult`。
  - `CourseManagementService.previewCourseUpdate(...)` 与 `applyCourseUpdate(..., required String previewFingerprint)`。

- [ ] **Step 1: 写草稿校验失败测试**

断言名称必填、至少一行安排、星期非空、`0 <= start < end <= 1440`、周次位于学期 1–totalWeeks、起始周不晚于结束周、单双周起点奇偶正确、项目属于领域。错误按字段 key 返回。

- [ ] **Step 2: 写全学期冲突预览失败测试**

把每条草稿按周次、频率、星期和时区展开到学期真实日期；查询同窗口既有 occurrence；排除本课程旧锚点和例外。固定日程与保护时间为阻断冲突；其它课程和课程自身重叠为警告。测试必须覆盖“代表周不冲突，但第 7 周冲突”。

- [ ] **Step 3: 写预览指纹测试**

指纹包含课程 id、全部字段、排序后的片段及 `sourceRevisions`。预览后改任何字段，旧指纹不能用于保存；纯显示顺序变化不改变指纹。

- [ ] **Step 4: 写事务回滚测试**

模拟更新第二个锚点失败，断言第一个锚点、规则、例外和课程资料全部保持旧值。模拟数据库里任一 `updated_at_utc` 与快照不一致，返回 `stale` 且零写入。

- [ ] **Step 5: 实现课程替换事务**

事务内按 `logicalCourseId + termId` 重新读取并核对 id 与修订时间；更新保留 `sourceKind=timetableImport`、`importBatchId`、`logicalCourseId`、`kind=fixed` 和时区。新增片段由服务生成 event/rule id。删除片段时必须在同一事务内删除该锚点、重复规则及其全部例外；预览未明确标记“将重写本学期历史”或确认指纹不一致时拒绝写入。禁止只删除未来例外却留下孤儿历史例外。

- [ ] **Step 6: 处理教师字段**

全部课程锚点的 `notes` 写入同一个教师值。不得把某一个片段的旧教师覆盖回其它片段；读到片段教师不一致时预览显示“教师信息不一致”，保存后统一。

- [ ] **Step 7: 验证与提交**

```powershell
dart format lib/domain/models/course_series.dart lib/domain/repositories/course_write_gateway.dart lib/application/course_management_service.dart lib/data/repositories/drift_calendar_repository.dart test/application/course_management_service_test.dart test/data/course_update_transaction_test.dart
flutter test --no-pub test/application/course_management_service_test.dart test/data/course_update_transaction_test.dart test/application/course_time_conflict_test.dart test/application/course_time_conflict_preview_test.dart
git add lib/domain/models/course_series.dart lib/domain/repositories/course_write_gateway.dart lib/application/course_management_service.dart lib/data/repositories/drift_calendar_repository.dart test
git commit -m "feat: update imported courses transactionally"
```

---

### Task 5: 完成课程编辑界面与路由

**Files:**
- Create: `lib/features/calendar/courses/course_editor_page.dart`
- Modify: `lib/features/calendar/courses/course_detail_page.dart`
- Modify: `lib/features/calendar/courses/course_edit_dialog.dart`
- Modify: `lib/app/router.dart`
- Create: `test/features/calendar/course_editor_page_test.dart`
- Modify: `test/features/calendar/course_detail_page_test.dart`
- Modify: `test/features/calendar/course_edit_dialog_widget_test.dart`
- Modify: `test/app/course_management_route_test.dart`

**Interfaces:**
- Consumes: Task 4 的 preview/apply API、工作区领域/项目选项、统一日期时间 picker。
- Produces: `/calendar/courses/:logicalCourseId/edit`；成功返回课程详情，取消不写入。

- [ ] **Step 1: 写表单结构测试**

断言资料区包含课程名、教师、地点、领域、项目；安排区逐行包含星期、开始/结束时间、起始/结束周、频率、删除行；底部有“预览更改”和“取消”。新增行复制时区和默认周次，不复制 anchor id。

- [ ] **Step 2: 写领域/项目联动测试**

改变领域后，如果旧项目不属于新领域，立即清空项目并给一句说明；没有项目时可保存；不得创建隐式项目。

- [ ] **Step 3: 写冲突预览测试**

字段有效后先显示影响摘要和冲突。阻断冲突时没有“确认保存”；警告冲突要求用户勾选“我已查看课程冲突”才可保存。任何字段变化立即作废旧预览。

- [ ] **Step 4: 修正课程详情操作**

删除当前页面级 `SegmentedButton<CourseEditScope>`。增加“编辑课程”按钮；“暂停课程”继续说明从今天起生效；“删除课程”仍二次确认。页面加载失败、课程不存在或保存 stale 时都有返回入口。

- [ ] **Step 5: 限定具体课次对话框**

`CourseEditDialog` 改名为具体课次用途或补充明确标题。它只从带 occurrence 的日历卡片打开；范围是单次、此次以后、整个上课序列，并把选择值真正传给 `CalendarService.updateEvent`。

- [ ] **Step 6: 路由与返回行为**

详情页进入编辑页；保存后 `go` 回同一详情并重新加载；取消同样返回详情；直接深链不存在 id 时显示“课程已删除或链接过期”。侧栏保持“日历”选中。

- [ ] **Step 7: 键盘与语义测试**

Tab 顺序为资料字段、安排行、预览、取消；Esc 在无未保存改动时返回，有改动时弹“放弃更改？”；每个删除行按钮语义包含课程名和星期。

- [ ] **Step 8: 验证与提交**

```powershell
dart format lib/features/calendar/courses lib/app/router.dart test/features/calendar/course_editor_page_test.dart test/features/calendar/course_detail_page_test.dart test/features/calendar/course_edit_dialog_widget_test.dart test/app/course_management_route_test.dart
flutter test --no-pub test/features/calendar/course_editor_page_test.dart test/features/calendar/course_detail_page_test.dart test/features/calendar/course_edit_dialog_widget_test.dart test/app/course_management_route_test.dart
git add lib/features/calendar/courses lib/app/router.dart test/features/calendar test/app/course_management_route_test.dart
git commit -m "feat: make imported course data editable"
```

---

### Task 6: 建立保护时间系列读模型

**Files:**
- Create: `lib/domain/models/protected_time_series.dart`
- Create: `lib/domain/repositories/protected_time_repository.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `lib/app/backup_assembly.dart`
- Create: `test/data/protected_time_repository_test.dart`

**Interfaces:**
- Consumes: `calendar_events.kind=protected`、`recurrence_rules`、例外约定。
- Produces:
  - `ProtectedTimeSeriesSummary`：anchor id、标题、首个有效时间、是否重复、星期、结束日期、状态。
  - `ProtectedTimeSeriesDetail`：完整锚点、规则、未来非删除例外数、`updatedAtUtc`。
  - `ProtectedTimeRepository.listSeries({bool includeEnded = false})`。
  - `ProtectedTimeRepository.findSeries(String anchorId)`。

- [ ] **Step 1: 写聚合失败测试**

同一锚点展开 26 次仍只返回一个 summary；一次性保护时间一行；固定日程不出现；规则来源的 `protected:sleep` 不在数据库，因此不出现。

- [ ] **Step 2: 写例外与结束状态测试**

零长度删除例外不形成新系列；正常例外计入 future exception 数；已结束系列默认隐藏，`includeEnded=true` 时显示并标记“已结束”。

- [ ] **Step 3: 写排序测试**

生效中在前、未来在后、已结束最后；同组按下次发生时间、标题、anchor id 排序，保证刷新不跳动。

- [ ] **Step 4: 实现并装配**

直接查询锚点与规则，不通过 180 天 occurrence 展开结果反推系列。页面不得认识 Drift companion。

- [ ] **Step 5: 验证与提交**

```powershell
dart format lib/domain/models/protected_time_series.dart lib/domain/repositories/protected_time_repository.dart lib/data/repositories/drift_calendar_repository.dart lib/app/backup_assembly.dart test/data/protected_time_repository_test.dart
flutter test --no-pub test/data/protected_time_repository_test.dart test/application/backup_service_test.dart
git add lib/domain/models/protected_time_series.dart lib/domain/repositories/protected_time_repository.dart lib/data/repositories/drift_calendar_repository.dart lib/app/backup_assembly.dart test/data/protected_time_repository_test.dart
git commit -m "feat: expose protected-time series for management"
```

---

### Task 7: 实现保护时间完整编辑服务

**Files:**
- Modify: `lib/application/calendar_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Create: `test/application/protected_time_edit_service_test.dart`
- Modify: `test/data/calendar_event_deletion_test.dart`
- Modify: `test/application/protected_time_replan_events_test.dart`

**Interfaces:**
- Consumes: Task 2 的统一编辑契约、Task 6 的系列详情。
- Produces: 自定义保护时间单次、此次以后、整个系列的完整编辑；返回 `CalendarMutationResult`。

- [ ] **Step 1: 写单次改名失败测试**

重复保护时间的某一次从“午休”改成“看医生”，只产生一条例外；原系列标题不变；该日显示新标题和新备注，其它星期仍显示“午休”。

- [ ] **Step 2: 写此次以后失败测试**

旧规则在所选本地日期前一天结束，新规则从所选日期开始；新锚点保留 `kind=protected`、时区、领域/项目空值和新标题。拆分发生在 DST 周时仍保持选择的本地钟点。

- [ ] **Step 3: 写整个系列失败测试**

更新锚点、规则、未来正常例外的标题与备注；过去例外不变；未来删除例外继续保持删除语义。改变重复星期时，先返回会清除的未来正常例外数量，用户确认后才提交。

- [ ] **Step 4: 写 stale 与事务回滚测试**

`expectedUpdatedAtUtc` 不匹配时返回 stale；事务中规则更新失败时锚点和例外全部不变。失败不发重排事件。

- [ ] **Step 5: 重排原因只记一次**

成功后发一条“保护时间单次改写 / 本次及以后改写 / 系列改写”；不得显示“固定日程改写”，也不得因为更新锚点和例外而重复记多条。

- [ ] **Step 6: 验证与提交**

```powershell
dart format lib/application/calendar_service.dart lib/data/repositories/drift_calendar_repository.dart test/application/protected_time_edit_service_test.dart test/data/calendar_event_deletion_test.dart test/application/protected_time_replan_events_test.dart
flutter test --no-pub test/application/protected_time_edit_service_test.dart test/data/calendar_event_deletion_test.dart test/application/protected_time_replan_events_test.dart
git add lib/application/calendar_service.dart lib/data/repositories/drift_calendar_repository.dart test/application/protected_time_edit_service_test.dart test/data/calendar_event_deletion_test.dart test/application/protected_time_replan_events_test.dart
git commit -m "feat: edit protected time without recreating it"
```

---

### Task 8: 完成保护时间管理页与编辑器

**Files:**
- Modify: `lib/features/calendar/protected_time/protected_time_list_page.dart`
- Modify: `lib/features/calendar/protected_time/protected_time_editor_page.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/features/calendar/protected_time_list_page_test.dart`
- Modify: `test/features/calendar/protected_time_editor_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/app/protected_time_route_test.dart`

**Interfaces:**
- Consumes: Task 6 的读模型和 Task 7 的编辑服务。
- Produces:
  - `/calendar/protected/:anchorId/edit`：管理页整个系列编辑。
  - 日历 occurrence 编辑请求：带 `anchorId`、`occurrenceStartUtc` 和 scope。
  - `ProtectedTimeEditorMode.create` / `editSeries` / `editOccurrence`。

- [ ] **Step 1: 把编辑器改为显式模式**

create 模式使用“新建保护时间”和默认标题；edit 模式使用“编辑「标题」”，所有字段从详情预填。编辑保存调用更新 API，绝不能走 `CalendarService.save()` 生成新 id。

- [ ] **Step 2: 完成管理列表**

每个系列一行，显示标题、重复摘要、下次时间和状态；整行点击与编辑图标进入同一编辑路由；删除仍二次确认。增加“显示已结束”开关，默认关闭。

- [ ] **Step 3: 完成日视图范围编辑**

自定义保护时间显示编辑/删除；规则来源保护时间显示“去设置”。编辑对话框加入标题、备注，并根据是否重复显示范围。一次性事项不显示三个同义选项。

- [ ] **Step 4: 修正保存后的返回路径**

从管理页进入，保存/取消回管理页；从日视图进入，保存/取消回原日期；从全局新建进入，保存后回管理页而不是跳到无关的今日页。

- [ ] **Step 5: 替换误导测试**

删除“传 initialNotes 再创建新事项也算编辑”的旧断言，改为断言原 event id 不变、记录数不增加、标题和备注已更新。

- [ ] **Step 6: 验证与提交**

```powershell
dart format lib/features/calendar/protected_time lib/features/calendar/day_view/day_view_page.dart lib/app/router.dart test/features/calendar/protected_time_list_page_test.dart test/features/calendar/protected_time_editor_test.dart test/features/calendar/day_view_test.dart test/app/protected_time_route_test.dart
flutter test --no-pub test/features/calendar/protected_time_list_page_test.dart test/features/calendar/protected_time_editor_test.dart test/features/calendar/day_view_test.dart test/app/protected_time_route_test.dart
git add lib/features/calendar/protected_time lib/features/calendar/day_view/day_view_page.dart lib/app/router.dart test/features/calendar test/app/protected_time_route_test.dart
git commit -m "feat: manage and rename custom protected time"
```

---

### Task 9: 增加早餐长期保护规则

**Files:**
- Modify: `lib/domain/models/planning_rules.dart`
- Modify: `lib/domain/services/default_settings.dart`
- Modify: `lib/features/settings/planning_rules/planning_rules_page.dart`
- Modify: `lib/features/onboarding/onboarding_page.dart`
- Modify: `lib/data/database/daos/analytics_dao.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `test/features/settings/planning_rules_page_test.dart`
- Modify: `test/features/onboarding/onboarding_page_test.dart`
- Modify: `test/scheduling/protected_time_expander_test.dart`
- Modify: `test/application/settings_service_test.dart`
- Modify: `test/data/analytics_dao_test.dart`

**Interfaces:**
- Consumes: `PlanningRules.protectedTimes` 的现有 JSON 序列化与 protected window 展开器。
- Produces: `ProtectedTimeKind.breakfast`；公开建议范围常量 `DefaultSettings.breakfastStartMinute=450`、`breakfastEndMinute=480`。

- [ ] **Step 1: 写枚举与旧 JSON 兼容测试**

旧 JSON 没有 breakfast 时正常读取且早餐关闭；新 JSON 可往返 breakfast；未知 kind 继续按现有错误策略处理，不能变成早餐。

- [ ] **Step 2: 写设置页测试**

早餐位于睡眠之后、午餐之前；默认关闭但字段显示 07:30–08:00；启用后保存。关闭再保存时从 `protectedTimes` 移除 breakfast，不留下 enabled=false 的重复表示。

- [ ] **Step 3: 增加保护窗口重叠校验**

保存前把睡眠、早餐、午餐、晚餐、固定休息按工作日/周末展开到 48 小时轴；任意交集返回例如“早餐保护 07:30–08:00 与睡眠 23:30–08:00 重叠 30 分钟”。首尾相接不算重叠。

- [ ] **Step 4: 写首次引导测试**

早餐开关默认开启、时间 07:30–08:00；完成引导会保存 breakfast；跳过引导不写规则。已有用户进入普通设置不会被自动开启。

- [ ] **Step 5: 补齐所有穷尽分支**

统计标签和计划预览统一显示“早餐”；禁止出现 `breakfast` 英文枚举名。搜索 `switch (kind)` 与 `ProtectedTimeKind.values`，逐处验证排序和文案。

- [ ] **Step 6: 排程与统计测试**

启用早餐后任务不能落进该区间；禁用后可用。早餐只计保护容量，不计固定日程投入；与午餐/晚餐同样使用本地日期和跨午夜裁剪规则。

- [ ] **Step 7: 验证与提交**

```powershell
dart format lib/domain/models/planning_rules.dart lib/domain/services/default_settings.dart lib/features/settings/planning_rules/planning_rules_page.dart lib/features/onboarding/onboarding_page.dart lib/data/database/daos/analytics_dao.dart lib/features/planning/plan_preview_page.dart test
flutter test --no-pub test/features/settings/planning_rules_page_test.dart test/features/onboarding/onboarding_page_test.dart test/scheduling/protected_time_expander_test.dart test/application/settings_service_test.dart test/data/analytics_dao_test.dart
git add lib/domain/models/planning_rules.dart lib/domain/services/default_settings.dart lib/features/settings/planning_rules/planning_rules_page.dart lib/features/onboarding/onboarding_page.dart lib/data/database/daos/analytics_dao.dart lib/features/planning/plan_preview_page.dart test
git commit -m "feat: add opt-in breakfast protection"
```

---

### Task 10: 回归、备份和兼容性守卫

**Files:**
- Modify: `test/application/backup_service_test.dart`
- Modify: `test/drift/app_database/schema_migration_test.dart`
- Modify: `test/drift/app_database/real_database_migration_test.dart`
- Modify: `test/app/app_smoke_test.dart`
- Modify: `test/app/accessibility_semantics_test.dart`
- Create: `integration_test/course_and_protection_management_test.dart`

**Interfaces:**
- Consumes: Tasks 2–9 的最终接口。
- Produces: 数据兼容、可访问性和用户主路径证据。

- [ ] **Step 1: 证明 schema 不变**

断言数据库 schemaVersion 仍为 9，Drift schema diff 为空。旧 v9 数据库打开后课程和保护时间记录数、id、kind、规则与例外不变。

- [ ] **Step 2: 备份往返**

构造多片段课程、改名后的重复保护时间和 breakfast 设置，导出再恢复；断言逻辑课程 id、锚点、规则、例外、标题、教师、领域/项目、早餐启用状态全部一致。

- [ ] **Step 3: 集成课程路径**

导入一门单双周课程，管理页改名称、教师、地点和其中一条安排；预览；保存；重启应用；课程列表、七日历和日视图显示一致。另建同名不同 id 课程，断言未被修改。

- [ ] **Step 4: 集成保护时间路径**

创建每周二“健身”保护时间；管理页只显示一行；改名为“游泳”并调整时间；重启后仍保留；排程不能占用；从某周只改一次为“体检”，其它周仍叫“游泳”。

- [ ] **Step 5: 集成早餐路径**

老设置升级后早餐关闭；手动启用后预览出现“早餐 07:30–08:00”；任务不进入；关闭后下一次预览恢复可用。与睡眠重叠时保存被拦截且旧规则不变。

- [ ] **Step 6: 可访问性**

断言课程编辑、保护时间编辑和早餐开关的名称、角色、状态与错误可读；键盘可到达所有操作；范围选项只出现一次语义节点。

- [ ] **Step 7: 运行全量验证**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub integration_test/course_and_protection_management_test.dart -d windows
```

Expected: 格式检查零改动，分析 0 问题，全量测试与 Windows 集成测试全部通过。必须记录准确通过数量，不能沿用旧台账的 2068。

- [ ] **Step 8: 提交**

```powershell
git add test/application/backup_service_test.dart test/drift/app_database/schema_migration_test.dart test/drift/app_database/real_database_migration_test.dart test/app/app_smoke_test.dart test/app/accessibility_semantics_test.dart integration_test/course_and_protection_management_test.dart
git commit -m "test: verify course and protection management end to end"
```

---

### Task 11: 文档、人工验收与候选发布

**Files:**
- Modify: `docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md`
- Modify: `docs/testing/manual-windows-checklist.md`
- Modify: `docs/release/windows-release.md`
- Modify: `docs/release/build-ledger.md`
- Modify: `docs/release/version-policy.md` only if its current-value section still points at the superseded candidate
- Modify: `pubspec.yaml`
- Modify: `lib/app/backup_assembly.dart`
- Modify: `test/app/version_consistency_test.dart`
- Create: `docs/release/1.8.0-build44-user-guide.md`

**Interfaces:**
- Consumes: Tasks 1–10 的测试证据和实际用户界面。
- Produces: 可安装候选及可审计台账；不自动宣称正式发布。

- [ ] **Step 1: 更新规范与人工清单**

把本文件 §2 写回设计规范；人工清单加入 §7 全部场景，实际结果初始留空，不能预先填写“通过”。

- [ ] **Step 2: 执行 Windows 人工验收**

使用从 Release 构建安装的应用，不用 `flutter run`。逐项记录操作、期望、实际、截图路径、执行人和时间；任何失败回到对应 Task 修复并重新跑全量测试。

- [ ] **Step 3: 冻结候选版本**

仅在源码冻结后，把版本改为 `1.8.0+44`，MSIX 改为 `1.8.0.1`，备份清单版本与测试同步。若 `+44` 已被其它构建占用，读取台账后使用下一个未使用的全局 build；MSIX revision 同步递增。

- [ ] **Step 4: 构建交付物**

严格按 `docs/release/windows-release.md` 构建 Release、便携目录、ZIP 和已签名 MSIX。关闭已安装旧进程后做原位升级；验证已安装 `data/app.so` 的 SHA-256 与候选包一致。

- [ ] **Step 5: 检查隐私和完整性**

ZIP 与 MSIX 不得包含 `user-data`、SQLite、`.pfx`、`.key`、`.pem`、日志、诊断输出、测试 exe 或个人课表图片。`.cer` 仅为公钥证书，可以随安装说明交付。

- [ ] **Step 6: 更新台账**

记录 EXE、app.so、ZIP、MSIX、证书哈希，测试总数、安装覆盖结果和人工清单结论。人工验收完成但 GitHub Release 未发布时，状态仍写“候选构建”。

- [ ] **Step 7: 最终提交**

```powershell
git add docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md docs/testing/manual-windows-checklist.md docs/release/windows-release.md docs/release/build-ledger.md docs/release/version-policy.md docs/release/1.8.0-build44-user-guide.md pubspec.yaml lib/app/backup_assembly.dart test/app/version_consistency_test.dart
git commit -m "release: prepare corrected 1.8.0 candidate"
```

不要用 `git add -A`；如果实际 build 不是 44，命令中的文件名必须改为真实文件名。

---

## 4. 禁止实现方式

- 不允许在课程页面按标题批量更新；唯一聚合键是 `logicalCourseId`。
- 不允许从未来 180 天 occurrence 列表反推保护系列；这会制造重复行并漏掉 180 天后的系列。
- 不允许用“删除旧记录再新建”假装编辑；这会改变 id、丢例外并让通知与重排记录重复。
- 不允许把 breakfast 当字符串塞进 UI 而不增加领域枚举；统计、预览和序列化会因此分叉。
- 不允许在 UI 推测冲突；服务层必须根据完整学期 occurrence 和保护窗口返回事实。
- 不允许保存前自动夹紧周次、自动更换单双周或静默调整重叠保护时间。
- 不允许为了让测试通过而删除 stale 检查、事务回滚断言或同名课程场景。
- 不允许多个代理同时改 `router.dart`、`calendar_service.dart`、`drift_calendar_repository.dart` 或设置序列化。

## 5. 失败处理与原子性

| 失败 | 用户看到 | 数据结果 |
| --- | --- | --- |
| 字段非法 | 对应字段下的中文错误；底部汇总同一错误一次 | 零写入 |
| 硬冲突 | 冲突事项标题、日期时间和类型；返回修改 | 零写入 |
| 页面数据过期 | “课程/保护时间已在别处变化，请重新打开” | 零写入并重新加载 |
| 目标已删除 | “找不到该事项，它可能已删除”并提供返回 | 零写入 |
| Drift 事务异常 | “保存失败，原内容未改变” | 整个事务回滚 |
| 写入后重排原因回调抛错 | “内容已保存，但变更记录失败”；不得谎称保存失败 | 数据已保存；返回 `savedWithWarning`，页面重新加载真实数据 |

## 6. 测试覆盖表

| 需求 | 单元/仓储 | Widget/路由 | Integration | 人工 |
| --- | --- | --- | --- | --- |
| 课程资料可改 | Task 3、4 | Task 5 | Task 10 | §7.1 |
| 多片段/单双周不误改 | Task 3、4 | Task 5 | Task 10 | §7.2 |
| 课程范围真实生效 | Task 2、4 | Task 5 | Task 10 | §7.3 |
| 保护系列只显示一次 | Task 6 | Task 8 | Task 10 | §7.4 |
| 自定义保护时间可改名 | Task 7 | Task 8 | Task 10 | §7.5 |
| 保护时间三种范围 | Task 7 | Task 8 | Task 10 | §7.6 |
| 早餐可配置且老用户不被强开 | Task 9 | Task 9 | Task 10 | §7.7 |
| 重叠保护被拦截 | Task 9 | Task 9 | Task 10 | §7.8 |
| 备份/升级无损 | Task 10 | Task 10 | Task 10 | §7.9 |
| 键盘与语义 | Task 10 | Task 10 | Task 10 | §7.10 |

## 7. 人工验收场景

### 7.1 修改课程资料

导入课程后，从“日历 → 管理课程”打开课程，修改名称、教师、地点、领域和项目。预览无冲突后保存；课程列表、七日历、日视图、详情页一致显示新值，重启后不恢复旧值。

### 7.2 修改多片段课程

使用一门含周一单周、周四双周的课程，只修改周四片段时间。周一片段保持原位；星期、单双周和总周数都不改变；同名但不同课程 id 的记录不受影响。

### 7.3 修改具体课次范围

从日视图选一节重复课程，分别验证仅本次、此次及以后、整个上课序列。每次修改前备份测试数据；结果必须与范围说明逐次对应，不能改到整门课程的其它片段。

### 7.4 管理重复保护时间

创建持续 26 周的“每周二健身”。管理页只出现一行，摘要写清星期、时间和结束日期；不能出现 26 行。

### 7.5 改名

把“健身”改为“游泳”，保存后管理页和未来日历统一显示“游泳”，数据库记录数不增加，anchor id 不变。

### 7.6 范围修改

从其中一周把标题改为“体检”：仅本周显示“体检”；选择此次及以后时，之前仍为旧标题、之后为新标题；选择整个系列时全部未来发生一致。

### 7.7 早餐

升级旧数据库后打开设置，早餐行存在但关闭。启用 07:30–08:00 后生成计划，任务不进入该区间；关闭后重新生成，该区间恢复可用。

### 7.8 重叠保护

把睡眠设为 23:30–08:00，再启用早餐 07:30–08:00。保存被拦截并指出重叠 30 分钟；退出页面后旧设置仍完整。

### 7.9 原位升级与数据保留

从已安装的 `1.8.0.0` 候选升级到修复候选；课程、任务、保护时间、周期目标、设置和备份仍可读。安装前后数据库文件指纹可变化，但业务记录计数和抽样字段一致。

### 7.10 键盘与屏幕阅读器

不用鼠标完成课程编辑、保护时间改名和早餐启用。Narrator 能读出字段名、当前值、范围、错误与保存结果；Esc 不会无提示丢弃更改。

## 8. 完成定义

以下条件缺一项都不能写“已完成”：

- Task 1–11 的 checkbox 全部有对应提交或验收证据；
- 格式检查零改动，静态分析 0 问题，全量测试与 Windows 集成测试通过；
- schema 仍为 v9，算法版本仍为 13，旧备份往返成功；
- 课程资料、课程具体范围、自定义保护时间改名、保护时间范围、早餐与重叠校验均通过人工验收；
- 修复候选可以覆盖安装，已安装 `app.so` 与交付包哈希一致；
- 交付包完整且不含隐私文件；
- GitHub Release 真正创建并附带安装包、校验值和说明后，台账才可把状态改为“已发布”。

## 9. 执行顺序

严格串行执行：

```text
Task 1 失败证据
  → Task 2 日历编辑契约
  → Task 3 课程读模型
  → Task 4 课程事务写入
  → Task 5 课程界面
  → Task 6 保护系列读模型
  → Task 7 保护编辑服务
  → Task 8 保护界面
  → Task 9 早餐规则
  → Task 10 全链路回归
  → Task 11 人工验收与候选构建
```

Task 3 与 Task 6 看似可以并行，但它们都会触及 `drift_calendar_repository.dart`、组合根和测试替身；本计划禁止并行，避免再次出现接口一半新、一半旧的状态。
