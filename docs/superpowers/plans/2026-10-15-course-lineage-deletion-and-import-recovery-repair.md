# Course Editing Integrity, Lineage, Deletion, and Import Recovery Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. **Do not use parallel agents for this plan.** Tasks 1–11 share the same calendar mutation, course lineage, Drift transaction, import-batch state, route, and migration contracts. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完整修复从“修改课程时间后课程变成未命名固定日程”开始，到后续审计发现的全部课程一致性问题：任何时间编辑都不得覆盖标题、教师、地点、领域、项目、时区或课程身份；多片段课程必须原子保存且按规则时区保持正确星期；已经受旧缺陷影响的数据必须可识别、可解释、可人工修复或通过原课表恢复；新增片段继承原导入来源；删课后可以从同一张课表恢复；删除不留下孤儿重复规则；缩短周次时清理失效的逐次例外；用户在提示条消失或重启后仍能找到导入记录并撤销。

**Architecture:** 先移除所有只传时间、靠占位标题与默认时区补字段的旧改写接口；日历单次/以后/系列改写改为“只提交用户实际修改的字段，仓储在事务内从权威锚点保留其它字段”，整门课程时间修改统一进入现有课程快照预览与 `replaceCourseSeries()` 单事务，不再逐片段循环写。随后把“课程来自哪个导入批次”作为服务层解析、仓储层强制执行的系列级来源；把“删除课程、删除例外、回收无引用规则、标记批次已部分删除”放进同一个 Drift 事务；把例外是否仍属于新规则收敛为与展开器共用的纯函数；把批次列表和回滚能力加入课表导入端口，并提供可持续访问的导入记录页。数据库由 v9 升至 v10，只扩充导入批次状态约束，不改现有主键、外键或用户业务字段。

**Tech Stack:** Flutter / Dart、GoRouter、Drift / SQLite、现有 `CourseManagementService`、`TimetableImportService`、`RecurrenceExpander`、IANA 时区、Flutter widget/integration tests、Windows x64。

**Spec:** `docs/superpowers/plans/2026-10-12-course-and-protected-time-management-repair.md` §2、Task 2、Task 4、Task 5、Task 9；`docs/superpowers/specs/2026-10-11-core-workflow-repair-design.md` §9、§10、§14。本文件是从课程时间修改事故开始的总收口方案，不只是五项后续补丁；课程改写语义、来源、删除事务、批次状态、例外清理和持久撤销入口发生冲突时，以本文件 §2 的冻结决策和 §15 的验收矩阵为准。

## Global Constraints

- **文档状态：实施方案已写定，专项代码尚未按本文件完整实施。** 代码中已经存在日视图完整草稿、课程编辑页和部分回归测试，不代表本文件列出的 10 个根因组、24 个原子问题与接口缺口已经闭环。
- 本轮只新增这份 Markdown 文件，不修改生产代码、测试、数据库、版本号、发布记录或安装包。
- 实施时必须由一个实现者、一个工作树按 Task 1 → Task 11 串行执行。禁止多个代理同时修改 `calendar_service.dart`、`course_management_service.dart`、`drift_calendar_repository.dart`、`drift_timetable_import_repository.dart`、`router.dart` 或数据库迁移文件。
- 当前实施工作树是 `G:\best-planing\.worktrees\native-implementation`，分支是 `feature/native-implementation`。执行前先记录 `git status --short`；不得 `reset --hard`、`clean`、覆盖或删除用户已有改动。
- 每个任务只暂存该任务列出的文件。禁止使用无筛选的 `git add -A` 或 `git add .`。
- 不修改课程标题、教师、地点、领域、项目、逻辑课程 id、原导入文件哈希和原导入时间的含义。
- 不把“同标题”当作同一门课。课程聚合、删除和整体编辑始终以 `logicalCourseId` 为边界。
- 不把 `importBatchId` 当作界面可编辑字段。它是来源事实，只能由服务根据当前数据库详情解析，页面和请求体不得伪造。
- 不允许任何“只改时间”接口用默认值补齐未展示字段。未被当前界面编辑的字段必须从事务内重新读取的权威锚点保留；需要清空字段时必须使用显式的 clear 语义。
- 不允许生产路径继续调用 `CalendarService.replaceOccurrence()`、`replaceFollowingOccurrences()`、`replaceSeries()`、`rememberTitleForLegacyWrappers()` 或 `rememberTimeZoneForLegacyWrappers()`。迁移完成后必须删除这些接口、缓存以及 `_fallbackTitle` / `_fallbackTimeZoneId`。
- 整门课程的多片段变更只允许一次事务提交。不得循环调用单锚点 API 后汇总失败；否则后一个片段失败会留下前一个片段已经修改的半完成状态。
- 所有跨表写入必须在单个 Drift 事务里完成。任一步失败时，锚点、例外、重复规则和批次状态全部保持原样。
- 外键必须保持开启。不得为绕过删除顺序或测试夹具问题关闭生产外键。
- 所有持久化时刻继续使用 UTC；周次、星期和规则成员判定使用规则自己的 IANA 时区。禁止用设备默认时区或固定 24 小时替代本地日历日。
- 时间范围仍使用半开区间 `[startUtc, endUtc)`；日期有效期是闭区间 `[validFromLocalDate, validUntilLocalDate]`。
- 页面不得显示 UUID、数据库异常、`partiallyDeleted` 等内部枚举值。错误必须指出课程或文件名、发生了什么以及用户可以做什么。
- 不新增联网权限，不上传课表、课程标题、教师、地点、图片哈希或数据库内容，不把这些内容写入普通日志、测试夹具或发布产物。
- 迁移前继续使用现有自动备份路径。迁移失败必须保留 v9 数据库并阻止应用在半迁移库上继续启动。
- `2026-10-12-course-and-protected-time-management-repair.md` 中“schema 保持 v9”的限制只对当时那批实现成立；本专项因需要可审计的部分删除状态，明确以 v10 取代该限制。除此之外不得顺带改变表结构。
- 本计划不改变排程算法、算法版本、任务候选、保护时间、通知、托盘、统计或更新器。
- 本计划不自动修改 `pubspec.yaml` 的应用版本、不创建 tag、不创建 GitHub Release、不上传构建产物。版本和发布授权另行处理。
- 每项生产修改先写能因目标缺陷失败的测试。编译失败、测试夹具错误、环境启动错误和无输出退出都不算有效红灯。
- 若 Windows 测试出现 `0xc0000142`、`-1073741502` 或重复弹窗，只记录一次并停止重试；不得把“未执行”写成 PASS。
- 不能承诺“零缺陷”。完成声明只能依据 §15 的门禁、真实测试输出和人工记录；没有证据的项目一律记为 NOT VERIFIED。

## Review Focus

- 从课程详情修改时间后，标题、教师、地点、领域、项目、`sourceKind`、`importBatchId`、`logicalCourseId`、事件类别和规则时区逐值不变；不得出现“未命名事项”“无领域固定日程”或 `UTC` 回退。
- 从日视图修改标题、备注、日期或时间时，界面没有展示的地点、领域、项目、类别、来源与课程身份必须保留；不能把“完整草稿”误当成“所有默认值都可以覆盖”。
- 多片段课程任何一段写入失败时全部回滚；成功时每段保留自己的星期。Asia/Shanghai 的 00:00–07:59、跨日和夏令时区必须按规则本地日换算，不能用 UTC `.weekday` 推算。
- 已经被旧版写成“未命名事项”或事件时区与规则时区不一致的导入课程必须显示结构化完整性提示；系统不得猜回原课程名、教师、地点或领域。
- 受损课程必须提供两条真实恢复路径：手工补全并预览保存，或备份后删除该课程、再从原课表重新导入。恢复前必须明确哪些逐次调整会丢失。
- 给一门导入课程新增星期或周次片段后，新锚点必须与原课程共享 `importBatchId`，继续出现在原学期，并能随原批次撤销。
- 存量数据若同一逻辑课程只有一个非空批次 id、另有若干空批次 id，应被判定为可修复混合来源；下次成功保存时统一为该批次。
- 同一逻辑课程若出现两个不同的非空批次 id，禁止猜测来源；保存应被阻止并显示数据一致性错误。
- 删除一门课时，例外先删、锚点后删、最后只删除已无锚点引用的重复规则；批次状态与上述删除必须同事务提交。
- 课表批次被部分删课后，再导入同一图片应进入正常预览；仍存在的课程默认跳过，被删课程可以恢复，不重复生成剩余课程。
- 缩短课程有效期、改星期或改单双周后，已经不再对应新规则的逐次例外必须在预览中计数，并在确认保存时删除。
- 预览计数和实际删除数必须来自同一成员判定函数；不能由页面按日期猜测。
- 提示条中的“撤销本次导入”继续保留为快捷入口；导入记录页是持久入口，两者必须调用同一套检查与回滚服务。
- 重启后导入记录仍可见；滚回已修改批次前必须继续要求二次确认，不得因新增页面绕过保护检查。
- v9 → v10 迁移只改变 `timetable_import_batches.status` 的允许值；其它表和业务字段逐值不变。

---

## 1. 已确认的 10 个根因组、24 个原子问题与代码证据

### 1.1 课程“改时间”仍走会覆盖资料的废弃接口

`CourseDetailPage._editTime()` 调用 `CourseManagementService.editWholeCourse()`；后者逐片段调用已经标记 `@Deprecated` 的 `CalendarService.replaceSeries()`：

- `lib/features/calendar/courses/course_detail_page.dart:143-187`；
- `lib/application/course_management_service.dart:343-395`；
- `lib/application/calendar_service.dart:145-170`。

该旧接口只接收锚点 id 与新起止时间。为满足完整草稿构造，它把未提供字段补成：

- 标题：缓存不存在时为 `未命名事项`；
- 时区：缓存不存在时为 `UTC`；
- 备注、地点：空字符串；
- 领域、项目：`null`；
- 类别：默认 `fixed`。

仓储 `_appliedTo()` 会保留 `sourceKind`、`importBatchId` 与 `logicalCourseId`，但会用草稿覆盖上述可编辑资料。因此用户只是改钟点，也可能得到“未命名事项”、教师和地点消失、领域归属清空、分类显示成“无领域固定日程”、事件时区与重复规则时区不一致。证据位置：

- `lib/domain/models/calendar_event_edit.dart:30-66`；
- `lib/data/repositories/drift_calendar_repository.dart:267-326`。

### 1.2 日视图的新改写路径仍会清空未展示字段

日视图已经不再调用旧包装器，但 `_editOccurrence()` 只从 `ScheduleViewItem` 构造标题、备注、时间和类别；`location`、`projectId` 未进入视图模型，`areaId` 也没有放进改写草稿：

- `lib/features/calendar/day_view/day_view_page.dart:283-340`；
- `lib/features/calendar/week_view/schedule_view_models.dart:83-195`；
- `lib/app/router.dart:1301-1349`。

