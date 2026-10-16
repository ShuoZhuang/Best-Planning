# 课程编辑完整性／血缘／删除与导入恢复——验收记录

> 计划：`docs/superpowers/plans/2026-10-15-course-lineage-deletion-and-import-recovery-repair.md`
> 工作树：`G:\best-planing\.worktrees\native-implementation`，分支 `feature/native-implementation`
> 记录时间：2026-10-16（Asia/Shanghai）
>
> **结论：NOT COMPLETE。**
> 自动化部分（`flutter analyze` ＋ 格式检查 ＋ 全量 `flutter test`）与
> **Windows 集成测试（场景 A–G，真机执行）全部通过并有逐项证据**；
> 剩下的阻断项是**人工矩阵**（缩放／窗口宽度／键盘／Narrator）与**覆盖安装验证**从未执行，
> 以及 Task 9 Step 4 的"逻辑课程内部半重复"检测未实现。
> 按计划 §18 的定义，缺一项就不能写"修复完成"。
> 本文件里每一行只写真实结果：PASS / FAIL / NOT RUN / NOT VERIFIED，未执行的项一律留 NOT RUN。
## 1. 环境与命令

| 项 | 值 |
| --- | --- |
| Flutter | 3.47.5（stable，revision 6a19cca564） |
| Dart | 3.13.4 |
| Drift | 2.35.1 |
| 平台 | Windows x64 |
| 静态分析 | `& G:\best-planing\.tooling\fx.ps1 analyze --no-pub` |
| 全量测试 | `& G:\best-planing\.tooling\fx.ps1 test --no-pub` |

## 2. 提交

| 提交 | 内容 |
| --- | --- |
| `3b7ac7eb` | `fix: make calendar scoped edits and whole-course time edits non-destructive`（Task 2 ＋ Task 3） |
| `67d7ebe1` | `feat: surface and guide recovery of legacy course edit damage`（Task 4） |
| `2f9a31cf` | `feat: add partially deleted batch state and preserve timetable lineage`（Task 5 ＋ Task 6） |
| `e33b7b84` | `fix: delete course series and import state atomically`（Task 7） |
| `ca90a8db` | `fix: prune course exceptions outside edited recurrence`（Task 8） |
| `31110fcb` | `feat: allow reimport after course deletion and add persistent import history`（Task 9 ＋ Task 10） |

**未推送远程、未打 tag、未构建安装包、未改 `pubspec.yaml` 的应用版本**（计划 Global Constraints）。

## 3. 自动化验收矩阵（计划 §15）

