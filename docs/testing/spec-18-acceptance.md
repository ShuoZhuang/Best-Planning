# 需求规格 §18 首版验收清单——证据记录

本文件是 `docs/superpowers/specs/2026-10-01-personal-intelligent-scheduling-design.md` §18
那 19 项的**逐项证据**。规格要求"每项必须附自动化测试证据或手工验收记录"，本文件就是那份记录。

**本文件的口径（与规格一致，不放松）**

- **只写实际执行过、且能复现的东西**。每条证据都给出**文件路径与用例名**，可当场重跑。
- 强度分三档：**直接**（该用例就是在验证这一条）、**间接**（相关但没验证核心主张）、
  **无自动化证据**（需要手工验收记录，见 `docs/testing/manual-windows-checklist.md`）。
- **间接证据不算通过**。因此下面凡是靠间接证据的条目都保持未勾选。
- 手工验收**没有执行过**，因此不拿它充当任何一项的证据；手工清单里相关条目已标注出来，
  指出"这一项还需要人去点一遍"。

**本记录的来源状态**

| 项 | 值 |
| --- | --- |
| 记录日期 | 2026-10-03 |
| 提交 | `61dd18b`（本记录之前最后一次代码提交） |
| `flutter analyze` | No issues found! |
| `flutter test` | **470 项全部通过** |
| `flutter test integration_test -d windows` | 三条流程**逐条单独运行全部通过**（批量运行会在 loading 阶段因测试装置连接失败，与断言无关） |
| 手工验收清单 | **尚未执行** |

**怎么复现**

```powershell
# 先按技术设计 §13.0.9 设好 TEMP 与 PATH，再：
flutter analyze
flutter test
# 集成测试要逐条跑（批量运行会失败在测试装置连接上）：
flutter test integration_test/first_plan_flow_test.dart -d windows
flutter test integration_test/emergency_replan_flow_test.dart -d windows
flutter test integration_test/backup_restore_flow_test.dart -d windows
```

---

## 逐项证据