`CalendarEventEditDraft` 对缺失字段使用空值，而 `_appliedTo()` 将这些空值写回锚点或例外。因此“把表单参数列全”并不等于保留了用户没有编辑的资料；当前契约无法区分“保持原值”和“明确清空”。

### 1.3 多片段课程时间修改不是原子操作

`CourseManagementService.editWholeCourse()` 对每个片段循环调用 `replaceSeries()`，最后才汇总失败 id。第一段提交后第二段失败时，第一段不会回滚，用户收到“部分没改成功”，数据库却已经处于一门课程多个片段版本不一致的状态。这个行为违反现有整门课程快照编辑的单事务约束，也会让后续冲突预览、学期聚合和撤销范围难以解释。

### 1.4 星期映射使用 UTC 日期，早晨课程可能落错本地星期

课程详情用一个固定的 `2026-01-05` 本地日期承载新钟点，再转换为 UTC；服务的 `_mapToSegmentDay()` 却读取 `newStartUtc.weekday`，并由 `_addLocalDays()` 直接操作 UTC 年月日：

- `lib/features/calendar/courses/course_detail_page.dart:158-185`；
- `lib/application/course_management_service.dart:148-176`。

现有测试明确使用 UTC+0，未覆盖 Asia/Shanghai 的 00:00–07:59 或夏令时边界：`test/application/course_whole_time_mapping_test.dart:35-137`。本地周一 07:30 在 UTC 中仍是周日，当前算法可能多移或少移一天。即使移除快捷“改时间”入口，也必须留下时区回归测试，防止相同错误在课程编辑预览中重现。

### 1.5 已受损课程没有识别与恢复路径

导入批次只保存源文件名、图片哈希、计数和时间，不保存 OCR 后的原课程资料：`lib/data/database/tables/planner_tables.dart:169-181`。一旦旧接口把课程名、教师、地点或领域覆盖，数据库不能可靠推回原值。当前页面也没有提示“事件时区与规则时区不一致”或“导入课程标题为旧版占位值”，用户只能把损坏数据当成正常课程继续保存。

本计划不得宣称可以自动恢复不存在的数据；必须提供可验证的手工修复与删除后重导入流程。

### 1.6 新增课程片段丢失导入来源和学期归属

`DriftCalendarRepository.replaceCourseSeries()` 在复用既有锚点时保留 `sourceKind` 与 `importBatchId`，但新增锚点没有 `existingRow`，会写成：

- `sourceKind = manual`；
- `importBatchId = null`。

证据位置：

- `lib/data/repositories/drift_calendar_repository.dart:745-849`；
- 当前来源赋值在 `lib/data/repositories/drift_calendar_repository.dart:823-832`。

课程的学期不是存在 `calendar_events` 上，而是通过 `calendar_events.import_batch_id → timetable_import_batches.term_id` 反查：

- `lib/data/repositories/drift_course_series_repository.dart:144-173`；
- 摘要当前取排序后第一条的 `termId` 和 `importBatchId`：`lib/data/repositories/drift_course_series_repository.dart:181-209`。

因此同一门课会出现混合来源。若新增片段排在摘要第一条，它还可能使课程从当前学期列表消失；按原批次撤销时，该新增片段也不会被删除。

### 1.7 删除课程后，同一课表图片仍被批次哈希拦截

`CourseManagementService.deleteCourse()` 只把锚点 id 交给课程写网关：

- `lib/application/course_management_service.dart:539-560`。

当前删除事务只删例外和锚点，不改变导入批次：

- `lib/data/repositories/drift_calendar_repository.dart:711-729`。

再次导入时，仓储只检查“同学期 + 同图片哈希 + 状态 committed”，没有检查该批次内容是否已被用户删除：

- `lib/data/repositories/drift_timetable_import_repository.dart:15-29`。

结果是课已经不存在，但旧批次仍被当作完整导入，用户无法用原图片恢复。

### 1.8 删除课程留下孤儿重复规则

课程删除事务删除：

1. `calendar_events.exception_of_id` 指向锚点的例外行；
2. 锚点行。

它没有删除锚点引用的 `recurrence_rules`。证据：`lib/data/repositories/drift_calendar_repository.dart:711-729`。

同仓库的整体替换路径和导入回滚路径会删除规则：

- `replaceCourseSeries()`：`lib/data/repositories/drift_calendar_repository.dart:768-790`；
- `rollback()`：`lib/data/repositories/drift_timetable_import_repository.dart:207-225`。

两条删除语义不一致，长期会积累无锚点引用的规则，并使数据完整性检查与备份审计出现噪声。

### 1.9 缩短规则后，保留锚点名下的失效例外不会被清理

`CourseManagementService._matchSegment()` 只按星期集合与 `intervalWeeks` 匹配，并优先相同开始时间：

- `lib/application/course_management_service.dart:752` 起。

因此缩短周次或移动有效日期通常会复用原锚点。当前 `replaceCourseSeries()` 只删除“被移除锚点”的例外，不检查“保留锚点”的例外是否仍属于新规则：

- `lib/data/repositories/drift_calendar_repository.dart:768-790`。

失效例外会留在库中。以后再次扩展规则时，它可能重新生效，形成用户没有预期的“复活”。

### 1.10 撤销导入只有短暂提示条入口

导入完成后，路由只显示带动作的提示条：

- `lib/app/router.dart:968-989`。

仓储端口只有 `commit`、`inspectRollback`、`rollback`，没有批次列表：

- `lib/domain/repositories/timetable_import_repository.dart:136-144`。

提示条消失、应用重启或用户稍后发现错误后，没有界面可以重新取得批次 id，已有回滚能力实际上不可达。

### 1.11 原子问题台账与闭环映射

前述 1.1–1.10 是便于定位代码所有权的根因分组，不是问题总数。实施与验收必须以下列 24 项原子台账为准；同一根因下任一行未通过，都不能把整个根因组标为完成。

| 编号 | 独立问题或接口缺口 | 根因组 | 实施任务 | 验收编号 |
| --- | --- | --- | --- | --- |
| C01 | 课程快捷改时仍调用已废弃的只传时间包装器 | 1.1 | Task 2、3 | API1 |
| C02 | 标题缺失时用“未命名事项”补齐并写回 | 1.1 | Task 2、3 | CE1、API1 |
| C03 | 时区缺失时用 UTC 补齐并写回 | 1.1 | Task 2、3 | CE1、TZ1、API1 |
| C04 | 备注和地点被空字符串覆盖 | 1.1 | Task 2、3 | CE1 |
| C05 | 领域和项目被 `null` 覆盖 | 1.1 | Task 2、3 | CE1 |
| C06 | 事件类别被默认 `fixed` 覆盖，界面显示成无领域固定日程 | 1.1 | Task 2、3 | CE1 |
| C07 | 日视图模型没有完整承载地点、领域和项目等隐藏字段 | 1.2 | Task 2 | CE2 |
| C08 | 当前草稿不能区分“保持原值”和“明确清空” | 1.2 | Task 2 | CE2 |
| C09 | 多片段课程逐片段提交，后段失败会留下半保存状态 | 1.3 | Task 3 | CE3 |
| C10 | 本地课程星期从 UTC `.weekday` 推导，清晨可能落到前一天 | 1.4 | Task 3 | TZ1 |
| C11 | 固定载体日期和 UTC 日历日加减不能正确覆盖跨午夜及 DST | 1.4 | Task 3 | TZ2 |
| C12 | 既有测试只覆盖 UTC+0，没有本地清晨、跨日和 DST 矩阵 | 1.4 | Task 1、3、11 | TZ1、TZ2 |
| C13 | 导入批次没有保存可重放的原课程快照，旧值丢失后不可凭空恢复 | 1.5 | Task 4、11 | LI1、LI3、LI4 |
| C14 | 页面没有结构化损坏检测，也没有正常空字段的误报边界 | 1.5 | Task 4 | LI1、LI2 |
| C15 | 受损课程没有手工补全或删除后重导入的受控恢复流程 | 1.5 | Task 4、9、11 | LI3、LI4 |
| C16 | 新增课程片段被错误写成 `sourceKind = manual` | 1.6 | Task 6 | P1、P4 |
| C17 | 新增课程片段丢失 `importBatchId`，可能脱离学期并逃逸批次撤销 | 1.6 | Task 6 | P1、P4 |
| C18 | 课程摘要由排序后第一片段决定学期和批次，混合来源结果不稳定 | 1.6 | Task 6 | P2、P3 |
| C19 | 删除导入课程后批次仍保持 `committed`，没有部分删除事实 | 1.7 | Task 5、7 | B1、B3 |
| C20 | 重导判断只看 committed 哈希，导致已删除课程不能用同图恢复 | 1.7 | Task 9 | R1、R2、R3 |
| C21 | 删除课程不回收已无锚点引用的重复规则 | 1.8 | Task 7 | D1、D2、D3、D4 |
| C22 | 保留锚点修改规则后，不重新校验其逐次例外是否仍是规则成员 | 1.9 | Task 8 | E1、E2、E3、E4、E5 |
| C23 | 失效例外残留，未来扩展规则时可能重新生效 | 1.9 | Task 8 | E1、E2、E3 |
| C24 | 仓储没有历史列表，撤销只存在于短暂提示条，重启后不可达 | 1.10 | Task 10、11 | H1、H2、H3、H4 |

台账状态只能取 `NOT STARTED`、`IN PROGRESS`、`PASS`、`FAIL`、`BLOCKED`。根因组完成条件是其所有原子编号均为 PASS；不得用“Task 已提交”代替验收结果，也不得把同一测试复制成多项证据而不逐条说明覆盖的断言。

## 2. 冻结产品与接口决策

本节不是建议列表。实施者不得在编码时改成另一套语义；若发现无法实现，停止对应 Task，记录证据并回到本文件评审。

### 2.0 先封住旧课程改写路径，再修复后续数据问题

实施顺序不可颠倒：先完成 Task 2–4，证明任何时间改写都不会继续制造受损课程，再允许执行来源修复、删除和重导入。否则后续任务一边修复数据，一边仍可能由旧入口重新写坏。

课程详情页只保留一个整门课程编辑入口。删除 `course-edit-time` 按钮和 `_editTime()` 的固定日期载体；“编辑课程”进入 `/calendar/courses/:logicalCourseId/edit`，编辑器可以滚动或聚焦到“上课安排”，但保存仍走 `previewCourseEdit()` → `saveCourse()` → `CourseWriteGateway.replaceCourseSeries()` 的单事务链路。

具体课次仍从日视图进入，范围语义保持：

- `singleOccurrence`：只写所选发生的一条例外；
- `followingOccurrences`：从真实发生日期拆分当前锚点；
- `entireSeries`：只改当前锚点代表的上课序列，不等于整门课程全部片段；
- 整门课程全部片段：只能走课程编辑页的课程快照事务。

不得把“移除快捷按钮”理解成删除功能：它是把两个实现不同、文案重叠的整门课程入口合并到唯一的安全事务入口。

### 2.0.1 日历改写使用显式 patch，不使用带默认值的伪完整草稿