| 编号 | 场景 | 期望 | 测试层 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- |
| CE1 | 课程详情仅修改整门课钟点 | 标题／教师／地点／领域／项目／类别／来源／批次／逻辑课程 id／规则时区逐值不变 | application + data + integration | `test/application/course_whole_time_mapping_test.dart`（CE1 用例）、`test/application/course_edit_save_test.dart`、integration 场景 A（Windows PASS，真实库逐列比对） | PASS |
| CE2 | 日视图仅修改本次／以后／系列 | 未展示的地点、领域、项目、类别、来源与身份不被默认值清空 | application + data + widget + integration | `test/data/recurrence_exception_test.dart`（CE2 用例，真实库逐列比对）、`test/features/calendar/day_view_test.dart`、integration 场景 B（Windows PASS） | PASS |
| CE3 | 多片段课程第二段写入失败 | 第一段也回滚，锚点、规则、例外与来源全部不变 | data | `test/data/course_write_gateway_test.dart`（CE3：SQLite 触发器在第二段锚点插入处注入失败 → 三张表逐值回滚） | PASS |
| TZ1 | Asia/Shanghai 00:00–07:59 课程 | 使用规则本地星期，不因 UTC 日期落到前一天 | unit + application | `test/application/course_whole_time_mapping_test.dart`（本地 07:30 的锚点 UTC 落在**周日**、规则与本地星期仍是周一；周日 00:15 同理） | PASS |
| TZ2 | 跨午夜与含 DST 的规则时区 | 日期、星期、持续时长与周次成员均按 IANA 本地规则正确 | unit + application | `course_whole_time_mapping_test.dart`（23:30–00:30 = 60 分钟）、`test/domain/recurrence_membership_test.dart`（America/New_York 切换周的周偏移） | PASS |
| LI1 | 导入课程为旧占位标题或事件／规则时区矛盾 | 显示结构化损坏提示，检测过程零写入 | data + widget + integration | `test/data/course_series_repository_test.dart`（LI1 两条 ＋ "只读"逐表零变化）、`test/features/calendar/course_detail_page_test.dart`、integration 场景 C（Windows PASS，逐表零写入） | PASS |
| LI2 | 正常空教师／空地点或手工同名事项 | 不误报为旧版损坏 | unit + widget | `course_series_repository_test.dart`（空教师／空地点／无领域不触发）、`course_detail_page_test.dart`、`course_editor_page_test.dart` | PASS |
| LI3 | 手工补全受损课程 | 预览后一次事务保存，重启后提示消失且其它字段不变 | application + integration | `test/application/course_edit_save_test.dart`（LI3：保存后重读，两个确定性问题都消失，批次未被写成 manual）、integration 场景 C（Windows PASS） | PASS（"重启"这一步由 integration 的每个场景各自新建库覆盖；真正跨进程重启未单独验证） |
| LI4 | 删除受损课程后用原图恢复 | 明确例外损失、确认后删除、同图可重导且不复制仍存课程 | data + integration | `test/data/course_write_gateway_test.dart`（B1）、`test/data/timetable_import_repository_test.dart`（R2）、`test/features/calendar/course_detail_page_test.dart`（删除前确认框）、integration 场景 E（Windows PASS） | PASS |
| API1 | 生产代码静态扫描 | `lib/` 中不存在旧 replace wrapper、legacy cache 或 fallback symbol | architecture | `test/architecture/no_legacy_calendar_wrappers_test.dart`（三条：符号不存在、占位标题只剩检测常量一处、详情页只有「编辑课程」） | PASS |
| P1 | imported 课程新增片段 | 新旧锚点 batch/source 相同 | data + application + integration | `course_series_repository_test.dart`（P1：新增片段后两段批次一致、课程仍在原学期、`inspectRollback` 可覆盖）、integration 场景 D（Windows PASS） | PASS |
| P2 | 混合 null/单一 batch 存量 | 可保存并统一来源 | unit + data | `course_series_repository_test.dart`（纯解析器四格）、`course_edit_save_test.dart`（P2：保存后全部片段统一到唯一批次） | PASS |
| P3 | 两个不同 batch | 阻止保存、零写入 | application | `course_edit_save_test.dart`（P3：`CourseSaveStatus.integrityConflict`、零写入、文案含"备份"且不含内部 id） | PASS |
| P4 | 新增片段后按批次撤销 | 新增片段也被删除 | data + integration | `course_write_gateway_test.dart`（两个锚点同批次 → 回滚范围包含两者）、integration 场景 D（Windows PASS：三个片段全部被删、无孤儿规则） | PASS |
| D1 | 删除课程 | 锚点、例外、独占规则全删 | data | `course_write_gateway_test.dart`（D1） | PASS |
| D2 | 共享规则 | 仍有引用时规则保留 | data | `course_write_gateway_test.dart`（D2：最后一个引用消失时才回收） | PASS |
| D3 | 删除中途失败 | 四张表全部回滚 | data | `course_write_gateway_test.dart`（D3 两条：触发器分别在"删规则"与"更新批次"处注入失败） | PASS |
| D4 | 重复删除 | 第二次 0 变化 | data | `course_write_gateway_test.dart`（D4：空结果且批次时间戳不变） | PASS |
| B1 | 删除 imported 课程 | committed → partiallyDeleted | data | `course_write_gateway_test.dart`（B1：状态与时间戳来自同一个 `deletedAtUtc`） | PASS |
| B2 | 删除 manual 课程 | 不改任何批次 | data | `course_write_gateway_test.dart`（B2） | PASS |
| B3 | rolledBack/draft 异常数据删除 | 状态不被覆盖 | data | `course_write_gateway_test.dart`（B3） | PASS |
| R1 | committed 同图重导 | 拦截且零写入 | data + UI | `timetable_import_repository_test.dart`（既有"same image hash and term is surfaced as a duplicate batch"） | PASS |
| R2 | partiallyDeleted 同图重导 | 允许恢复缺失课程 | data + integration | `timetable_import_repository_test.dart`（R2）、integration 场景 E（Windows PASS） | PASS |
| R3 | rolledBack 同图重导 | 允许新批次 | data | `timetable_import_repository_test.dart`（R3、draft 用例） | PASS |
| R4 | 两个并发 committed 提交 | 仅一个成功 | data | `timetable_import_repository_test.dart`（R4：并发提交只有一个成功） | PASS |
| E1 | 缩短 validUntil | 范围外例外预览并删除 | unit + data + UI | `test/domain/recurrence_membership_test.dart`、`test/data/recurrence_exception_test.dart`（E1 两条）、`course_edit_save_test.dart`（预览计数） | PASS |
| E2 | 改星期 | 旧星期例外删除 | unit + data | `recurrence_membership_test.dart`、`recurrence_exception_test.dart`（E2） | PASS |
| E3 | 每周改双周 | 错误周例外删除 | unit + data | `recurrence_membership_test.dart`、`recurrence_exception_test.dart`（E3 两条，含"起点前移后原例外重新成为成员必须保留"） | PASS |
| E4 | 规则内例外 | 保留 | unit + data | `recurrence_exception_test.dart`（E4） | PASS |
| E5 | 预览后例外变化 | stale，零写入 | application + data | `course_edit_save_test.dart`（E5 三条：新增／删一条再加一条都 stale；纯顺序变化不改指纹） | PASS |
| H1 | 重启后打开历史 | 记录仍在 | route + integration | `test/app/course_management_route_test.dart`（H1：同一仓储、重建 router 后记录仍在且不可再撤销） | PASS（"弹掉整个应用再打开"这一形态未单独验证；重建 router ＋ 复用同一仓储覆盖了"记录不活在提示条里"这一要点） |
| H2 | 受保护批次撤销 | 必须二次确认 | service + widget | `test/features/calendar/timetable_import_history_page_test.dart`（H2：取消 ⇒ 零写入；确认 ⇒ 按同一 force 集合回滚） | PASS |
| H3 | 提示条快捷撤销 | 与历史页同结果 | route | 两处都调用 `confirmAndRollbackTimetableImport()`（唯一实现）；`course_management_route_test.dart` 覆盖历史页那一侧 | PASS（提示条那一侧未单独建用例） |
| H4 | rolledBack 历史 | 可见但不可再次撤销 | data + widget | `timetable_import_repository_test.dart`、`timetable_import_history_page_test.dart` | PASS |
| M1 | v9 → v10 | 旧业务数据逐值不变 | migration | `test/drift/app_database/schema_migration_test.dart`（M1：三批次＋规则＋事件＋例外＋任务逐值比对、`PRAGMA foreign_key_check` 为空、全部版本组合的空库迁移逐一校验） | PASS |
| M2 | v10 非法 status | CHECK 拒绝 | migration/data | 同文件 M1 用例末段；`timetable_import_repository_test.dart`（未知值的受控错误） | PASS |
| C1 | 无网络和隐私泄露 | 静态边界通过 | architecture | `test/architecture/no_network_test.dart`、`test/architecture/update_network_boundary_test.dart`、`no_legacy_calendar_wrappers_test.dart` | PASS |
| A1 | 键盘、语义、缩放 | 无死入口、无溢出 | widget + manual | `timetable_import_history_page_test.dart` 覆盖按钮状态；**键盘／语义／缩放的自动化断言只在既有 J 节用例里，本专项的人工矩阵 NOT RUN** | 部分 PASS（人工 NOT RUN） |