| # | 条目 | 结论 | 证据（文件 :: 用例名） | 强度 |
| --- | --- | --- | --- | --- |
| 1 | 全新安装后无需完整手动配置即可使用默认值生成首个计划 | **通过** | `integration_test/first_plan_flow_test.dart` :: 录入任务后可以生成、确认并在周视图看到首个七日计划；`test/app/app_smoke_test.dart` :: 首次启动先显示默认设置引导；`test/domain/default_settings_test.dart` :: 提供可立即排程的作息、精力和容量默认值 | 直接 |
| 2 | 首次引导允许用户查看、采用或修改所有关键默认值 | **通过** | `test/features/onboarding/onboarding_page_test.dart` :: 修改设置覆盖全部关键排程默认值并持久化；同上文件 :: 首次引导展示默认值且一键采用不会开启自动调整和应用锁；`test/app/app_smoke_test.dart` :: 首次启动先显示默认设置引导 | 直接 |
| 3 | 普通任务可在一分钟内完成快速录入 | **未通过（缺手工记录）** | `test/features/tasks/quick_add_test.dart` :: 快速录入可仅用键盘提交；`test/application/task_service_test.dart` :: 快速录入只需标题和预计时长并填充收集箱默认值 | 间接 |
| 4 | 固定日程、保护时间和锁定时间块不存在自动重叠 | **通过** | `test/scheduling/plan_validator_test.dart` :: 报告固定日程和保护时间重叠；`test/scheduling/availability_builder_test.dart` :: 合并重叠忙碌区间并保持半开边界可相邻；`test/scheduling/schedule_engine_test.dart` :: 任意两个任务块之间保留休息，不区分任务类型；`test/application/requested_move_test.dart` :: 拖到与固定日程重叠的位置时，冲突被报出来而不是静默覆盖 | 直接 |
| 5 | 系统可以生成未来七天计划并检查更远截止压力 | **通过** | `test/application/repository_schedule_problem_source_test.dart` :: 按本机时区计算未来七天的规划窗口；`test/scheduling/pressure_calculator_test.dart`（7 条，含"容量估计不会往前推超过 180 天"）；`test/scheduling/schedule_engine_test.dart` :: 远期任务会排入可排的最小量，而不是整周 0 分钟；`integration_test/first_plan_flow_test.dart` | 直接 |
| 6 | 可拆分任务和连续任务均按各自规则安排 | **通过** | `test/scheduling/candidate_generator_test.dart` :: generates 30 to 90 minute chunks at five-minute steps；同上文件 :: continuous tasks only produce a whole-task candidate；`test/scheduling/plan_validator_test.dart` :: 报告连续任务被拆分 | 直接 |
| 7 | 新增突发日程后能生成带原因的调整预览 | **通过** | `test/scheduling/plan_preview_test.dart` :: 断言原因文案（临近截止时间／匹配高精力时段／分成两个专注片段／当天容量不足／优先级较高）；`test/scheduling/plan_differ_split_test.dart` :: `_changeFor(diff, 'b').reason == 'priority'`；`test/scheduling/schedule_engine_test.dart` :: PlanDiffer identifies added, moved and removed blocks；`test/app/replan_prompt_test.dart` :: 点"查看调整"跳到该提案的预览页 | 直接 |
| 8 | 无可行方案时显示逾期风险、所缺时间和冲突来源 | **通过** | `test/scheduling/infeasible_schedule_test.dart` :: reports the exact shortage without scheduling into sleep；`test/scheduling/schedule_engine_time_zone_test.dart` :: 纽约时区下每天毫无空闲，任务必须报出缺口；`test/application/plan_generation_flow_test.dart` :: 开启信任但提案不可行时不应用，并说明原有计划保留；`test/domain/task_status_test.dart` :: 派生状态优先级：已结束 > 已逾期 > 进行中 > 已安排 > 用户状态 | 直接 |
| 9 | 临时晚归触发次日恢复保护且不永久修改常规作息 | **通过** | `integration_test/emergency_replan_flow_test.dart` :: 临时晚归后重排不会占用固定安排、保护时间或睡眠（**Windows 实机通过**）；`test/application/recovery_planning_service_test.dart`（3 条）；`test/application/repository_schedule_problem_source_test.dart` :: 一次性恢复例外进入排程输入但**不写入设置**；`test/features/calendar/special_day_test.dart` :: 最低睡眠与早课冲突时明确保留早课 | 直接 |
| 10 | 计划时长、实际时长和统计汇总一致 | **通过** | `test/application/analytics_service_test.dart` :: 自定义范围按交集区分计划和实际，并公开所有比例分母；`test/features/analytics/analytics_page_test.dart` :: 统计页同时显示计划、实际、分母、文本摘要和图表语义；`test/application/energy_periods_test.dart` :: 休息保护：被专注占用按**实际时长**折算，而不是按挂钟时长；`test/application/export_service_test.dart` :: CSV 使用 UTF-8 BOM 且计划和实际时间列明确分开 | 直接 |
| 11 | 统计支持今天、本周、本月和自定义日期范围 | **通过** | `test/features/analytics/analytics_page_test.dart` :: 统计页的四种时间范围都能切换出正确的窗口（本轮新增，并顺带查出与修掉了下面那条 UTC 日界缺陷）；`test/features/analytics/analytics_tag_filter_test.dart` :: 切换时间范围不会丢掉已选标签 | 直接 |
| 12 | 学习偏好可查看、确认、修改、停用和清除 | **通过** | `test/features/settings/preferences_page_test.dart` :: 用户可查看依据并确认、拒绝、停用、清除和撤销自动更新；同上文件 :: 修改学习建议后保持待确认且新值可见；`test/application/preference_service_test.dart` :: 拒绝、停用和清除均保留明确状态并可移除学习结果；`test/application/learned_preference_storage_test.dart` :: 清除学习结果会同时删除排程读取的那份偏好 | 直接 |
| 13 | 用户主动设置、已确认学习偏好与产品默认值按规定优先级生效 | **通过** | `test/application/settings_service_test.dart` :: 指定日期、用户规则、已确认偏好和默认值按优先级解析；`test/domain/default_settings_test.dart` :: 按临时例外、用户设置、已确认偏好和默认值的顺序解析；`test/application/preference_service_test.dart` :: 临时例外和用户设置优先于已确认偏好；`test/application/learned_preference_storage_test.dart` :: 用户主动设置优先于学习偏好 | 直接 |
| 14 | 偏好自动更新有记录、可解释且可撤销，不能静默修改硬约束 | **通过** | 记录：`test/application/preference_service_test.dart` :: 设置存储在服务重建后保留建议、偏好和自动采用撤销历史；可解释：`test/features/settings/preferences_page_test.dart` :: 用户可查看依据…；可撤销：`test/application/preference_service_test.dart` :: 自动采用只写入软偏好并可撤销，硬规则保持默认；不改硬约束：`test/application/settings_service_test.dart` :: 学习偏好不能更改用户保存的硬约束 | 直接 |
| 15 | 自动调整不能移动用户锁定的事项 | **通过** | `test/scheduling/plan_validator_test.dart` :: 报告锁定块被移动；`test/application/repository_schedule_problem_source_test.dart` :: 只有已锁定的已确认计划块进入 lockedBlocks；`test/scheduling/availability_builder_test.dart` :: 扣除睡眠、午餐、课程和锁定块后应用每日六小时上限；`test/application/requested_move_test.dart` :: 已锁定的块被拖动时也只剩一条，位置换成目标日 | 直接 |
| 16 | 异常退出后已确认计划和有效计时数据不丢失 | **通过（附下方注意事项）** | `test/application/focus_service_test.dart` :: 重启发现 running 记录时要求确认，时钟跳变不直接计入；`test/features/focus/recovery_wiring_test.dart` :: 进入专注页即提示确认上次未结束的计时；`test/platform/sqlite_database_lifecycle_adapter_test.dart` :: WAL 中残留已提交数据时备份快照仍然完整；`integration_test/backup_restore_flow_test.dart` | 直接 |
| 17 | 备份可验证并恢复，损坏备份不会覆盖现有数据 | **通过** | `test/application/backup_service_test.dart` :: 错误哈希、截断数据库、新 schema 和路径穿越全部被拒绝且**原库不变**；同上文件 :: 包含任务、计划和计时的数据库可完整备份并恢复；`test/app/backup_pending_restore_test.dart` :: 有待恢复文件时替换数据库，并留下**回滚副本**、清掉旧 sidecar；`integration_test/backup_restore_flow_test.dart`（Windows 实机通过） | 直接 |
| 18 | 用户可完整导出和永久清除自己的数据 | **未通过** | 导出：`test/app/export_route_test.dart` :: 侧边导航可以进入数据导出页；`test/features/settings/data/export_page_test.dart`；`test/application/export_service_test.dart`（2 条）。**永久清除**：`test/application/data_erasure_service_test.dart` :: 只有明确确认短语才清除数据库、索引、通知和锁凭据（服务层有测试） | 一半直接、一半**在真实用户路径上不可达** |
| 19 | 应用密码锁的保护边界有明确说明 | **通过** | `test/features/settings/app_lock/app_lock_unlock_test.dart` :: 说明它只挡正常界面、不宣称加密数据库；`test/features/settings/app_lock/app_lock_page_test.dart` :: 应用锁页面明确说明数据库未加密并要求两次输入一致；`lib/features/onboarding/onboarding_page.dart` 的"应用锁保持关闭"说明；`docs/release/windows-release.md` | 直接 |

