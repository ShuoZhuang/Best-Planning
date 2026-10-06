# Task Classification and Earliest-Start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let every task belong directly to a required area, optionally select a project from that area, and enforce an optional earliest-start time as a hard scheduling constraint while fixing the related dark-theme and settings spacing defects.

**Architecture:** Extend the existing Drift task row and `PlannerTask` domain object instead of introducing hidden projects. New and edited tasks are validated by `TaskService`; legacy rows may remain unclassified until edited. The scheduling model carries `availableFromUtc` to candidate generation, while analytics and life-time classification read the direct task area.

**Tech Stack:** Flutter 3/Dart 3, Drift/SQLite, Riverpod application assembly, GoRouter, Flutter widget/unit/integration tests.

**Spec:** `docs/superpowers/specs/2026-10-05-task-area-and-timetable-import-design.md`

> **执行状态（2026-10-05 复核）：本计划全部 7 个任务已完成，阶段验证通过（570 个单元/组件测试，静态分析无问题）。**
> 勾选口径：已完成的实现与验证步骤标为 `[x]`；每个任务末尾的 **Commit** 步骤保持 `[ ]`——工作树中当时已存在用户自己的未提交改动，按 `.superpowers/sdd/` 台账的裁定跳过逐任务提交，以免把无关改动一起提交。逐任务证据见 [progress.md](../../../.superpowers/sdd/2026-10-05-task-classification-and-start-constraint/progress.md)。

## Global Constraints

- Execute this plan before the recurrence and timetable-import plans.
- Keep existing user data; do not assign legacy projectless tasks to “学业”.
- New tasks require an area; a project remains optional and must belong to that area.
- Store instants as UTC microseconds; local conversion stays at the UI/application boundary.
- “最早开始时间” is a hard constraint; “期望时段” remains a soft preference.
- User-facing copy is “计入个人生活时间”; do not expose “生活标记” or `isLife` as UI terminology.
- Do not include unrelated dirty-worktree changes in task commits.

## Review Focus

- Legacy task with a project must inherit that project’s area during v4 migration; a legacy projectless task must remain unclassified.
- Changing an area must clear a project from the previous area before save, never retain an invalid pair.
- `availableFromUtc` inside a slot but off the five-minute grid must round upward, never schedule early.
- A direct-area task with no project must still count toward personal-life statistics and quota when its area is enabled.
- Narrow windows must stack form sections without overflow, and dark surfaces must not render black labels.

---

### Task 1: Add direct area and earliest-start data to tasks

**Files:**
- Modify: `lib/data/database/tables/planner_tables.dart`
- Modify: `lib/data/database/app_database.dart`
- Regenerate: `lib/data/database/app_database.g.dart`
- Regenerate: `lib/data/database/app_database.steps.dart`
- Create: `drift_schemas/app_database/schema_v4.json`
- Regenerate: `test/drift/app_database/generated/schema.dart`
- Create: `test/drift/app_database/generated/schema_v4.dart`
- Modify: `test/drift/app_database/schema_migration_test.dart`
- Modify: `lib/domain/models/task.dart`
- Modify: `lib/data/repositories/drift_task_repository.dart`
- Modify: `test/data/repository_round_trip_test.dart`

**Interfaces:**
- Produces: `PlannerTask.areaId: String?`
- Produces: `PlannerTask.availableFromUtc: DateTime?`
- Produces: Drift columns `tasks.areaId` and `tasks.availableFromUtc`
- Migration: database schema v3 → v4

- [x] **Step 1: Write failing migration and round-trip tests**

Add tests named `v3 task with project backfills direct area`, `v3 projectless task stays unclassified`, and `task area and earliest start round trip`. Assert the first row receives its project’s `area_id`, the second stays null, and an exact UTC instant survives repository save/load.

- [x] **Step 2: Run the focused tests and verify failure**

Run: `flutter test test/drift/app_database/schema_migration_test.dart test/data/repository_round_trip_test.dart`

Expected: FAIL because v4 columns and `PlannerTask` properties do not exist.

- [x] **Step 3: Implement schema v4 and domain mapping**

Add nullable `areaId` and `availableFromUtc` to `Tasks`; increase `schemaVersion` to 4. In `_upgradeToV4`, add both columns and execute an `UPDATE` joining `projects` to backfill only tasks with a non-null project. Add constructor/copy validation requiring UTC when `availableFromUtc != null`. Map both fields in `DriftTaskRepository`.