新增不可变命令模型：

```dart
final class CalendarEventPatch {
  CalendarEventPatch({
    required this.title,
    required this.notes,
    required this.startAtUtc,
    required this.endAtUtc,
    this.location,
  });

  final String title;
  final String notes;
  final DateTime startAtUtc;
  final DateTime endAtUtc;

  // null = 当前界面没有编辑该字段，必须保留锚点原值；
  // 空字符串 = 用户明确清空地点。
  final FieldPatch<String>? location;
}

sealed class FieldPatch<T> {
  const FieldPatch();
}
final class KeepField<T> extends FieldPatch<T> {
  const KeepField();
}
final class SetField<T> extends FieldPatch<T> {
  const SetField(this.value);
  final T value;
}
```

若实现者选择把 `location` 设为必填并把权威值带入页面，也必须满足同一个验收结果；但 `areaId`、`projectId`、`kind`、`sourceKind`、`importBatchId`、`logicalCourseId`、锚点时区和规则时区不得由日视图请求覆盖。它们一律由仓储在事务内读取锚点后保留。

`CalendarService.updateEvent()` 接收 patch；仓储在同一事务内完成：读取锚点 → 核对 `expectedUpdatedAtUtc` → 合并允许修改字段 → 写锚点/例外/规则。不得先在服务层读一遍、过一段时间再写；那会在读取和提交之间留下竞态。

迁移完成后删除以下兼容代码：

- `CalendarService.replaceOccurrence()`；
- `CalendarService.replaceFollowingOccurrences()`；
- `CalendarService.replaceSeries()`；
- `_fallbackTitle`、`_fallbackTimeZoneId`；
- `_titleCache`、`_timeZoneCache`；
- `rememberTitleForLegacyWrappers()`、`rememberTimeZoneForLegacyWrappers()`。

删除而不是继续 deprecate，是为了让漏迁的调用点在编译期失败；只要这些接口还存在，相同事故就能从另一个入口复发。

### 2.0.2 整门课程保存必须原子且按规则本地日计算

整门课程资料或上课安排变更只构造一次 `CourseSaveRequest`。预览和保存使用同一份规范化草稿指纹；保存时按 `logicalCourseId + termId` 重新读取全部锚点与规则、核对修订号，然后在一个 Drift 事务中替换全部片段。

星期、起止日期、单双周和钟点都以每个片段规则的 `timeZoneId` 解释。禁止读取 UTC `DateTime.weekday` 来决定本地星期，也禁止使用固定年份的日期承载钟点。测试时间必须至少包含：

- Asia/Shanghai 周一 07:30；
- Asia/Shanghai 周日 00:15；
- America/New_York 夏令时切换前后；
- 23:30–次日 00:30 跨午夜；
- 一门课包含两个不同星期和单双周片段。

### 2.0.3 已受旧版影响的数据只检测，不猜测恢复

新增结构化完整性问题：

```dart
enum CourseIntegrityIssueKind {
  legacyPlaceholderTitle,
  eventRuleTimeZoneMismatch,
  conflictingImportLineage,
}

final class CourseIntegrityIssue {
  const CourseIntegrityIssue({
    required this.kind,
    required this.affectedAnchorIds,
  });
  final CourseIntegrityIssueKind kind;
  final List<String> affectedAnchorIds; // 仅内部使用，界面不显示
}
```

确定性判据：

- `logicalCourseId != null` 且导入课程标题精确等于旧占位值 `未命名事项`：标记 `legacyPlaceholderTitle`；
- 锚点 `timeZoneId` 与其 `recurrence_rules.time_zone_id` 不同：标记 `eventRuleTimeZoneMismatch`；
- 同一逻辑课程出现多个非空批次 id：沿用 `conflictingImportLineage`。

空教师、空地点或无领域本身可能是合法数据，不能单独作为损坏判据。迁移不得自动改标题、教师、地点、领域或项目。

课程详情与编辑页显示：“检测到这门课程可能受旧版时间修改问题影响。保存前请核对课程名称、教师、地点、领域、项目和上课安排。”并提供两条路径：

1. **手工修复**：在完整课程编辑页补全资料，查看结构化差异和冲突，确认后单事务保存；
2. **从原课表恢复**：先创建/确认备份，预览删除影响，删除整门受损课程，再打开课表导入并重新选择原图片。界面明确说明课程的逐次调整与例外会随删除消失。

数据库没有保存原 OCR 结果，所以不得提供“自动恢复原名称”按钮。若用户没有原图片、备份或记忆中的资料，系统只能保留现状并让用户手工更正，不能伪造答案。

### 2.1 课程来源按“逻辑课程在当前学期的系列”解析

新增领域值：

```dart
enum CourseLineageState {
  manual,
  imported,
  recoverableMixed,
  conflicting,
}

final class CourseSeriesProvenance {
  const CourseSeriesProvenance({
    required this.sourceKind,
    required this.importBatchId,
  });

  final CalendarEventSourceKind sourceKind;
  final String? importBatchId;
}
```

解析规则固定为：

| 当前学期片段中的非空 `importBatchId` | 空 `importBatchId` | 结果 | 保存行为 |
| --- | ---: | --- | --- |
| 0 个 | 任意 | `manual` | 全部写 `manual/null` |
| 恰好 1 个不同值 | 0 个 | `imported` | 全部沿用该批次，来源为 `timetableImport` |
| 恰好 1 个不同值 | 1 个以上 | `recoverableMixed` | 允许保存；成功事务把全部最终片段统一到该批次 |
| 2 个或更多不同值 | 任意 | `conflicting` | 禁止保存；不猜测、不写库 |

具体约束：

- `CourseSeriesSegment` 增加 `importBatchId`，由读仓储逐行带出。
- `CourseSeriesSummary.termId` 和 `importBatchId` 不再盲取排序后的第一条；从全部片段的唯一非空来源归并。
- `CourseSaveRequest` 不增加用户可填写的来源字段。
- `CourseManagementService.saveCourse()` 在完成 stale 检查后，从刚读到的 `detail.segments` 解析 `CourseSeriesProvenance`。
- `CourseWriteGateway.replaceCourseSeries()` 增加必填 `provenance` 参数。
- `DriftCalendarRepository.replaceCourseSeries()` 对每个最终锚点都写同一 provenance；不得再按 `existingRow == null` 决定来源。
- `conflicting` 返回 `CourseSaveStatus.invalid` 或新增的结构化 `integrityConflict`；界面显示“这门课程关联了多个导入批次，未保存。请先备份并从导入记录检查来源。”不得显示批次 UUID。

### 2.2 批次增加 `partiallyDeleted` 持久状态

不复用 `draft`，不改写图片哈希，不删除仍被其它课程引用的批次行。

`TimetableImportBatchStatus` 增加：

```dart
partiallyDeleted('partiallyDeleted')
```

语义：

- `committed`：批次提交完成，未通过“删除整个课程”路径移除批次内容；
- `partiallyDeleted`：该批次至少有一门逻辑课程被课程管理功能删除；即使已删至 0 条，也保留该状态和审计记录；
- `rolledBack`：用户执行了批次回滚；
- `draft`：保留现有兼容值，不把它当删除标记。

同图片重复判断只阻止 `committed` 批次。`partiallyDeleted` 与 `rolledBack` 不阻止重新导入。

### 2.3 删除课程是一个事务，不是四次调用

`CourseWriteGateway.deleteSeriesWithExceptions()` 改为：

```dart
Future<CourseDeletionResult> deleteSeriesWithExceptions({
  required Set<String> anchorEventIds,
  required DateTime deletedAtUtc,
});
```

事务内顺序固定：

1. 读取目标锚点，收集真实存在的锚点 id、候选规则 id、非空导入批次 id；
2. 删除 `exception_of_id` 指向目标锚点的例外；
3. 删除目标锚点；
4. 对候选规则逐个确认已经没有任何 `calendar_events.recurrence_rule_id` 引用，再删除规则；
5. 把受影响且当前为 `committed` 的批次改为 `partiallyDeleted`，写同一个 `deletedAtUtc`；
6. 返回实际删除的锚点、例外、规则和受影响批次数。

空集合和不存在的 id 保持幂等；不能把其它锚点仍在使用的共享规则删掉。

### 2.4 规则成员判定只有一个实现

新增纯函数：

```dart
bool recurrenceIncludesLocalDate(
  RecurrenceRule rule,
  DateTime localDate,
);
```

它按以下顺序判定：

1. 取 date-only；
2. 不早于 `validFromLocalDate`；
3. 不晚于非空 `validUntilLocalDate`；
4. 星期属于 `rule.weekdays`；
5. `candidateMonday - anchorMonday` 的周偏移非负且能被 `intervalWeeks` 整除。

`RecurrenceExpander` 和课程例外预览/清理必须调用这个函数，不允许复制另一份相似公式。

当前数据库用例外行 `startAtUtc` 在规则时区对应的本地日期作为例外键；本计划沿用该已存在语义。移动到另一日期的旧替换例外缺少“原发生日期”字段，不能在本计划中凭空恢复历史来源。实施者不得猜测或批量改写这类旧数据；见 §10.2 的剩余风险。

### 2.5 预览必须分开报告两类例外删除

`CourseEditPreview` 增加：

```dart
final int removedSegmentExceptionCount;
final int invalidatedRetainedExceptionCount;
int get removedExceptionCount =>
    removedSegmentExceptionCount + invalidatedRetainedExceptionCount;
```

- 第一项：锚点整段被删除而随之删除的例外；
- 第二项：锚点保留，但例外日期不再属于新规则而被清理的例外。

确认界面必须分别写明，例如：“删除 1 个课程片段及其 2 次单独调整；另有 1 次单独调整已超出新周次，将删除。”

预览与保存使用同一个 `recurrenceIncludesLocalDate()`。若预览后数据变化，现有 fingerprint/revision stale 检查必须阻止保存。

### 2.6 导入记录是持久入口，快捷撤销仍保留

新增仓储接口：

```dart
Future<List<TimetableImportHistoryItem>> listHistory({
  String? termId,
  bool includeRolledBack = true,
});
```

`TimetableImportHistoryItem` 至少包含：

- 批次 id（仅供动作调用，不直接显示）；
- 源文件名；
- 学期 id 与可用时的学期名称；
- 创建时间；
- 原创建系列数；
- 当前剩余系列数；
- 受保护/已修改系列数；
- 存储状态；
- `canRollback`；
- `requiresForceConfirmation`。

入口固定为：`近期日历 → 管理课程 → 导入记录`。原因是课程管理页已有“导入课表”入口，且不会继续挤压近期日历顶部工具栏。新增路由：`/calendar/import/history`。

列表按 `createdAtUtc` 降序；状态文案：

- `committed` 且无受保护系列：“已导入”；
- `committed` 且有受保护系列：“导入后有修改”；
- `partiallyDeleted`：“已删除部分课程，可重新导入”；
- `rolledBack`：“已撤销”。