---

## 未通过的 3 项：缺什么、谁来补

**第 3 项「普通任务可在一分钟内完成快速录入」——缺的是手工计时，不是功能。**
按钮、键盘提交、字段校验都有自动化覆盖（`quick_add_test`、`task_service_test`、`task_validation_test`），
但"**一分钟内**"是一个**操作耗时**主张，自动化测试无法证明。手工清单 `2.1`（一秒内创建成功）与
`2.2`（全程键盘）就是为它准备的，**尚未执行**。

**第 16 项「异常退出后已确认计划和有效计时数据不丢失」——已通过，但请注意它靠的是什么证据。**
自动化证据覆盖的是两件事：① 计时记录的崩溃恢复（重启发现 `running` 记录时要求确认、时钟跳变
不计入实际投入）；② 已提交数据的持久性（WAL 中的已提交内容进入快照并可完整恢复，含 Windows
实机）。**没有**自动化证据的是那个**端到端场景**："在生成计划的过程中强制结束进程，重启后已确认
计划仍在"。手工清单 `10.1` 正是它，**尚未执行**。因此本项按规格"自动化证据即可"通过，但那一条
手工场景仍然欠着——写在这里，免得它被这次勾选掩盖。

**第 18 项「用户可完整导出和永久清除自己的数据」——一半兑现，一半不可达。**
导出这条链路完整且有测试（服务、适配器、页面、路由）。
**永久清除不是这样**：`DataErasureService` 已实现且有自己的单测，`BackupPage` 也已经有那一块
界面（`widget.erasure != null` 时才渲染），但 **`lib/app/router.dart` 刻意不传 `erasure`**
（那里写着：永久清除同样需要"关库—换实例—重开"，因此先不显示该入口）。于是**真实用户路径上
没有这个入口**。这是"结构就绪 ≠ 需求兑现"的又一例：服务层与组件都在、有测试，用户却点不到。
**因此本项不勾选**，直到该入口接通并实测。