- [x] **Step 4: Regenerate Drift output and migration fixtures**

Run:

```powershell
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev make-migrations
dart run drift_dev schema generate drift_schemas/app_database/ test/drift/app_database/generated/ --data-classes --companions
```

Expected: schema v4 helpers are generated without conflicts.

- [x] **Step 5: Run the focused tests and verify pass**

Run: `flutter test test/drift/app_database/schema_migration_test.dart test/data/repository_round_trip_test.dart`

Expected: PASS, including every historical version → v4 combination.

- [ ] **Step 6: Commit**

```powershell
git add lib/data/database lib/domain/models/task.dart lib/data/repositories/drift_task_repository.dart drift_schemas/app_database test/drift/app_database test/data/repository_round_trip_test.dart
git commit -m "feat: add task area and earliest start data"
```

### Task 2: Seed five default areas and clarify personal-life semantics

**Files:**
- Modify: `lib/application/workspace_service.dart`
- Modify: `lib/features/workspace/workspace_management_page.dart`
- Modify: `test/application/workspace_service_test.dart`
- Modify: `test/features/workspace/workspace_management_page_test.dart`

**Interfaces:**
- Produces: `DefaultAreas.entries` in order 学业、科研、竞赛、工作、生活
- Produces: `WorkspaceService.ensureDefaultAreas() -> Future<int>` that adds only missing normalized names
- Produces: UI copy “计入个人生活时间”

- [x] **Step 1: Write failing service and widget tests**

Assert an empty repository receives five ordered defaults; a repository already containing `工作` only receives the other missing names; repeated calls add zero; only `生活` defaults to `isLife == true`. Assert the workspace page shows “计入个人生活时间” and no longer shows “标记为生活领域”.

- [x] **Step 2: Run the focused tests and verify failure**

Run: `flutter test test/application/workspace_service_test.dart test/features/workspace/workspace_management_page_test.dart`

Expected: FAIL because only three defaults exist and the old copy remains.

- [x] **Step 3: Implement idempotent default completion and copy change**

Normalize names with `trim().toLowerCase()` for comparison; preserve all existing rows and append only missing defaults after the current maximum `sortOrder`. Keep `isLife` as the storage property but label create/edit switches and help text “计入个人生活时间”.

- [x] **Step 4: Run focused tests and verify pass**

Run: `flutter test test/application/workspace_service_test.dart test/features/workspace/workspace_management_page_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/application/workspace_service.dart lib/features/workspace/workspace_management_page.dart test/application/workspace_service_test.dart test/features/workspace/workspace_management_page_test.dart
git commit -m "feat: complete default areas and clarify life time"
```

### Task 3: Validate area/project assignments in the task service

**Files:**
- Modify: `lib/application/task_service.dart`
- Modify: `lib/domain/repositories/workspace_repository.dart` only if an exact lookup helper is needed
- Modify: `lib/main.dart`
- Modify: `test/application/task_service_test.dart`
- Modify: `test/application/task_project_assignment_test.dart`

**Interfaces:**
- Changes: `TaskDraft` adds named parameters `required String areaId` and `DateTime? availableFromUtc`; its existing named parameters remain unchanged
- Changes: `TaskService` receives `WorkspaceRepository workspace`
- Produces field errors: `areaId`, `projectId`, `availableFromUtc`

- [x] **Step 1: Write failing validation tests**

Add assertions for: empty/nonexistent area rejected; project from another area rejected; no project accepted; `availableFromUtc` at or after `dueAtUtc` rejected; valid UTC classification saves both values; non-UTC instants are rejected.

- [x] **Step 2: Run tests and verify failure**

Run: `flutter test test/application/task_service_test.dart test/application/task_project_assignment_test.dart`

Expected: FAIL because `TaskDraft` has no direct area or earliest-start validation.

- [x] **Step 3: Implement service validation and assembly**

Require the area to exist before constructing `PlannerTask`. When `projectId != null`, load projects and require `project.areaId == draft.areaId`. Preserve a legacy null area only when loading an old task; any successful edit must supply an area. Validate UTC and the strict `availableFromUtc < dueAtUtc` relation. Inject the existing Drift workspace repository in `main.dart`.

- [x] **Step 4: Run tests and verify pass**