`rolledBack` 行不显示可点击撤销；无剩余课程的 `partiallyDeleted` 行也不显示撤销，但保留“重新导入课表”入口。

提示条快捷动作和历史页动作都必须调用同一个 `TimetableImportService.inspectRollback()/rollback()` 流程。不得在页面复制回滚 SQL或跳过受保护课程确认。

### 2.7 迁移决策

数据库从 v9 升到 v10，唯一结构变化是 `timetable_import_batches.status` 的 CHECK 增加 `'partiallyDeleted'`。

- `plannerSchemaVersion` 与 `AppDatabase.schemaVersion` 同时改为 10。
- 使用 Drift 的表迁移重建 `timetable_import_batches`；不能手改生成文件。
- v9 的 `draft/committed/rolledBack` 原值逐行保留，不做猜测式回填。
- 现有外键 `calendar_events.import_batch_id` 在迁移前后都要通过 `PRAGMA foreign_key_check`。
- 迁移前后的批次数、id、termId、哈希、文件名、创建数和时间戳逐值相同。
- `calendar_events`、`recurrence_rules` 和其它表不得因本迁移发生数据变化。

## 3. 目标状态与事务不变量

### 3.0 改写与恢复不变量

任意日历或课程改写提交后：

```text
未在当前界面暴露的字段(after) = 同一锚点对应字段(before)
课程身份(after) = 课程身份(before)
事件类别(after) = 事件类别(before)
事件时区(after) = 规则时区(after) = 该片段规则时区
```

其中课程身份至少包含 `sourceKind`、`importBatchId`、`logicalCourseId`。日视图没有编辑地点、领域或项目时，三者也必须逐值不变。

整门课程的保存只有两种可观察结果：

- 成功：全部目标片段、规则和需清理例外同一事务提交，只发一次日历失效信号；
- 失败或 stale：所有目标表逐值等于保存前，不允许“3 个片段中改了 2 个”。

受损数据检测是只读行为。打开课程、运行迁移或生成计划都不得自动覆写它。只有用户确认课程编辑保存、课程删除、导入提交或备份恢复时才允许改变数据。

### 3.1 来源不变量

对于任意一个 `logicalCourseId + termId`：

- 若存在非空 `importBatchId`，所有成功保存后的系列锚点都必须使用同一个批次；
- `importBatchId != null` 时 `sourceKind == timetableImport`；
- `sourceKind == manual` 时 `importBatchId == null`；
- 新增片段、复用片段和只改资料片段遵守同一规则；
- 删除例外和替换例外不改变所属锚点的来源事实。

### 3.2 删除不变量

课程删除提交后：

```text
目标逻辑课程锚点 = 0
指向目标锚点的例外 = 0
只由目标锚点引用的规则 = 0
仍被非目标锚点引用的规则 = 保留
受影响 committed 批次 = partiallyDeleted
其它批次状态 = 不变
```

事务失败后，上述五项都等于删除前状态。

### 3.3 例外不变量

保存课程新规则后，保留锚点名下每一条例外满足：

```text
recurrenceIncludesLocalDate(newRule, exceptionLocalDate) == true
```

否则该例外必须在同一事务中删除。预览报告的 `invalidatedRetainedExceptionCount` 必须等于实际删除数。

### 3.4 重导入不变量

- 同学期、同哈希存在 `committed` 批次：保持幂等拦截；
- 同学期、同哈希只有 `partiallyDeleted` 或 `rolledBack` 批次：允许进入预览和提交；
- 剩余课程由现有逐课程重复检测默认跳过；
- 已删除课程作为缺失课程重新创建；
- 新批次拥有新 batch id，旧批次历史不被覆盖；
- 两个提交不能因重复检查在事务外发生竞态而同时写入相同完整课表。

### 3.5 回滚不变量

- 回滚只删除所选批次当前仍归属该批次的锚点、例外和无引用规则；
- 课程编辑新增且正确继承批次的片段也属于回滚范围；
- 用户改过的锚点或外部例外继续列入 `protectedEventIds`；
- 未确认 force 时零写入；
- 回滚提交后状态为 `rolledBack`，历史记录仍存在。

## 4. Task 1 — 建立 24 项原子问题的红灯与基线清单

**Files:**
- Modify: `test/application/course_whole_time_mapping_test.dart`
- Modify: `test/application/calendar_replan_events_test.dart`
- Modify: `test/features/calendar/course_detail_page_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/data/recurrence_exception_test.dart`
- Modify: `test/data/course_write_gateway_test.dart`
- Modify: `test/data/course_series_repository_test.dart`
- Modify: `test/application/course_edit_save_test.dart`
- Modify: `test/application/course_management_service_test.dart`
- Modify: `test/data/timetable_import_repository_test.dart`
- Create: `test/features/calendar/timetable_import_history_page_test.dart`
- Modify: `test/app/timetable_import_route_test.dart`

**Interfaces:**
- Produces: 24 项原子问题的可追踪最小复现；记录当前 v9 行为和旧包装器仍可被调用的事实。允许一个测试覆盖同一执行链上的多项原子问题，但测试名、断言或台账证据必须明确对应 C01–C24，不能只写“课程编辑正常”。
- Does not produce: 生产修复、迁移、UI入口。

- [ ] **Step 1: 记录基线**

运行并保存当前提交哈希、`git status --short`、Flutter/Dart 版本及以下定向测试结果。已有失败单独登记，不能混入本计划红灯。

```powershell
flutter test --no-pub test/application/course_whole_time_mapping_test.dart test/application/calendar_replan_events_test.dart test/features/calendar/course_detail_page_test.dart test/features/calendar/day_view_test.dart test/data/recurrence_exception_test.dart test/data/course_write_gateway_test.dart test/data/course_series_repository_test.dart test/application/course_edit_save_test.dart test/application/course_management_service_test.dart test/data/timetable_import_repository_test.dart test/app/timetable_import_route_test.dart
```

- [ ] **Step 2: 写“改时间不得覆盖资料”红灯**

构造一门 imported 课程，字段全部使用非默认值：标题“算法与数据结构”、教师“张老师”、地点“教一 302”、领域/项目非空、时区 Asia/Shanghai、`sourceKind=timetableImport`、`importBatchId` 与 `logicalCourseId` 非空。执行课程详情当前“改时间”链路，逐字段断言除开始/结束钟点外全部不变；当前实现应至少在标题、教师、地点、领域、项目和事件时区上失败。

- [ ] **Step 3: 写日视图隐藏字段保留红灯**

从日视图只改标题、备注与时间，断言地点、领域、项目、类别、来源、批次、逻辑课程 id 和规则时区不变。再覆盖一次性固定日程、自定义保护时间、导入课程的重复发生三类。不得只断言页面回调参数；必须落到真实 Drift 后重读数据库。

- [ ] **Step 4: 写多片段原子性红灯**

一门课程含周一与周四两个片段。在第二片段规则写入处注入失败，断言第一片段锚点/规则、第二片段锚点/规则、所有例外、修订号和失效信号计数全部保持保存前状态。当前逐片段调用应暴露半提交。

- [ ] **Step 5: 写本地星期与跨日红灯**

按 §2.0.2 的五组时区/时间逐项断言本地星期、起止分钟、持续时长和规则日期。测试不得用 UTC+0 简化；至少一个用例必须在 Asia/Shanghai 本地 07:30 对应前一 UTC 日期。

- [ ] **Step 6: 写旧损坏检测与零写入红灯**

分别构造：导入课程标题为 `未命名事项`、锚点 Asia/Shanghai 规则但事件为 UTC、正常空教师/空地点、用户手工创建且标题恰为“未命名事项”。只标记前两种确定异常；打开详情或运行检测后逐表断言零写入。手工 fixed 事项不得被误报为导入课程损坏。

- [ ] **Step 7: 写来源红灯**

夹具：一个导入批次、一门逻辑课程、一个既有锚点；编辑时保留旧片段并新增第二片段。断言新增锚点的 `sourceKind`、`importBatchId` 与旧片段一致，课程仍能按原 termId 列出，回滚预览包含两个锚点。当前实现应失败。

- [ ] **Step 8: 写删课后重导入红灯**

提交含课程 A/B 的批次，删除 A 的全部片段，再提交同学期同哈希且只包含 A 的请求。目标行为是允许；B 不重复。当前实现应抛 `DuplicateTimetableImportException`，因此红灯成立。

- [ ] **Step 9: 写孤儿规则红灯**

删除一门含两个规则、三个例外的课程，断言锚点、例外、两个独占规则都不存在。再造一个异常夹具：目标锚点和非目标锚点共享规则，断言共享规则保留。

- [ ] **Step 10: 写失效例外红灯**

至少覆盖：

1. 有效期从第 1–16 周缩短到第 1–8 周，第 10 周例外删除；
2. 星期从周一改周三，原周一例外删除；
3. 每周改双周，落在不匹配周的例外删除；
4. 仍在规则内的替换例外保留；
5. 零长度删除例外与非零替换例外使用同一成员判定。

- [ ] **Step 11: 写持久撤销入口红灯**

构造 committed、partiallyDeleted、rolledBack 三类历史项，断言按时间倒序、内部 id 不显示、按钮状态正确、受保护批次点击后出现确认。此时类型或页面尚不存在，编译失败是接口红灯；补最小测试桩后必须让行为断言失败，而不是停在无意义编译错误。

- [ ] **Step 12: 审核红灯真实性**

每条测试在目标生产修复前失败，在故意恢复旧行为时仍失败。不得用 `skip`、宽泛 `throwsA(anything)`、只检查“不为空”或 snapshot 大图替代字段级断言。

- [ ] **Step 13: 提交测试**

提交信息：`test: reproduce course edit and import recovery defects`。

## 5. Task 2 — 用事务内 patch 取代会清空字段的日历改写契约

