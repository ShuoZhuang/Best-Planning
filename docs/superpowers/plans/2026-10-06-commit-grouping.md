# 提交分组清单（审阅用 · 尚未提交）

> 本文件只是**分组提案**，还没有执行任何 `git add` / `git commit`。
> 等你看过并确认口径后再落库。

## 先说一个硬约束：C1–C4 无法真正拆开

我按「每份计划声明的文件清单」做了归属（不是凭印象），结果发现三份计划在**文件级别互相咬合**：

| 咬合点 | 文件 | 为什么拆不开 |
| --- | --- | --- |
| 数据库 schema | `planner_tables.dart`、`app_database.dart`、`app_database.g.dart`、`app_database.steps.dart`、`schema.dart`、`schema_migration_test.dart` | 同一个文件里同时含 v4 + v5 + v6；`app_database.g.dart` 是 Drift **生成代码**，按 hunk 拆会直接损坏 |
| 生产装配 | `main.dart`、`planner_app.dart`、`router.dart` | C4 的 `main.dart` 引用 C3 的 `TimetableImportService`，而 C3 的仓储又引用 C4 的 v6 表——**互为前提，成环** |
| 领域模型 | `calendar_event.dart`、`drift_calendar_repository.dart` | 同时被计划二与计划三改动 |
| 共用测试 | `repository_round_trip_test.dart`、`settings_hub_test.dart` | 同时含两份计划的断言 |

后果：**没有任何一种提交顺序能让中间提交独立编译通过**；只有最终状态是绿的（我实测 654/654、analyze 干净）。所以按「计划一 / 计划二 / 计划三」拆成三个提交，只能靠改写生成代码的 hunk 来实现——我不建议，收益是名义上的可二分，代价是引入损坏风险。

## 另一个必须说明的：发布后 OCR 修复拆不出来

「发布后 OCR 修复」（`decode_failed` → 改读字节喂 `BitmapDecoder`，1.0.7+9）改的就是计划三任务 2 的那两个文件（`windows/runner/timetable_ocr_channel.cpp`、`lib/platform/ocr/windows_timetable_ocr.dart`）。它们现在是未提交状态，文件里已经是修好的版本，**没有办法再单独成一个提交**，只能连同计划三一起提交并在提交信息里注明。

导出修复（1.0.8+10）则是真正独立的文件，可以单独成提交。

## 我建议的落库形状（5 个提交）

| 提交 | 内容 | 文件数 |
| --- | --- | --- |
| A | 三份计划（C1+C2+C3+C4，含发布后 OCR 修复） | 121 |
| B | 导出改造（C5） | 6 |
| C | 外观与玻璃材质（C6） | 9 |
| D | 通知与平台诊断（C7） | 7 |
| E | 其余既有改动（C8）——**归属不明，需要你定** | 60 |

E 那 60 个文件我无法从三份计划里归属：里面既有看起来像计划涟漪的（`analytics_service`、`today_page`、`time_zone` 已单列到 C4），也有明显属于别的主题的（`focus_page`、`relaxation_page`、`quick_add_form.dart` 被删除、一批 planning/replan/preferences 测试）。台账当初把这些称为「用户自己的改动」。**我不打算在没有你确认的情况下把它们打包提交**——那正是你一开始想避免的那种无法审查的大提交。

如果你认可，我就按 A→B→C→D 落库，E 先留着不动。

---




## C1 · 计划一：领域归属与最早开始约束  —— 28 个文件

- `drift_schemas/app_database/drift_schema_v4.json`
- `lib/application/input_snapshot_builder.dart`
- `lib/application/repository_schedule_problem_source.dart`
- `lib/application/task_service.dart`
- `lib/application/workspace_service.dart`
- `lib/data/database/daos/analytics_dao.dart`
- `lib/data/repositories/drift_life_area_lookup.dart`
- `lib/data/repositories/drift_task_repository.dart`
- `lib/domain/models/task.dart`
- `lib/features/tasks/task_detail_page.dart`
- `lib/features/tasks/task_editor_page.dart`
- `lib/features/workspace/workspace_management_page.dart`
- `lib/scheduling/candidate_generator.dart`
- `lib/scheduling/schedule_problem.dart`
- `test/app/app_smoke_test.dart`
- `test/application/repository_schedule_problem_source_test.dart`
- `test/application/task_project_assignment_test.dart`
- `test/application/task_service_test.dart`
- `test/application/workspace_service_test.dart`
- `test/data/analytics_dao_test.dart`
- `test/data/life_area_lookup_test.dart`
- `test/drift/app_database/generated/schema_v4.dart`
- `test/features/tasks/task_detail_page_test.dart`
- `test/features/tasks/task_editor_page_test.dart`
- `test/features/tasks/task_project_picker_test.dart`
- `test/features/workspace/workspace_management_page_test.dart`
- `test/scheduling/candidate_generator_test.dart`
- `test/scheduling/schedule_engine_test.dart`