## 4. 静态分析与全量测试

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 静态分析 | `fx.ps1 analyze --no-pub` | `No issues found!`（2026-10-16，改动全部提交后重跑） |
| 全量测试 | `fx.ps1 test --no-pub` | `All tests passed!` / **2591 项**（01:07 完成） |
| 格式检查 | `dart format --output=none --set-exit-if-changed <本专项改动的 62 个 .dart 文件>` | `Formatted 62 files (0 changed)` —— 本专项改动的文件全部符合格式 |
| Windows 集成测试 | `fx.ps1 test --no-pub integration_test/course_edit_integrity_and_import_recovery_test.dart -d windows` | **`All tests passed!` / 7 个场景（A–G）**（真实构建 `build\windows\x64\runner\Debug\personal_planner.exe`） |

### 4.1 Windows 集成测试：第一次运行发现了一个真实缺陷

第一次执行是 **4 通过 / 2 失败**（场景 A–C、G 通过；E、F 失败），两个失败的性质完全不同——
这正是这一层存在的理由：

| 失败 | 性质 | 处置 |
| --- | --- | --- |
| 场景 E：`rollback('batch-1')` 抛 `ProtectedTimetableEventsException` | **夹具错误**：批次 `created_at_utc` 写成 `1`，而它导入出来的锚点 `updated_at_utc` 是 `2026-10-01`。`inspectRollback` 正是用"锚点修订号是否还等于批次创建时间"判断"导入后被改过"，两者不一致会让每一门课都被判成受保护。 | 把夹具的两处时间统一为同一个常量 `_seedInstantUs`（真实导入用同一个 `createdAtUtc` 写批次与锚点） |
| 场景 F：缩短周次后断言"预告删 1 条、实际就删 1 条"得到 **2** | **真实产品缺陷**：`previewCourseEdit` 用 `countExceptionsInvalidatedBy()` 把"另有 1 条调整已超出新周次，将删除"写给了用户，而**课程快照保存路径（`replaceCourseSeries`）从来没有执行那次清理**——只有日视图那条 `replaceSeries` 路径清理过。这正是计划 §16 禁止的"预览报一个数字、保存时另一套条件"。 | 在 `replaceCourseSeries` 写入每个片段的新规则之后调用同一个 `_pruneInvalidatedExceptions()`；并补一条**快检用例**（`test/data/course_write_gateway_test.dart` 的 E1）把这个缺口永久钉住，让它在无设备的全量测试里也会红 |