**Files:**
- Modify: `lib/domain/models/calendar_event_edit.dart`
- Modify: `lib/domain/repositories/calendar_event_deletion.dart`
- Modify: `lib/application/calendar_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/application/calendar_service_test.dart`
- Modify: `test/application/calendar_replan_events_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Modify: `test/data/recurrence_exception_test.dart`
- Modify: all affected test doubles found by `rg "implements CalendarEventDeletion" test`

**Interfaces:**
- Produces: `CalendarEventPatch`（或语义完全等价的显式 patch）；事务内锚点合并；结构化 mutation 结果。
- Consumes: Task 1 的隐藏字段覆盖红灯。
- Removes: 五个 legacy wrapper/cache 方法、两个 fallback 常量以及所有生产调用。

- [ ] **Step 1: 冻结调用点清单**

运行：

```powershell
rg -n "replaceOccurrence\(|replaceFollowingOccurrences\(|replaceSeries\(|rememberTitleForLegacyWrappers|rememberTimeZoneForLegacyWrappers|_fallbackTitle|_fallbackTimeZoneId" lib test
```

把结果贴入执行记录。生产调用除 `CalendarService` 向仓储端口的分派外必须在本任务结束时归零；测试可直接测仓储端口，但不得继续测已删除的兼容包装器。

- [ ] **Step 2: 新增 patch 与字段语义测试**

按 §2.0.1 建立不可变 patch。明确并测试：

- 标题空白非法；
- 起止必须为 UTC 且结束晚于开始；
- `KeepField` 与 `SetField('')` 可区分；
- 集合或 map 字段不可由外部改写；
- patch 不包含 `sourceKind`、`importBatchId`、`logicalCourseId` 或 `kind` 的任意修改入口。

- [ ] **Step 3: 把 stale 校验移入同一写事务**

`CalendarEventDeletion` 的改写命令接收 `expectedUpdatedAtUtc`。Drift 仓储在事务开始后按 `anchorId` 读取锚点并比较修订号；不存在返回 missing，修订不同返回 stale，均零写入。删除 `CalendarService._currentUpdatedAtOf()` 的宽窗口 occurrence 扫描，避免已结束系列被误判为不存在。

仓储不得抛字符串供页面判断状态；返回结构化 `CalendarMutationStatus` 或抛只在应用层映射的类型化领域异常。

- [ ] **Step 4: 在仓储内合并权威字段**

对 single/following/series 三条路径，在同一事务内从锚点合并：

```text
title/notes/start/end/location = patch 中明确提交的值
areaId/projectId              = 锚点原值
kind                          = 锚点原值
timeZoneId                    = 规则存在时取规则时区，否则取锚点时区
source/importBatch/logicalId  = 锚点原值
locked/recurrence identity    = 按既有范围语义保留或生成
```

单次例外必须继承锚点的地点、领域、项目、类别与来源；此次及以后产生的新锚点必须继承同样身份。只有专门的“调整所属领域”命令可以改变 `areaId`。

- [ ] **Step 5: 迁移日视图调用**

`OccurrenceEditRequest` 改为携带 patch 和 expected revision，不再伪造完整 `CalendarEventEditDraft`。对话框继续只展示产品允许的字段；用户没看到的字段不会进入请求。路由只负责本地日期时间转 UTC，不再逐字段重建带默认值草稿。

- [ ] **Step 6: 删除旧包装器与缓存**

迁移所有调用后删除 §2.0.1 列出的包装器、缓存与 fallback。再次运行 Step 1 搜索；任何生产命中均为失败。测试中的调用改为 `updateEvent()` 或直接仓储端口，不能为了少改测试而保留危险接口。

- [ ] **Step 7: 验证事务和用户错误**

分别注入：锚点不存在、stale、规则写入失败、例外写入失败、重排记录回调失败。前四种零写入；最后一种数据已保存并返回 `savedWithWarning`。用户消息不得包含异常 `toString()`、数据库路径、SQL 或 UUID。

- [ ] **Step 8: 运行定向测试并提交**

```powershell
flutter test --no-pub test/application/calendar_service_test.dart test/application/calendar_replan_events_test.dart test/features/calendar/day_view_test.dart test/data/recurrence_exception_test.dart
```

提交信息：`fix: preserve event metadata during scoped edits`。

## 6. Task 3 — 移除危险的课程快捷改时并统一到课程快照事务

**Files:**
- Modify: `lib/features/calendar/courses/course_detail_page.dart`
- Modify: `lib/features/calendar/courses/course_editor_page.dart`
- Modify: `lib/application/course_management_service.dart`
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/domain/models/course_edit.dart`
- Modify: `lib/data/repositories/drift_course_series_repository.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/features/calendar/course_detail_page_test.dart`
- Modify: `test/features/calendar/course_editor_page_test.dart`
- Modify: `test/application/course_whole_time_mapping_test.dart`
- Modify: `test/application/course_edit_save_test.dart`
- Modify: `test/data/course_write_gateway_test.dart`

**Interfaces:**
- Produces: 整门课程只有一个编辑入口；本地时区明确的课程片段；全部片段单事务保存。
- Consumes: Task 2 的安全日历单次/系列 patch，但整门课程不通过该单锚点接口保存。
- Removes: `CourseDetailPage._editTime()`、`course-edit-time` 入口、`CourseManagementService.editWholeCourse()` 的逐片段写路径和 `_mapToSegmentDay()` 的 UTC 日期载体。

- [ ] **Step 1: 先把 UI 契约写成红灯**

课程详情只显示“编辑课程”，不再同时显示“编辑课程”和“改时间”。点入口进入同一 `logicalCourseId` 的编辑页，标题、教师、地点、领域、项目和全部安排预填。可通过 route query/页面锚点聚焦“上课安排”，但不得创建第二种保存服务。

- [ ] **Step 2: 把片段时区加入权威读模型**

`CourseSeriesSegment` 增加非空 `timeZoneId`，由锚点和规则读取。正常重复课程要求两者一致；不一致时不静默选一个，而是产生 Task 4 的结构化完整性问题。课程编辑的日期、星期与分钟一律依据该字段解释。

- [ ] **Step 3: 移除固定日期载体**

删除 `DateTime(2026, 1, 5)`、`_mapToSegmentDay()` 与 `_addLocalDays()`。编辑页已经持有规则的本地 `validFromLocalDate`、星期与分钟；预览按每个片段自己的规则时区直接构造 occurrence。不得先构造一个 UTC 日期再搬星期。

- [ ] **Step 4: 整门课程只调用一次事务网关**

资料或任一片段变化后，构造完整 `CourseSaveRequest`，先调用 `previewCourseEdit()`，再以同一 fingerprint 调 `saveCourse()`。写网关事务内重新读取全部锚点/规则并核对修订；任何一步失败全部回滚。成功只发一次 `onCalendarChanged`，不按片段发多次重排原因。

- [ ] **Step 5: 锁定时区与多片段回归**

运行 Task 1 的五组时区测试，并新增：两片段第二次写失败回滚、同名不同 `logicalCourseId` 不受影响、只改钟点时所有资料/身份逐值不变、跨午夜持续时长正确、预览后再改字段会使旧指纹失效。

- [ ] **Step 6: 清理无调用代码**

搜索 `editWholeCourse(`、`_mapToSegmentDay`、`course-edit-time`。若应用层已无合法调用，删除方法及只为它存在的测试替身；不得留下“以后可能会用”的危险后门。若保留同名公共 API 供外部调用，它必须内部转成一次 `CourseSaveRequest` 并具备完全相同的事务与预览令牌，不得循环单锚点更新。

- [ ] **Step 7: 运行定向测试并提交**

```powershell
flutter test --no-pub test/features/calendar/course_detail_page_test.dart test/features/calendar/course_editor_page_test.dart test/application/course_whole_time_mapping_test.dart test/application/course_edit_save_test.dart test/data/course_write_gateway_test.dart
```

提交信息：`fix: make whole-course time edits atomic and timezone safe`。

## 7. Task 4 — 识别并引导恢复旧版已损坏课程

**Files:**
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/data/repositories/drift_course_series_repository.dart`
- Modify: `lib/features/calendar/courses/course_detail_page.dart`
- Modify: `lib/features/calendar/courses/course_editor_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/data/course_series_repository_test.dart`
- Modify: `test/features/calendar/course_detail_page_test.dart`
- Modify: `test/features/calendar/course_editor_page_test.dart`
- Modify: `test/app/course_management_route_test.dart`

**Interfaces:**
- Produces: `CourseIntegrityIssue`；只读检测；手工修复与删除后重导入两条可达路径。
- Consumes: Task 3 的安全课程事务编辑。
- Does not produce: 猜测原课程资料、自动改库、OCR 结果历史恢复。

- [ ] **Step 1: 实现确定性只读检测**

仓储在读取课程详情时同时读取锚点与规则时区，按 §2.0.3 生成问题列表。内部可保存 anchor id 供定位，但界面只显示受影响片段的星期和时间，不显示 id。空教师、空地点、空领域不得触发损坏提示。

- [ ] **Step 2: 在详情与编辑页显示阻断级提示**

提示必须说明：这是“可能由旧版时间修改造成的资料丢失”，系统没有原 OCR 内容，不能自动还原。编辑页将标题为 `未命名事项` 的导入课程标为待核对，不允许用户不看提示就再次确认保存；用户可以保留这个标题，但必须显式勾选“我确认这是正确课程名”。

- [ ] **Step 3: 提供手工修复路径**

“手工修复”进入完整课程编辑页，预填当前仍存在的字段。保存预览逐项列出标题、教师、地点、领域、项目、时区和安排差异；确认后走 Task 3 的单事务。保存成功后重新读取，只有所有确定性问题消失才移除提示。

- [ ] **Step 4: 提供删除后重导入路径**

“从原课表恢复”先显示：将删除多少片段、多少未来/历史 occurrence、多少逐次调整；要求用户确认已有备份，再进入既有删除二次确认。删除成功后跳转 `/calendar/import`，显示原文件名作为提示但不保存或自动打开旧绝对路径。Task 7–10 完成前该入口保持 feature-gated，不得把用户送到仍会被同哈希阻止的死路。

- [ ] **Step 5: 写不可恢复边界测试**

没有原图片、备份或人工输入时，只能保留现状。测试断言页面不显示“自动恢复原名称”，迁移与启动零写入；用户取消手工修复或删除确认时数据库不变。

- [ ] **Step 6: 运行定向测试并提交**

```powershell
flutter test --no-pub test/data/course_series_repository_test.dart test/features/calendar/course_detail_page_test.dart test/features/calendar/course_editor_page_test.dart test/app/course_management_route_test.dart
```

提交信息：`feat: surface and recover legacy course edit damage`。

## 8. Task 5 — 数据库 v10 与批次部分删除状态

**Files:**
- Modify: `lib/data/database/tables/planner_tables.dart`
- Modify: `lib/data/database/app_database.dart`
- Regenerate: `lib/data/database/app_database.g.dart`
- Regenerate: `lib/data/database/app_database.steps.dart`
- Create: `drift_schemas/app_database/schema_v10.json`
- Create: `test/drift/app_database/generated/schema_v10.dart`
- Modify: `test/drift/app_database/generated/schema.dart`
- Modify: `test/drift/app_database/schema_migration_test.dart`
- Modify: `test/drift/app_database/real_database_migration_test.dart`
- Modify: `test/app/pre_migration_backup_test.dart`
- Modify: `lib/domain/repositories/timetable_import_repository.dart`

**Interfaces:**
- Produces: `TimetableImportBatchStatus.partiallyDeleted`；v9 → v10 原子迁移。
- Consumes: 现有迁移前备份与 Drift 外键配置。

- [ ] **Step 1: 先写迁移红灯**

用 v9 schema 建库，插入三种既有状态、批次外键、课程锚点、规则和例外。打开 v10 后断言：

- 所有旧值逐列相同；
- 可以写 `partiallyDeleted`；
- 非法状态仍被 CHECK 拒绝；
- `PRAGMA foreign_key_check` 为空；
- 所有非批次表行数和内容不变。

- [ ] **Step 2: 更新领域枚举和表约束**

枚举解析必须显式认识新值。未知存储值不能静默回落为 committed；应抛受控数据错误或返回明确 unknown 状态，避免把损坏数据当成可撤销批次。

- [ ] **Step 3: 实现 v10 迁移**

同时更新两个版本数字。表重建必须在 `onUpgrade` 同一事务内完成。迁移期间保留表名、主键、外键和全部列；只替换 status CHECK。

- [ ] **Step 4: 重新生成，不手改生成文件**

```powershell
& G:\best-planing\.tooling\fx.ps1 pub run build_runner build --delete-conflicting-outputs
& G:\best-planing\.tooling\fx.ps1 pub run drift_dev schema dump lib/data/database/app_database.dart drift_schemas/
& G:\best-planing\.tooling\fx.ps1 pub run drift_dev schema generate drift_schemas/ test/drift/app_database/generated --data-classes --companions
```

若仓库脚本参数与当前 Drift 版本不同，以 `test/drift/app_database/schema_migration_test.dart` 顶部记录的命令为准，并在验收记录中写明实际命令。

- [ ] **Step 5: 验证备份先于迁移**

`plannerSchemaVersion` 改为 10 后，`pre_migration_backup_test.dart` 必须证明 v9 数据库先成功备份，再打开 v10。备份失败时数据库不得进入升级。

- [ ] **Step 6: 运行定向测试**

```powershell
flutter test --no-pub test/drift/app_database/schema_migration_test.dart test/drift/app_database/real_database_migration_test.dart test/app/pre_migration_backup_test.dart
```

- [ ] **Step 7: 提交**

提交信息：`feat: add partially deleted timetable batch state`。

## 9. Task 6 — 修复课程来源解析与新增片段继承

**Files:**
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/domain/models/course_edit.dart`
- Modify: `lib/domain/repositories/course_write_gateway.dart`
- Modify: `lib/data/repositories/drift_course_series_repository.dart`
- Modify: `lib/application/course_management_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/data/course_series_repository_test.dart`
- Modify: `test/data/course_write_gateway_test.dart`
- Modify: `test/application/course_edit_save_test.dart`
- Modify: fake `CourseWriteGateway` implementations found by `rg -l "implements CourseWriteGateway" test lib`