Run: `flutter test test/application/task_service_test.dart test/application/task_project_assignment_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/application/task_service.dart lib/domain/repositories/workspace_repository.dart lib/main.dart test/application/task_service_test.dart test/application/task_project_assignment_test.dart
git commit -m "feat: validate task area and project relationship"
```

### Task 4: Build the area-first detailed task editor

**Files:**
- Modify: `lib/features/tasks/task_editor_page.dart`
- Modify: `lib/features/tasks/task_detail_page.dart`
- Modify: `test/features/tasks/task_editor_page_test.dart`
- Modify: `test/features/tasks/task_project_picker_test.dart`

**Interfaces:**
- Consumes: `TaskDraft.areaId`, `TaskDraft.availableFromUtc`
- Consumes: `WorkspaceService.listAreas()`, `listProjects()`, `createProject(name:, areaId:)`
- Produces keys: `task-area`, `task-project`, `task-available-from`, `task-create-project`

- [x] **Step 1: Write failing widget tests**

Assert: new task defaults to 学业; area appears before project; project options are filtered by selected area; switching area clears an incompatible project; inline project creation receives the selected area and selects the result; earliest-start picker persists; earliest-start after deadline shows the service error next to that field; legacy unclassified edit requires an area.

- [x] **Step 2: Run tests and verify failure**

Run: `flutter test test/features/tasks/task_editor_page_test.dart test/features/tasks/task_project_picker_test.dart`

Expected: FAIL because the editor only exposes project and deadline.

- [x] **Step 3: Implement the approved three-section editor**

Load areas and projects together. For new tasks select the area named 学业, otherwise the first sorted area; for legacy edits keep null until the user chooses. Render 基本信息, 分类归属, 时间与拆分 as separated panels with 16–24px gaps. Filter projects by `_areaId`; place “新建该领域项目” beside the project field and create through `WorkspaceService`. Add a date/time picker and clear action for `_availableFromLocal`, converting through `TimeZoneDatabase` on save.

- [x] **Step 4: Run tests and verify pass**

Run: `flutter test test/features/tasks/task_editor_page_test.dart test/features/tasks/task_project_picker_test.dart`

Expected: PASS at both 1280px desktop width and a narrow 700px test surface without overflow.

- [ ] **Step 5: Commit**

```powershell
git add lib/features/tasks/task_editor_page.dart lib/features/tasks/task_detail_page.dart test/features/tasks/task_editor_page_test.dart test/features/tasks/task_project_picker_test.dart
git commit -m "feat: add area-first detailed task editor"
```

### Task 5: Enforce earliest start in scheduling

**Files:**
- Modify: `lib/scheduling/schedule_problem.dart`
- Modify: `lib/scheduling/candidate_generator.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/application/input_snapshot_builder.dart`
- Modify: `test/scheduling/candidate_generator_test.dart`
- Modify: `test/scheduling/schedule_engine_test.dart`
- Modify: `test/application/repository_schedule_problem_source_test.dart`
- Modify: `test/application/plan_generation_flow_test.dart`

**Interfaces:**
- Produces: `SchedulableTask.availableFromUtc: DateTime?`
- Candidate rule: start ≥ ceil-to-granularity(`availableFromUtc`)
- Snapshot rule: changing earliest start changes the input hash

- [x] **Step 1: Write failing scheduling tests**

Add tests for available-from at 10:03 producing the first candidate at 10:05; no candidate before the bound across multiple slots; continuous and split tasks obeying the same bound; an impossible deadline returning an unscheduled shortage; repository mapping and snapshot hash changes.

- [x] **Step 2: Run tests and verify failure**

Run: `flutter test test/scheduling/candidate_generator_test.dart test/scheduling/schedule_engine_test.dart test/application/repository_schedule_problem_source_test.dart test/application/plan_generation_flow_test.dart`

Expected: FAIL because `SchedulableTask` and candidate generation ignore earliest start.

- [x] **Step 3: Implement the scheduling lower bound**

Add `availableFromUtc` to `SchedulableTask`; require UTC when non-null. In `CandidateGenerator.generate`, start each slot at the later of the slot start and the bound rounded upward to `granularityMinutes`. Pass the task field from `RepositoryScheduleProblemSource`, and include it in `InputSnapshotBuilder` using ISO UTC text or microseconds consistently with other instants.