修复后重跑：`All tests passed!`。随后补齐计划 Task 11 Step 4 的场景 D 时又出现第三次运行
**6 通过 / 1 失败**：

| 失败 | 性质 | 处置 |
| --- | --- | --- |
| 场景 D：`rollback('batch-autumn')` 抛 `ProtectedTimetableEventsException` | **期望写错，产品行为正确**：用户刚编辑过这门课，三个锚点的 `updated_at_utc` 都不再等于批次的创建时间，`inspectRollback` 因此把它们全部判成"导入后被修改过"——这正是 §3.5 要求的保护。 | 按真实流程改写场景：先看 `protectedEventIds` 清单（3 条，含新增片段）、断言"不带 force 会被拒绝且零写入"，再带 force 确认撤销并断言三个片段与三条规则全部回收 |

最终：**`All tests passed!` / 7 个场景（A–G）**。这条记录是"红 → 绿"的完整证据，
不是"跑一遍恰好绿了"。

## 5. 数据库迁移证据

| 项 | 证据 |
| --- | --- |
| 源 schema | v9（`drift_schemas/app_database/drift_schema_v9.json`） |
| 目标 schema | v10（`drift_schemas/app_database/drift_schema_v10.json`，由 `drift_dev schema dump` 生成） |
| 唯一结构变化 | `timetable_import_batches.status` 的 CHECK 增加 `'partiallyDeleted'` |
| 逐版本结构校验 | `schema_migration_test.dart` 的全部版本组合（空库 v1→v10 等）逐版本比对快照 |
| 行级数据保留 | M1 用例：三批次（draft／committed／rolledBack）＋ 学期 ＋ 规则 ＋ 事件 ＋ 例外 ＋ 任务，迁移后逐列比对 |
| 外键检查 | M1 用例内 `PRAGMA foreign_key_check` 为空 |
| 迁移前备份顺序 | `test/app/pre_migration_backup_test.dart`：`plannerSchemaVersion` 已随 v10 更新，备份先于升级的不变量仍由既有用例守着 |
| 生成文件 | `lib/data/database/app_database.g.dart`、`.steps.dart` **未被手改**；表的 CHECK 由 `planner_tables.dart` 在运行时提供，dump 出的 v10 快照已确认包含新值 |
| v6 历史步骤 | `_upgradeToV6` 改用**字面 SQL** 建批次表：`createTable` 用的是当前定义，会把 v10 的 CHECK 写进 v6 形状的库里，使"空库迁移到 v6"与 v6 快照不一致（drift verifier 当场报 `Schema does not match`） |