**Interfaces:**
- Produces: §2.1 的 lineage state、provenance 和唯一解析规则。
- Consumes: Task 1 来源红灯。

- [ ] **Step 1: 增加逐片段来源字段和纯解析器**

`CourseSeriesSegment` 带出 `importBatchId`。解析器独立测试 manual、imported、recoverableMixed、conflicting 四格，不读数据库、不看时钟。

- [ ] **Step 2: 修正课程摘要来源**

`_summarize()` 先汇总全部行再选择 term/batch；排序后的 head 只继续承担标题、时段等代表展示，不能再决定来源。混合一空一非空时，当前学期过滤仍能找到课程。

- [ ] **Step 3: 服务层从最新详情解析 provenance**

解析发生在 stale/fingerprint 检查之后、字段校验之后、写网关调用之前。不能使用页面打开时缓存的 batch id。conflicting 时返回结构化失败，零写入。

- [ ] **Step 4: 网关要求 provenance**

更新接口、所有 fake 和调用点。参数不能为空；`sourceKind == timetableImport` 与 `importBatchId == null` 的非法组合在进入事务前抛 `ArgumentError`，manual + 非空批次同样拒绝。

- [ ] **Step 5: 对全部最终锚点统一写来源**

复用锚点和新增锚点都使用 `provenance`。对 recoverableMixed，成功保存后再次读取必须变成 imported；若事务中任一行失败，混合来源保持原样。

- [ ] **Step 6: 验证回滚范围与学期列表**

新增片段后：

- `listCourses(termId: originalTerm)` 仍返回一门课程；
- 详情含两个片段且 batch 一致；
- `inspectRollback(batchId).eventIds` 含两个锚点；
- 另一个学期同名课程不受影响。

- [ ] **Step 7: 运行测试**

```powershell
dart format lib/domain/models/course_series.dart lib/domain/models/course_edit.dart lib/domain/repositories/course_write_gateway.dart lib/data/repositories/drift_course_series_repository.dart lib/application/course_management_service.dart lib/data/repositories/drift_calendar_repository.dart test
flutter test --no-pub test/data/course_series_repository_test.dart test/data/course_write_gateway_test.dart test/application/course_edit_save_test.dart test/application/course_management_service_test.dart test/application/timetable_import_rollback_test.dart
```

- [ ] **Step 8: 提交**

提交信息：`fix: preserve timetable lineage when editing courses`。

## 10. Task 7 — 让课程删除清理完整并原子标记批次

**Files:**
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/domain/repositories/course_write_gateway.dart`
- Modify: `lib/application/course_management_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/data/course_write_gateway_test.dart`
- Modify: `test/application/course_management_service_test.dart`
- Modify: `test/data/course_deletion_preview_count_test.dart`
- Modify: fake `CourseWriteGateway` implementations found by repository search

**Interfaces:**
- Produces: `CourseDeletionResult`；§2.3 单事务删除语义；批次状态转移。
- Consumes: Task 5 的 `partiallyDeleted`。

- [ ] **Step 1: 定义结果结构**

结果至少返回 `deletedAnchorCount`、`deletedExceptionCount`、`deletedRuleCount`、`affectedImportBatchCount`。集合可用于测试但不向 UI 显示 UUID。

- [ ] **Step 2: 服务传入单一 UTC 时间**

`CourseManagementService.deleteCourse()` 用注入时钟生成一次 `deletedAtUtc`。仓储不得在循环中多次读系统时钟。

- [ ] **Step 3: 实现事务顺序**

按 §2.3 的六步执行。先读真实锚点，避免调用方传入不存在 id 时错误标记批次。规则删除增加“已无引用”条件，不能假设规则永不共享。

- [ ] **Step 4: 只转移允许的批次状态**

`committed → partiallyDeleted`；`partiallyDeleted` 保持；`rolledBack` 和 `draft` 不改。状态更新、时间戳和课程删除同事务。

- [ ] **Step 5: 注入失败验证整体回滚**

在删除例外后、删除锚点后、删除规则后、批次更新时分别制造失败。每个用例都断言四张表与执行前一致。

- [ ] **Step 6: 幂等与共享规则测试**

第一次删除返回真实计数；第二次返回 0 且不改批次更新时间。共享规则在仍有引用时保留，最后一个引用删除时才回收。

- [ ] **Step 7: 运行测试**

```powershell
flutter test --no-pub test/data/course_write_gateway_test.dart test/application/course_management_service_test.dart test/data/course_deletion_preview_count_test.dart test/data/timetable_import_repository_test.dart
```

- [ ] **Step 8: 提交**

提交信息：`fix: delete course series and import state atomically`。

## 11. Task 8 — 清理不再属于新规则的逐次例外

**Files:**
- Create: `lib/domain/services/recurrence_membership.dart`
- Modify: `lib/domain/services/recurrence_expander.dart`
- Modify: `lib/domain/models/course_series.dart`
- Modify: `lib/domain/models/course_edit.dart`
- Modify: `lib/domain/repositories/course_write_gateway.dart`
- Modify: `lib/application/course_management_service.dart`
- Modify: `lib/data/repositories/drift_course_series_repository.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Create: `test/domain/recurrence_membership_test.dart`
- Modify: `test/domain/recurrence_expander_test.dart`
- Modify: `test/data/course_write_gateway_test.dart`
- Modify: `test/application/course_edit_save_test.dart`
- Modify: `test/features/calendar/course_editor_page_test.dart`

**Interfaces:**
- Produces: `recurrenceIncludesLocalDate()`；两类例外删除计数；事务内清理。
- Consumes: Task 1 的范围、星期、单双周红灯。

- [ ] **Step 1: 写纯函数边界矩阵**

至少覆盖：起始日、结束日、结束日后一日、错误星期、每周、每两周首周/次周、跨年、周日起始、Asia/Shanghai、America/New_York DST 周。函数只比较本地日期，不自行将 UTC 转本地。

- [ ] **Step 2: 让展开器复用纯函数**

删除 `_matchesIntervalWeek` 的重复公式。现有展开器测试结果必须逐项不变；这一步是防止预览/清理与真正展开产生不同答案。

- [ ] **Step 3: 网关增加固定的预览计数接口**

接口固定为：

```dart
Future<int> countExceptionsInvalidatedBy({
  required String anchorEventId,
  required CourseScheduleDraft replacement,
  required String zoneId,
});
```

仓储使用目标规则的 `zoneId` 将例外 `startAtUtc` 转为 date-only，再调用纯函数。例外行时区若与目标规则不同，返回结构化完整性错误，不在预览中偷偷选一个。锚点不存在时返回 0。

- [ ] **Step 4: 预览分开累计两类删除**

被移除锚点调用现有 `countExceptions()`；保留锚点调用新方法。页面显示两个数字，0 项不渲染空句。预览不得执行删除。

- [ ] **Step 5: 保存事务中先写新规则，再清理失效例外**

对每个复用锚点，根据刚写入的新规则筛选例外。只删除成员判定为 false 的行。新锚点没有旧例外，不做查询。

- [ ] **Step 6: 把例外修订纳入确定性指纹并在事务内校验**

`CourseSeriesSegment` 增加 `exceptionRevisionFingerprint`。`DriftCourseSeriesRepository` 一次批量读取本课程所有锚点的例外，按锚点分组；每组按例外 id 排序后拼接：

```text
exception.id | startAtUtc | endAtUtc | timeZoneId | updatedAtUtc
```

该值加入 `CourseSeriesDetail.revisionFingerprint`，也进入 `CourseSaveRequest.expectedFingerprint`。`CourseWriteGateway.replaceCourseSeries()` 在同一写事务开始后重新计算并比较；不一致返回 stale 且零写入。不得只比较例外数量或最大更新时间，因为“删一条再加一条”可能保持数量相同，“同一微秒写多条”也可能具有相同最大时间。

测试覆盖预览后新增、删除、移动、改名和零长度删除例外五种变化，均 stale；纯查询顺序变化不改变 fingerprint。

- [ ] **Step 7: 回滚测试**

在清理第 N 条例外时失败，断言新规则、锚点资料和已删例外全部回滚。原规则和全部例外仍可展开。

- [ ] **Step 8: 运行测试**

```powershell
flutter test --no-pub test/domain/recurrence_membership_test.dart test/domain/recurrence_expander_test.dart test/data/course_write_gateway_test.dart test/application/course_edit_save_test.dart test/features/calendar/course_editor_page_test.dart
```

- [ ] **Step 9: 提交**

提交信息：`fix: prune course exceptions outside edited recurrence`。

## 12. Task 9 — 允许从同一图片恢复已删除课程

**Files:**
- Modify: `lib/data/repositories/drift_timetable_import_repository.dart`
- Modify: `lib/features/calendar/timetable_import/timetable_import_controller.dart`
- Modify: `test/data/timetable_import_repository_test.dart`
- Modify: `test/application/timetable_import_commit_test.dart`
- Modify: `test/features/calendar/timetable_import_page_test.dart`
- Modify: `test/app/timetable_import_route_test.dart`