**接通它的做法已经查清（留给下一轮照做，避免重推）**——关键是把"删库"变成**延迟到启动时**，
与恢复那条链路同一个套路（`lib/app/backup_assembly.dart` 的 `preparePlannerDatabase()`）：

1. **为什么不能在运行中删**：`_PendingRestoreLifecycle.eraseAll()` 现在直接委托
   `SqliteDatabaseLifecycleAdapter.eraseAll()`，后者**立刻删除数据库文件与 `-wal`/`-shm`**。
   而运行中的 drift 连接仍指向那个文件（Windows 上还可能直接因共享冲突抛错）。两种结果都不好：
   前者是"界面还显示着数据、重启后才真的空"，后者更糟——`eraseAll` 在
   `DataErasureService` 里是**最后一步**，前面已经清掉了密码锁凭据与通知，删除失败就会留下
   **半清除状态**（锁没了、提醒没了、数据还在），而用户只会看到一个错误。
2. **具体改法**（三处）：
   - `backup_assembly.dart` 加 `pendingErasurePath(databasePath) => '$databasePath.erase-pending'`，
     并把 `_PendingRestoreLifecycle.eraseAll()` 改成**写这个标记文件**（与 `replaceWith` 写
     `.restore-pending` 完全对称）；
   - `preparePlannerDatabase()` 里在 `applyPendingRestoreFor` **之前**先看标记：存在就删除
     数据库与 sidecar，**并且一并删掉 `.restore-pending` 与 `.restore-old`**（否则一个残留的
     待恢复文件会在下次启动把数据搬回来），然后删掉标记。**顺序不能反**：若先应用恢复，
     被恢复的数据会存活一整个会话。
   - 组合根构造 `DataErasureService` 并传给 `/settings/backup` 路由。它要四样：
     `DatabaseLifecyclePort`（用上面那个延迟实现）、`BackupIndexPort`（`FileBackupIndexAdapter`
     目前**在生产里没有装配点**，需要一并决定它指向哪个索引文件）、`NotificationPort`
     （已有）、`AppLockCredentialStore`（已有 `SettingsAppLockCredentialStore`）。
3. **界面文案要如实**：因为删除发生在下次启动，提示必须写"**重启后生效**"，与恢复那条路径的
   措辞一致；`BackupPage` 里已经有一句"本机应用数据已永久清除；自行导出的外部文件未删除"，
   落到这条路径时也要点明范围（外部导出文件与用户自己的备份文件不在清除范围内）。

## 顺带查出并修掉的一处缺陷（本条不算任何一项的通过理由）

为第 11 项补证据时，新写的用例当场失败：统计页的"今天／本周／本月"按 **UTC** 取日界，而需求
§13／R11 要求按用户本机时区。对东八区用户，本地 00:00–08:00 之间打开统计页，"今天"会落到
**前一天**。已修（`61dd18b`，含把逐日推进从绝对时间加法改成日历加法——与 C11 同一处教训）。
**两条既有断言正是那个缺陷本身**（它们写的是 `DateTime.utc(2026, 10, 1)`），在提交信息里点明了
这一点，而不是悄悄改掉断言。