## C2 · 计划二：按周间隔重复与学业日历  —— 23 个文件

- `drift_schemas/app_database/drift_schema_v5.json`
- `lib/application/academic_calendar_service.dart`
- `lib/application/calendar_service.dart`
- `lib/data/repositories/drift_academic_calendar_repository.dart`
- `lib/domain/models/academic_calendar.dart`
- `lib/domain/repositories/academic_calendar_repository.dart`
- `lib/domain/repositories/calendar_event_deletion.dart`
- `lib/domain/services/recurrence_expander.dart`
- `lib/features/calendar/day_view/day_view_page.dart`
- `lib/features/calendar/event_editor/event_editor_form.dart`
- `lib/features/settings/academic_calendar/academic_calendar_page.dart`
- `lib/features/settings/academic_calendar/period_template_editor.dart`
- `test/application/academic_calendar_service_test.dart`
- `test/application/calendar_replan_events_test.dart`
- `test/data/academic_calendar_repository_test.dart`
- `test/data/calendar_event_deletion_test.dart`
- `test/data/recurrence_exception_test.dart`
- `test/domain/academic_calendar_test.dart`
- `test/domain/recurrence_expander_test.dart`
- `test/drift/app_database/generated/schema_v5.dart`
- `test/features/calendar/day_view_test.dart`
- `test/features/calendar/event_editor_test.dart`
- `test/features/settings/academic_calendar_page_test.dart`

## C3 · 计划三：本地课表导入（含发布后 OCR 修复）  —— 42 个文件

- `docs/智能日程使用教程.md`
- `docs/testing/manual-windows-checklist.md`
- `drift_schemas/app_database/drift_schema_v6.json`
- `integration_test/timetable_import_flow_test.dart`
- `integration_test/windows_timetable_ocr_native_test.dart`
- `lib/application/timetable_conflict_detector.dart`
- `lib/application/timetable_import_service.dart`
- `lib/data/repositories/drift_timetable_import_repository.dart`
- `lib/domain/models/timetable_import.dart`
- `lib/domain/ocr/timetable_ocr.dart`
- `lib/domain/repositories/timetable_import_repository.dart`
- `lib/domain/services/timetable_parser.dart`
- `lib/features/calendar/timetable_import/period_step.dart`
- `lib/features/calendar/timetable_import/preview_step.dart`
- `lib/features/calendar/timetable_import/review_step.dart`
- `lib/features/calendar/timetable_import/term_step.dart`
- `lib/features/calendar/timetable_import/timetable_import_controller.dart`
- `lib/features/calendar/timetable_import/timetable_import_page.dart`
- `lib/features/calendar/timetable_import/upload_step.dart`
- `lib/features/calendar/week_view/week_view_page.dart`
- `lib/platform/ocr/windows_timetable_ocr.dart`
- `pubspec.yaml`
- `test/app/timetable_import_route_test.dart`
- `test/application/timetable_conflict_detector_test.dart`
- `test/application/timetable_import_commit_test.dart`
- `test/application/timetable_import_preview_test.dart`
- `test/application/timetable_import_privacy_test.dart`
- `test/application/timetable_import_rollback_test.dart`
- `test/architecture/no_network_test.dart`
- `test/data/timetable_import_repository_test.dart`
- `test/domain/timetable_ocr_contract_test.dart`
- `test/domain/timetable_parser_test.dart`
- `test/drift/app_database/generated/schema_v6.dart`
- `test/features/calendar/timetable_import_page_test.dart`
- `test/features/calendar/week_view_test.dart`
- `test/fixtures/timetable/desktop_grid_ocr.json`
- `test/fixtures/timetable/mobile_grid_ocr.json`
- `test/platform/windows_timetable_ocr_test.dart`
- `windows/runner/CMakeLists.txt`
- `windows/runner/flutter_window.cpp`
- `windows/runner/timetable_ocr_channel.cpp`
- `windows/runner/timetable_ocr_channel.h`