**Interfaces:**
- Produces: 基于批次状态的同图重导入；事务内重复判断。
- Consumes: Task 7 的 `partiallyDeleted` 和现有逐课程重复检测。

- [ ] **Step 1: 把重复批次检查移入提交事务**

当前检查在事务外。改为在插入批次和系列的同一事务中检查 `committed`，避免检查通过后另一提交先落库。相同连接上的并发提交测试必须只有一个成功。

- [ ] **Step 2: 状态判定固定为 committed**

`partiallyDeleted`、`rolledBack`、`draft` 不抛 `DuplicateTimetableImportException`。不能用“当前剩余锚点数量”猜状态；删除事务已经负责写入明确状态。

- [ ] **Step 3: 重导入走完整预览**

同图重导入不能跳过 OCR/解析、课程重复预览或冲突预览。剩余课程应被识别为 exact duplicate 并默认 skip；已删课程无现存 occurrence，应生成 write。

- [ ] **Step 4: 防止逻辑课程内部半重复**

为一门多片段课程构造“整门课已删”和“只剩部分片段”的数据。课程管理的正常删除应只出现前者。若检测到后一种损坏状态，导入页必须标为需要人工确认，不能默认 create 全套导致重复剩余片段。

本任务不把现有 `update` 选项伪装成已实现；若 controller 仍对 `update` 执行 skip，应保留已有专项问题状态并在页面写清“保留现有课程”，不能声称更新了课程。

- [ ] **Step 5: 全部课程仍存在时保持幂等**

同学期同哈希 committed 批次仍返回“这张课表已经导入过，本次没有重复写入”，批次数和日历行数不变。

- [ ] **Step 6: 恢复后验证历史**

旧批次保持 partiallyDeleted；新批次为 committed；被恢复课程归属新批次；旧批次撤销不删除新批次课程。

- [ ] **Step 7: 运行测试**

```powershell
flutter test --no-pub test/data/timetable_import_repository_test.dart test/application/timetable_import_commit_test.dart test/features/calendar/timetable_import_page_test.dart test/app/timetable_import_route_test.dart
```

- [ ] **Step 8: 提交**

提交信息：`fix: allow reimport after course deletion`。

## 13. Task 10 — 增加持久导入记录与撤销入口

**Files:**
- Modify: `lib/domain/repositories/timetable_import_repository.dart`
- Modify: `lib/data/repositories/drift_timetable_import_repository.dart`
- Modify: `lib/application/timetable_import_service.dart`
- Create: `lib/features/calendar/timetable_import/timetable_import_history_page.dart`
- Modify: `lib/features/calendar/courses/course_management_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `test/data/timetable_import_repository_test.dart`
- Modify: `test/application/timetable_import_rollback_test.dart`
- Modify: `test/features/calendar/timetable_import_history_page_test.dart`
- Modify: `test/features/calendar/course_management_page_test.dart`
- Modify: `test/app/timetable_import_route_test.dart`
- Modify: `test/app/accessibility_semantics_test.dart`

**Interfaces:**
- Produces: `listHistory()`；`/calendar/import/history`；持久回滚入口。
- Consumes: 现有 `inspectRollback/rollback` 和 Task 5 状态。

- [ ] **Step 1: 定义历史读模型**

字段按 §2.6 固定。`canRollback` 与 `requiresForceConfirmation` 由仓储事实计算，页面不根据状态文案猜测。

- [ ] **Step 2: 用批量查询构建列表**

禁止每个批次调用一次 `inspectRollback()` 形成 N+1。一次查询批次和学期，一次查询相关锚点，一次查询相关例外，在内存按 batch id 分组。列表顺序用 UTC 创建时间降序，时间相同时按 batch id 保证确定性。

- [ ] **Step 3: 服务层提供统一动作**

`TimetableImportService.listHistory()` 只代理读；回滚仍走既有服务并在成功后发一次日历失效信号。失败、取消、未确认 force 时不发信号。

- [ ] **Step 4: 实现历史页状态**

必须覆盖加载、空、错误、正常四态：

- 空态：“还没有课表导入记录”，提供“导入课表”；
- 错误态：用户可读说明和“重试”；
- 正常态：文件名、学期、导入时间、原系列数、剩余数、状态；
- 不显示图片哈希、batch id 或数据库异常。

- [ ] **Step 5: 复用统一撤销对话框**

把 `router.dart` 中 `_undoTimetableImport()` 的确认流程提取为可由提示条和历史页共同调用的组件或协调器。两处文案、force 集合和失败处理必须一致。

- [ ] **Step 6: 添加课程管理入口和路由**

课程管理页标题行增加“导入记录”，具备 key、tooltip、语义标签和至少 44×44 点击区。路由缺少服务时显示 `_UnavailablePage`，不渲染死按钮。

- [ ] **Step 7: 回滚后的页面刷新**

成功回滚后重新加载历史列表和课程列表；日历通过已有失效总线刷新。rolledBack 行立即变为不可撤销。失败时列表保持原状态并提供重试，不能乐观地先移除。

- [ ] **Step 8: 重启可达测试**

使用同一个测试数据库重新创建 app/router，直接从课程管理进入历史页，完成撤销。测试不得依赖导入完成提示条仍存在。

- [ ] **Step 9: 可访问性与缩放**

键盘可打开记录、选择批次、取消/确认；屏幕阅读器读出文件名和状态；125%、150%、200% 文字缩放无溢出；1024 像素宽下操作仍可见。

- [ ] **Step 10: 运行测试**

```powershell
flutter test --no-pub test/data/timetable_import_repository_test.dart test/application/timetable_import_rollback_test.dart test/features/calendar/timetable_import_history_page_test.dart test/features/calendar/course_management_page_test.dart test/app/timetable_import_route_test.dart test/app/accessibility_semantics_test.dart
```

- [ ] **Step 11: 提交**

提交信息：`feat: add persistent timetable import history`。

## 14. Task 11 — 端到端、备份、隐私与回归验收

**Files:**
- Create: `integration_test/course_edit_integrity_and_import_recovery_test.dart`
- Modify: `test/application/backup_service_test.dart`
- Modify: `test/data/repository_round_trip_test.dart`
- Modify: `test/architecture/no_network_test.dart`
- Modify: `docs/testing/manual-windows-checklist.md`
- Create: `docs/testing/course-edit-integrity-and-import-recovery-acceptance.md`

**Interfaces:**
- Consumes: Tasks 2–10 的最终接口。
- Produces: 自动化和 Windows 人工验收证据；不发布。

- [ ] **Step 1: 端到端场景 A——课程改时间不再改坏资料**

导入一门含标题、教师、地点、领域、项目、Asia/Shanghai 时区和两个星期片段的课程 → 从课程详情进入唯一“编辑课程”入口 → 只修改钟点 → 预览并保存 → 重启。逐字段断言除目标时间外全部不变；日历和课程管理中不得出现“未命名事项”“无领域固定日程”或 UTC 时区漂移。

- [ ] **Step 2: 端到端场景 B——日视图改写保留隐藏字段**

从日视图对导入课程分别执行仅本次、此次及以后、整个序列，只改标题/备注/时间。重启后地点、领域、项目、类别、来源、批次和逻辑课程 id 不变；其它课程片段不受影响；三种范围与页面说明一致。

- [ ] **Step 3: 端到端场景 C——旧损坏识别与恢复**

导入旧版损坏夹具（占位标题 + 事件/规则时区不一致）→ 详情显示结构化提示但打开时零写入 → 取消手工修复后数据不变 → 手工修复成功后提示消失。另复制数据库走“删除后重导入”：删除预览列出例外损失 → 取消一次确认零写入 → 确认删除 → 同图重导成功 → 课程只出现一份且归属新批次。

- [ ] **Step 4: 端到端场景 D——编辑新增片段**

导入一门周一课程 → 管理课程新增周三片段 → 保存 → 重启 → 当前学期仍只显示一门课且有两个片段 → 导入记录撤销 → 两个片段、例外和规则全部删除。

- [ ] **Step 5: 端到端场景 E——删课与恢复**

导入 A/B → 删除 A → 历史显示部分删除 → 用同一图片重新导入 → 预览默认跳过 B、恢复 A → 日历 A/B 各一份 → 新旧批次历史均可解释。

- [ ] **Step 6: 端到端场景 F——缩短周次**

给第 4、10 周分别建立逐次调整 → 把课程从 1–16 周改为 1–8 周 → 预览显示保留第 4 周、删除第 10 周 → 保存并重启 → 再扩展回 1–16 周，第 10 周旧调整不复活。

- [ ] **Step 7: 端到端场景 G——取消与失败**

在删除确认、失效例外确认、受保护批次回滚确认分别取消，数据库逐表不变。注入事务失败后同样逐表不变。

- [ ] **Step 8: 备份往返**

用 v10 数据构造 committed、partiallyDeleted、rolledBack 批次和混合课程例外，导出、恢复后逐项一致。旧 v9 备份恢复再升级 v10 也必须通过。

- [ ] **Step 9: 隐私与网络边界**

静态检查新增代码没有 HTTP、socket、分析 SDK 或日志课表内容。错误提示可显示用户当前可见的课程名/文件名，但不得输出图片哈希、数据库绝对路径、用户名目录或 UUID。

- [ ] **Step 10: 格式、分析、全量测试**

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub integration_test/course_edit_integrity_and_import_recovery_test.dart -d windows
```

记录真实测试数量、耗时和提交哈希。不得沿用旧验收文档数字。

- [ ] **Step 11: Windows 人工矩阵**

在 100%、125%、150%、200% 缩放和 1024/1280/1920 三档窗口验证：受损课程提示、课程编辑预览、日视图三种范围、课程删除、同图重导入、导入记录、受保护回滚确认、重启后历史可达。每项记录期望、实际和截图路径。

- [ ] **Step 12: 安装升级验证**

仅在获得构建授权后，用 v9 正式版数据副本覆盖安装修复候选；确认迁移备份存在、升级后数据完整、卸载/重装不会误删用户库。不得拿用户唯一数据库做试验。

- [ ] **Step 13: 写验收记录**

`course-edit-integrity-and-import-recovery-acceptance.md` 每项写 PASS/FAIL/NOT RUN。任一 FAIL 回到所属 Task，修复后重跑定向测试、全量测试和受影响人工场景。

- [ ] **Step 14: 提交**

提交信息：`test: verify course import recovery end to end`。

## 15. 自动化验收矩阵