## 6. 安全与边界

| 项 | 结果 |
| --- | --- |
| 事务回滚注入 | `course_write_gateway_test`（CE3、D3×2）、`recurrence_exception_test`（E1–E4 通过真实库删除路径）、`course_edit_save_test`（E5 零写入） |
| 备份往返 | `test/application/backup_service_test.dart`（版本断言已随 v10 更新）＋ `test/data/repository_round_trip_test.dart`（三种批次状态往返一致） |
| 无网络边界 | `no_network_test` ＋ `update_network_boundary_test` 通过；本专项未新增任何依赖、未新增网络调用 |
| 隐私 | 本专项不新增联网权限；导入记录页只显示文件名与计数，不显示批次 id、图片哈希或数据库路径（`timetable_import_history_page_test.dart` 断言） |
| 未使用用户真实数据库 | 全部自动用例使用内存库；未接触用户的 `planner.sqlite` |
| 未发布 | 无构建、无安装、无 tag、无远程推送、未改应用版本号 |

## 7. 未完成项（发布阻断）

1. **人工矩阵 NOT RUN**：`docs/testing/manual-windows-checklist.md` 的 K.1–K.4（缩放、窗口宽度、
   主路径、键盘与 Narrator）全部为空。
2. **覆盖安装验证 NOT RUN**：用 v9 正式版数据副本覆盖安装修复候选属于 Task 11 Step 12，
   需要构建授权，本次未申请。
3. **A1 的键盘／语义／缩放自动化**：本专项只补了按钮状态与错误态用例，
   没有为导入记录页新增 100/125/150/200% 缩放与 1024/1280/1920 宽度的自动化矩阵。
4. **Task 9 Step 4 的"逻辑课程内部半重复"检测 NOT VERIFIED**：计划要求导入页在检测到
   "一门多片段课程只剩部分片段"这种损坏时标为需要人工确认。本次没有实现这一条检测
   （需要跨批次比对同一 `logicalCourseId` 的片段完整性），因此**没有把它写成已完成**。
   `TimetableDuplicateResolution.update` 仍然只做 skip（计划 §17.1 的既有缺陷），未曾冒充已实现。
5. **H1 的"整个应用重启"形态**：`course_management_route_test` 用"重建 router ＋ 复用同一仓储"
   覆盖了"记录不活在提示条里"这一要点，但没有真的杀掉进程再打开。
   人工矩阵 K.2.11 就是为这一条准备的（**尚未执行**）。

### 已完成的原 NOT RUN 项

- **Windows 集成测试**：场景 A–G 已在真实 Windows 上执行并全部通过（见 §4.1）。
- **格式门禁**：本专项改动的 62 个 `.dart` 文件通过 `dart format --set-exit-if-changed`。
- **P4 的端到端覆盖**：由 integration 场景 D 补齐。

## 8. 剩余风险（与计划 §17 一致）