## C4 · 三份计划的共用装配与迁移链（含统计/今日页/时区/集成测试涟漪）  —— 28 个文件

- `integration_test/backup_restore_flow_test.dart`
- `integration_test/emergency_replan_flow_test.dart`
- `integration_test/first_plan_flow_test.dart`
- `lib/app/planner_app.dart`
- `lib/app/router.dart`
- `lib/application/analytics_service.dart`
- `lib/core/time_zone.dart`
- `lib/data/database/app_database.dart`
- `lib/data/database/app_database.g.dart`
- `lib/data/database/app_database.steps.dart`
- `lib/data/database/tables/planner_tables.dart`
- `lib/data/repositories/drift_calendar_repository.dart`
- `lib/domain/models/analytics.dart`
- `lib/domain/models/calendar_event.dart`
- `lib/features/analytics/analytics_page.dart`
- `lib/features/settings/settings_hub_page.dart`
- `lib/features/today/today_page.dart`
- `lib/main.dart`
- `test/app/analytics_route_test.dart`
- `test/app/settings_hub_test.dart`
- `test/core/local_time_zone_test.dart`
- `test/core/time_zone_test.dart`
- `test/data/repository_round_trip_test.dart`
- `test/drift/app_database/generated/schema.dart`
- `test/drift/app_database/schema_migration_test.dart`
- `test/features/analytics/analytics_page_test.dart`
- `test/features/today/today_page_test.dart`
- `test/scheduling/schedule_engine_time_zone_test.dart`

## C5 · 发布后修复：导出改用保存对话框  —— 6 个文件

- `lib/application/export_service.dart`
- `lib/data/repositories/drift_export_data_source.dart`
- `lib/features/settings/data/export_page.dart`
- `test/app/export_route_test.dart`
- `test/application/export_service_test.dart`
- `test/features/settings/data/export_page_test.dart`

## C6 · 外观与玻璃材质  —— 9 个文件

- `design-system/default/MASTER.md`
- `lib/application/appearance_service.dart`
- `lib/design/planner_glass.dart`
- `lib/design/planner_theme.dart`
- `lib/features/settings/appearance/appearance_page.dart`
- `lib/platform/files/file_appearance_mode_store.dart`
- `test/application/appearance_service_test.dart`
- `test/design/planner_glass_test.dart`
- `test/platform/file_appearance_mode_store_test.dart`

## C7 · 通知与平台诊断  —— 7 个文件

- `lib/application/notification_service.dart`
- `lib/platform/notifications/diagnostic_notification_port.dart`
- `lib/platform/windows/windows_package_identity.dart`
- `test/application/notification_kinds_test.dart`
- `test/platform/diagnostic_notification_port_test.dart`
- `test/platform/windows_notification_activator_config_test.dart`
- `test/platform/windows_package_identity_test.dart`

## C8 · 其余既有未提交改动（归属待确认）  —— 60 个文件