| 编号 | 场景 | 期望结果 | 测试层 |
| --- | --- | --- | --- |
| CE1 | 课程详情仅修改整门课钟点 | 标题、教师、地点、领域、项目、类别、来源、批次、逻辑课程 id 和规则时区逐值不变 | application + data + integration |
| CE2 | 日视图仅修改本次/以后/系列 | 未展示的地点、领域、项目、类别、来源和课程身份不被默认值清空 | application + widget + integration |
| CE3 | 多片段课程第二段写入失败 | 第一段也回滚，锚点、规则、例外和来源全部不变 | data + integration |
| TZ1 | Asia/Shanghai 00:00–07:59 课程 | 使用规则本地星期，不因 UTC 日期落到前一天 | unit + application |
| TZ2 | 跨午夜与含 DST 的规则时区 | 日期、星期、持续时长和周次成员均按 IANA 本地规则正确 | unit + application |
| LI1 | 导入课程为旧占位标题或事件/规则时区矛盾 | 显示结构化损坏提示，检测过程零写入 | data + widget |
| LI2 | 正常空教师/空地点或手工同名事项 | 不误报为旧版损坏 | unit + widget |
| LI3 | 手工补全受损课程 | 预览后一次事务保存，重启后提示消失且其它字段不变 | application + integration |
| LI4 | 删除受损课程后用原图恢复 | 明确例外损失、确认后删除、同图可重导且不复制仍存课程 | data + integration |
| API1 | 生产代码静态扫描 | `lib/` 中不存在旧 replace wrapper、legacy cache 或 fallback symbol | architecture |
| P1 | imported 课程新增片段 | 新旧锚点 batch/source 相同 | data + application + integration |
| P2 | 混合 null/单一 batch 存量 | 可保存并统一来源 | unit + data |
| P3 | 两个不同 batch | 阻止保存、零写入 | application |
| P4 | 新增片段后按批次撤销 | 新增片段也被删除 | data + integration |
| D1 | 删除课程 | 锚点、例外、独占规则全删 | data |
| D2 | 共享规则 | 仍有引用时规则保留 | data |
| D3 | 删除中途失败 | 四张表全部回滚 | data |
| D4 | 重复删除 | 第二次 0 变化 | data |
| B1 | 删除 imported 课程 | committed → partiallyDeleted | data |
| B2 | 删除 manual 课程 | 不改任何批次 | data |
| B3 | rolledBack/draft 异常数据删除 | 状态不被覆盖 | data |
| R1 | committed 同图重导 | 拦截且零写入 | data + UI |
| R2 | partiallyDeleted 同图重导 | 允许恢复缺失课程 | data + integration |
| R3 | rolledBack 同图重导 | 允许新批次 | data |
| R4 | 两个并发 committed 提交 | 仅一个成功 | data |
| E1 | 缩短 validUntil | 范围外例外预览并删除 | unit + data + UI |
| E2 | 改星期 | 旧星期例外删除 | unit + data |
| E3 | 每周改双周 | 错误周例外删除 | unit + data |
| E4 | 规则内例外 | 保留 | unit + data |
| E5 | 预览后例外变化 | stale，零写入 | application + data |
| H1 | 重启后打开历史 | 记录仍在 | route + integration |
| H2 | 受保护批次撤销 | 必须二次确认 | service + widget |
| H3 | 提示条快捷撤销 | 与历史页同结果 | route |
| H4 | rolledBack 历史 | 可见但不可再次撤销 | data + widget |
| M1 | v9 → v10 | 旧业务数据逐值不变 | migration |
| M2 | v10 非法 status | CHECK 拒绝 | migration/data |
| C1 | 无网络和隐私泄露 | 静态边界通过 | architecture |
| A1 | 键盘、语义、缩放 | 无死入口、无溢出 | widget + manual |

## 16. 禁止的捷径

- 不允许保留“缺标题就写 `未命名事项`、缺时区就写 `UTC`”的生产 fallback；这会把接口缺字段伪装成合法数据。
- 不允许页面用默认值拼出所谓“完整草稿”覆盖仓储中的隐藏字段；未编辑字段必须在事务内从权威记录保留。
- 不允许用循环单锚点写入代替整门课程事务；第二段失败时不得留下第一段已保存。
- 不允许用 UTC `.weekday`、设备默认时区或固定日期载体推导课程星期；必须先按规则 IANA 时区构造和校验本地日期时间。
- 不允许自动猜测旧损坏课程原来的名称、教师、地点、领域或项目；没有原始证据时只能要求用户确认补全，或备份后删除并从原课表重导。
- 不允许把新增课程片段固定写成 manual 后只在 UI 上补“属于原课程”的标签。
- 不允许从 `CourseSaveRequest` 接受页面传来的 batch id；页面数据可能过期或被伪造。
- 不允许继续让排序后的第一片段决定整门课的学期和批次。
- 不允许把 `partiallyDeleted` 写成 `draft`，不允许给旧哈希追加随机后缀来绕过重复检查。
- 不允许删除导入批次行；剩余课程有外键，而且历史和回滚都需要该行。
- 不允许只删除锚点而留下规则，也不允许不查引用就直接删规则。
- 不允许把课程删除与批次状态更新拆成两个事务或两个服务调用。
- 不允许用页面看到的周次直接删例外；必须使用与展开器相同的成员判定。
- 不允许预览报一个数字、保存时重新用另一套条件删除另一个数字。
- 不允许为解决 stale 竞态而关闭乐观并发或无条件覆盖新数据。
- 不允许把提示条停留时间延长当作持久撤销入口。
- 不允许历史页直接调用 Drift、拼 SQL 或绕过 `TimetableImportService`。
- 不允许在历史页显示内部 id、图片哈希或原始异常。
- 不允许手改 `app_database.g.dart`、`app_database.steps.dart` 或测试 schema 生成文件。
- 不允许迁移失败后自动创建空库覆盖旧库。
- 不允许只运行新增测试就宣布完成；必须通过全量测试和 Windows 主路径。
- 不允许在未获授权时构建、安装、发布、打 tag 或推送远程。

## 17. 剩余风险与明确边界

### 17.1 现有 `update` 重复课程选项并未真正更新

当前 controller 对 `TimetableDuplicateResolution.update` 与 skip 一样跳过写入。这是已有独立缺陷。本计划只保证“删掉整门课程后恢复缺失课程”和“不重复剩余课程”，不把 update 冒充已完成。若产品要支持“用新图片覆盖已修改课程”，应另建专项设计，明确覆盖范围和例外保留规则。

### 17.2 旧替换例外没有原发生日期

现有表只保存替换后的 `startAtUtc`，没有单独保存“它原本替换哪一次”。本计划按当前展开器使用的例外本地日期清理，能解决已确认的周次缩短复活问题，但不能可靠恢复历史上曾跨日期移动的例外来源。

若后续要求正确支持“把周一这次课移动到周二，同时仍以周一为例外键”，需要新增 `occurrence_key_utc` 或等价字段、迁移与展开器改造。不得在本计划内用猜测回填旧数据。

### 17.3 多批次冲突只阻止写入，不自动合并

同一逻辑课程关联多个非空批次属于异常数据。自动选择任一批次都会改变另一批次的回滚范围，因此本计划只显示错误并零写入。数据修复工具应在另一个有备份、预览和逐项确认的任务中设计。

### 17.4 旧版已经覆盖掉的课程资料无法无证据还原

现有导入批次只保存导入状态和图片哈希，不保存可重放的 OCR 原文或原课程快照。若旧版时间编辑已经把标题、教师、地点、领域或项目覆盖，数据库中可能已不存在原值。本计划可以可靠检测确定异常并阻止继续无提示传播，但不能凭空恢复真实资料。

允许的恢复路径只有两条：用户对照课表手工补全并确认，或先备份、删除受损课程，再从仍由用户持有的原课表图片重新导入。若两条路径都不可用，记录保持原样并继续显示“待核对”；不得静默改名、合并到同名课程或伪造来源。

## 18. 完成定义

以下条件缺一项都不能写“修复完成”：

- Task 1–11 的 checkbox 有对应提交、测试输出或人工记录；
- `lib/` 中已删除旧 `replaceOccurrence/replaceFollowingOccurrences/replaceSeries` 包装器、legacy title/timezone cache 及 fallback；所有调用点通过明确 patch 或课程快照事务迁移；
- 课程详情仅改时间、日视图三种范围改写都保留未展示字段，重启后不出现“未命名事项”“无领域固定日程”或 UTC 时区漂移；
- 多片段课程只有一次事务提交，任意片段失败时所有锚点、规则、例外和来源逐表不变；
- Asia/Shanghai 清晨、跨午夜和至少一个含 DST 的 IANA 时区矩阵通过，课程星期不再由 UTC `.weekday` 或固定载体日期决定；
- 旧版损坏检测零写入且不误报正常空字段；手工修复与删除后同图重导两条恢复路径均有通过证据；
- schemaVersion 为 10，v9 → v10 迁移、外键检查和迁移前备份通过；
- 新增课程片段继承来源，并在原学期可见、原批次可撤销；
- recoverableMixed 能修复，conflicting 被阻止且零写入；
- 删除课程同时清理例外、独占规则并标记 partiallyDeleted；
- 共享规则、幂等删除和四个失败注入用例通过；
- 同图重导入能恢复整门被删课程，且不复制仍存在课程；
- 规则成员纯函数由展开器和例外清理共同使用；
- 失效例外预览数等于实际删除数，规则内例外保留；
- 预览后并发变化会 stale，不会多删；
- 导入记录重启后可达，提示条与历史页共用回滚流程；
- 受保护批次未确认时零写入，确认后才回滚；
- 备份往返、无网络边界、隐私检查、格式检查和静态分析通过；
- 全量 Flutter 测试和 Windows 集成测试通过；
- Windows 缩放、键盘、重启和覆盖升级有真实记录；
- 验收文档没有把 NOT RUN 写成 PASS；
- 未经用户授权，没有安装、发布、tag、远程推送或改版本。

## 19. 执行交接模板

实施者完成后只允许按真实结果填写：

```markdown
## Course Editing Integrity / Lineage / Import Recovery — Handoff

### Scope
- Completed tasks:
- Deferred tasks and exact reason:

### Database
- Source schema:
- Target schema:
- Migration backup evidence:
- Foreign-key check:
- Row-by-row preservation evidence:

### Defect evidence
- Whole-course time edit metadata before/after:
- Day-view scoped edit hidden fields before/after:
- Multi-segment injected failure rollback:
- Asia/Shanghai early-morning and DST timezone matrix:
- Legacy damage detection and false-positive matrix:
- Manual repair and delete/reimport recovery evidence:
- Legacy wrapper/cache/fallback static scan:
- New-segment provenance before/after:
- Course deletion cleanup before/after:
- Same-image recovery before/after:
- Exception pruning before/after:
- Persistent history after restart:

### Verification
- Targeted tests:
- Full test count:
- Analyze:
- Windows integration:
- Manual scenarios:

### Safety
- Transaction rollback injections:
- Backup round trip:
- Network/privacy boundary:
- User database not used directly:
- No release/tag/push performed:

### Remaining risk
- Irrecoverable legacy metadata without source image:
- Duplicate update semantics:
- Legacy cross-date exception identity:
- Conflicting multi-batch courses:

### Status
- NOT COMPLETE / COMPLETE
```