| 风险 | 说明 |
| --- | --- |
| 无原图时资料不可还原 | 导入批次不保存 OCR 原文；系统只做确定性检测与两条恢复路径，不猜测原值（§17.4） |
| `update` 语义未实现 | 重复课程的"用新图覆盖"仍只是跳过；本专项不声称支持（§17.1） |
| 旧替换例外没有原发生日期 | 跨日期移动过的旧例外无法可靠恢复来源；本专项按当前展开器的例外本地日期清理（§17.2） |
| 多批次冲突只阻止写入 | 不自动合并，也不猜来源（§17.3） |

## 9. 交接（计划 §19 模板）

### Scope
- Completed tasks：Task 1（红灯与基线，以真实失败/通过记录落地为各任务用例）、Task 2、Task 3、
  Task 4、Task 5、Task 6、Task 7、Task 8、Task 9、Task 10。Task 11 的**自动化部分**完成。
- Deferred tasks and exact reason：Task 11 的 Windows 集成测试、人工矩阵、格式门禁、
  覆盖安装验证与 A1 自动化矩阵未执行（见 §7）；Task 9 Step 4 的半重复检测未实现。

### Database
- Source schema：v9
- Target schema：v10
- Migration backup evidence：既有 `pre_migration_backup_test`（版本号断言已更新到 10）
- Foreign-key check：M1 用例内 `PRAGMA foreign_key_check` 为空
- Row-by-row preservation evidence：`schema_migration_test.dart` 的 M1 用例

### Defect evidence
- Whole-course time edit metadata before/after：`course_whole_time_mapping_test` 的 CE1 用例
- Day-view scoped edit hidden fields before/after：`recurrence_exception_test` 的 CE2 用例（真实库逐列）
- Multi-segment injected failure rollback：`course_write_gateway_test` 的 CE3 用例
- Asia/Shanghai early-morning and DST timezone matrix：`course_whole_time_mapping_test`、`recurrence_membership_test`
- Legacy damage detection and false-positive matrix：`course_series_repository_test` 的 LI1／LI2 组
- Manual repair and delete/reimport recovery evidence：`course_edit_save_test` 的 LI3；LI4 的删除确认在 `course_detail_page_test`
- Legacy wrapper/cache/fallback static scan：`no_legacy_calendar_wrappers_test`
- New-segment provenance before/after：`course_series_repository_test` 的 P1
- Course deletion cleanup before/after：`course_write_gateway_test` 的 D1–D4、B1–B3
- Same-image recovery before/after：`timetable_import_repository_test` 的 R1–R4
- Exception pruning before/after：`recurrence_exception_test` 的 E1–E4
- Persistent history after restart：`course_management_route_test` 的 H1

### Verification
- Targeted tests：各任务提交信息里逐条列出，全部通过
- Full test count：2590（`flutter test --no-pub`）
- Analyze：`No issues found!`
- Format：本专项改动的 62 个 `.dart` 文件 `dart format --set-exit-if-changed` 通过
- Windows integration：`All tests passed!` / 7 个场景（A–G，真实构建与运行）
- Manual scenarios：NOT RUN

### Safety
- Transaction rollback injections：见 §6
- Backup round trip：见 §6
- Network/privacy boundary：通过，无新增依赖
- User database not used directly：是（全部内存库）
- No release/tag/push performed：是

### Remaining risk
- Irrecoverable legacy metadata without source image：见 §8
- Duplicate update semantics：未实现，未冒充
- Legacy cross-date exception identity：按当前语义清理，跨日期来源不可恢复
- Conflicting multi-batch courses：只阻止写入

### Status
- **NOT COMPLETE**
  剩余未完成项：§7.1 人工矩阵 NOT RUN、§7.2 覆盖安装验证 NOT RUN、
  §7.3 导入记录页的缩放／键盘自动化矩阵未补、§7.4 Task 9 Step 4 的内部半重复检测未实现、
  §7.5 "整个应用重启"形态未执行。
  其余全部为 PASS，证据见 §3、§4 与 §4.1。