- `docs/superpowers/plans/2026-10-05-execution-status.md`
- `docs/superpowers/plans/2026-10-05-local-timetable-import.md`
- `docs/superpowers/plans/2026-10-05-recurrence-and-academic-calendar.md`
- `docs/superpowers/plans/2026-10-05-task-classification-and-start-constraint.md`
- `docs/testing/flow-verification.md`
- `lib/app/backup_assembly.dart`
- `lib/application/pending_moves.dart`
- `lib/application/planning_rule_resolver.dart`
- `lib/application/planning_service.dart`
- `lib/application/recovery_planning_service.dart`
- `lib/data/repositories/drift_preference_evidence_repository.dart`
- `lib/domain/models/workspace.dart`
- `lib/domain/repositories/plan_repository.dart`
- `lib/features/calendar/special_day/special_day_page.dart`
- `lib/features/calendar/week_view/schedule_view_source.dart`
- `lib/features/focus/focus_page.dart`
- `lib/features/planning/plan_preview_page.dart`
- `lib/features/settings/relaxation/relaxation_page.dart`
- `lib/features/tasks/quick_add_form.dart`
- `lib/features/tasks/task_list_page.dart`
- `lib/platform/files/file_selector_adapter.dart`
- `lib/scheduling/schedule_engine.dart`
- `test/app/app_lock_gate_test.dart`
- `test/app/calendar_event_route_test.dart`
- `test/app/focus_route_test.dart`
- `test/app/planner_database_path_test.dart`
- `test/app/preferences_route_test.dart`
- `test/app/replan_prompt_test.dart`
- `test/app/special_day_route_test.dart`
- `test/app/workspace_route_test.dart`
- `test/application/energy_periods_test.dart`
- `test/application/learned_preference_storage_test.dart`
- `test/application/plan_application_service_test.dart`
- `test/application/planning_service_test.dart`
- `test/application/preference_evidence_loop_test.dart`
- `test/application/replan_events_test.dart`
- `test/application/replanning_coordinator_test.dart`
- `test/application/requested_move_test.dart`
- `test/application/suggestion_events_test.dart`
- `test/application/task_preferred_window_test.dart`
- `test/application/task_remaining_correction_test.dart`
- `test/data/database_schema_test.dart`
- `test/data/rest_protection_windows_test.dart`
- `test/data/task_correction_log_test.dart`
- `test/data/workspace_repository_test.dart`
- `test/domain/schedule_rule_override_test.dart`
- `test/domain/task_status_test.dart`
- `test/features/focus/pause_reason_test.dart`
- `test/features/focus/recovery_wiring_test.dart`
- `test/features/planning/plan_preview_test.dart`
- `test/features/settings/app_lock/app_lock_unlock_test.dart`
- `test/features/settings/preferences_evidence_trigger_test.dart`
- `test/features/settings/relaxation_test.dart`
- `test/features/tasks/quick_add_test.dart`
- `test/features/tasks/task_preferred_window_page_test.dart`
- `test/features/tasks/task_tagging_test.dart`
- `test/scheduling/plan_differ_split_test.dart`
- `test/scheduling/preferred_time_window_test.dart`
- `test/scheduling/protected_time_expander_test.dart`
- `windows/runner/main.cpp`

合计 203 / 203

---

## 落库结果（2026-10-06 10:2x 补记）

实际落库形状与上面的提案有一处**重要不同**：

| 提交 | 内容 | 文件数 |
| --- | --- | --- |
| `d9d100b` | feat: 领域分类与最早开始约束、间周重复与学业日历、本地课表导入（含发布后 OCR 修复）= C1+C2+C3+C4 | 121 |
| `48ffce5` | fix(export): 导出改用 Windows 保存对话框 = C5 | 6 |
| `fe47afe` | feat(ui): 四档玻璃材质模式与外观设置 = C6 | 9 |
| `5ca5280` | style: dart format 重新排版通知与平台诊断相关文件 = C7 | 7 |
| （本提交） | chore: 集成改动与其余既有工作 = C8/E | 60 |

### 与提案的差异

1. **C7 实际是纯排版**：打开 diff 逐行核对后确认只有相邻字符串换行与一个缺失的末尾换行，
   没有任何语义改动，因此按 `style:` 提交，而不是伪装成「通知与平台诊断」功能提交。
2. **C8/E 必须先提交，否则仓库编译不过**——这是提案里判断错的地方。把 E 暂存掉之后在 HEAD 上跑
   `flutter analyze` 得到 **16 个 error**，因为 E 里包含前四笔提交的**集成尾巴**：
   - `lib/features/tasks/quick_add_form.dart` 调用已被 `d9d100b` 移除的 `TaskService.quickAdd`
     → 需要 E 里的删除与调用方更新；
   - `lib/platform/files/file_selector_adapter.dart` 未实现 `48ffce5` 新增的
     `ExportFilePort.chooseSaveLocation` / `writeFile`；
   - `lib/main.dart:84` 与 `test/app/planner_database_path_test.dart` 需要 E 提供的
     `fallbackDirectories` / `documentsDirectory` / `writableProbe` 参数；
   - 路由新增必填 `appearance` 后，E 里的 `focus_route_test.dart` 等调用点必须更新。

   因此本提案中「E = 归属不明的既有改动、可以不动」这个归类是**错的**：它至少有一大半是必需改动。
   结论修正为——**只有把 E 一并提交，HEAD 才等于已验证的 1.0.8 状态**。

3. **`windows/runner/main.cpp` 的行尾差异消失**：`git stash` 往返后 git 按转换规则重写了该文件，
   原先唯一的差异（CRLF/LF）被规范化。逐行比对与 HEAD 一致，**无内容丢失**。这也是待处理文件数
   从 61 变成 60 的唯一原因。

### 复核口径

「没有任何中间提交能独立编译」这一判断已被实测证实（HEAD 去掉 E 后 16 个 error）。落库后
HEAD 与工作区一致并已复验：`flutter test` 654/654、`flutter analyze` 无问题、
`dart format` 0 处改动。