- [x] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS; generated blocks never begin early.

- [ ] **Step 5: Commit**

```powershell
git add lib/scheduling/schedule_problem.dart lib/scheduling/candidate_generator.dart lib/application/repository_schedule_problem_source.dart lib/application/input_snapshot_builder.dart test/scheduling/candidate_generator_test.dart test/scheduling/schedule_engine_test.dart test/application/repository_schedule_problem_source_test.dart test/application/plan_generation_flow_test.dart
git commit -m "feat: enforce task earliest start constraint"
```

### Task 6: Make direct-area classification drive analytics and personal-life quota

**Files:**
- Modify: `lib/data/repositories/drift_life_area_lookup.dart`
- Modify: `lib/data/database/daos/analytics_dao.dart`
- Regenerate: `lib/data/database/daos/analytics_dao.g.dart` if generated output changes
- Modify: `test/data/life_area_lookup_test.dart`
- Modify: `test/data/analytics_dao_test.dart`
- Modify: `test/application/analytics_service_test.dart`

**Interfaces:**
- Consumes: `tasks.areaId`
- Behavior: projectless direct-area tasks participate in area statistics and `lifeTaskIds()`

- [x] **Step 1: Write failing classification tests**

Seed a task with `area_id = area-life` and `project_id = null`; assert it appears in `lifeTaskIds()` and under the 生活 area in analytics. Seed an unclassified legacy task and assert it remains 未分类. Seed a mismatched corrupted project and assert the direct task area wins.

- [x] **Step 2: Run tests and verify failure**

Run: `flutter test test/data/life_area_lookup_test.dart test/data/analytics_dao_test.dart test/application/analytics_service_test.dart`

Expected: FAIL because current queries derive area exclusively through project.

- [x] **Step 3: Update queries to use the direct area**

Join `areas.id` to `tasks.areaId`. Keep project joins only for project names/filters. Do not infer life semantics from area names.

- [x] **Step 4: Regenerate DAO code if required and run tests**

Run: `dart run build_runner build --delete-conflicting-outputs`

Run: `flutter test test/data/life_area_lookup_test.dart test/data/analytics_dao_test.dart test/application/analytics_service_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/data/repositories/drift_life_area_lookup.dart lib/data/database/daos test/data/life_area_lookup_test.dart test/data/analytics_dao_test.dart test/application/analytics_service_test.dart
git commit -m "fix: classify tasks by direct area"
```

### Task 7: Fix dark-theme labels and settings spacing, then verify phase 1

**Files:**
- Modify: `lib/features/tasks/task_detail_page.dart`
- Modify: `lib/features/settings/settings_hub_page.dart`
- Modify: `test/features/tasks/task_detail_page_test.dart`
- Modify: `test/app/settings_hub_test.dart`
- Modify: `test/app/app_smoke_test.dart`

**Interfaces:**
- Uses theme text roles instead of `Colors.black*`
- Settings-entry vertical gap: 12 logical pixels; group lead-in remains 16/24px

- [x] **Step 1: Write failing regression tests**

Assert `_Fact` labels resolve to a theme-derived non-black color with sufficient contrast in dark mode. Assert the bounds of consecutive settings cards have a 12px vertical gap and each `ListTile` is at least 44px high.

- [x] **Step 2: Run tests and verify failure**

Run: `flutter test test/features/tasks/task_detail_page_test.dart test/app/settings_hub_test.dart test/app/app_smoke_test.dart`

Expected: FAIL on the hard-coded `Colors.black54` and zero card spacing.

- [x] **Step 3: Implement token-based text and explicit list spacing**

Use `Theme.of(context).textTheme.bodySmall`/`colorScheme.onSurfaceVariant` for facts. Wrap each settings card with explicit bottom padding or use a separated list; do not change global `CardTheme.margin`.

- [x] **Step 4: Run phase verification**

Run:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter test integration_test -d windows
```

Expected: formatting clean, analyzer reports no issues, all unit/widget tests pass, Windows integration flows pass.

- [ ] **Step 5: Commit**

```powershell
git add lib/features/tasks/task_detail_page.dart lib/features/settings/settings_hub_page.dart test/features/tasks/task_detail_page_test.dart test/app/settings_hub_test.dart test/app/app_smoke_test.dart
git commit -m "fix: improve dark form readability and settings spacing"
```
