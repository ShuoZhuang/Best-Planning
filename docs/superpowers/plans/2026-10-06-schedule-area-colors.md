# 日程领域配色统一 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将今日、七日历和单日详情统一改为“领域颜色 + 保护时间颜色”，补齐无领域任务、无领域固定日程的独立颜色，并允许用户在领域设置中调整全部颜色。

**Architecture:** 新建独立的 `ScheduleColorService`，从 `WorkspaceRepository` 读取领域颜色、从 `SettingsRepository` 读取三个特殊分类颜色，并生成统一的颜色目录。`RepositoryScheduleViewSource` 在装配日程时一次性解析分类，将分类键、名称、颜色和排序写入 `ScheduleViewItem`；所有日程页面只消费这份展示数据，不再自行判断颜色。设置页面分别保存领域颜色和特殊分类颜色，旧数据通过稳定的默认色回退，不做破坏性迁移。

**Tech Stack:** Flutter/Dart, Drift-backed `SettingsRepository`/`WorkspaceRepository`, `flutter_test`

**Spec:** `docs/superpowers/specs/2026-10-06-schedule-area-colors-design.md`

## Global Constraints

- [ ] 领域颜色、特殊分类颜色均使用不透明 ARGB 值；透明或格式错误的数据必须回退到默认值。
- [ ] 同一条日程在今日、七日历和单日详情中必须使用同一个 `categoryKey`、`categoryLabel` 和颜色。
- [ ] 卡片只显示分类名称，例如“学业”“保护时间”“无领域任务”，不显示“领域 · 任务”等组合文案。
- [ ] 任务、固定日程、保护时间仍通过图标和辅助说明区分，不能只依赖颜色传达类型。
- [ ] 用户可以把两个分类设置为同一种颜色；图例按 `categoryKey` 去重，不能按颜色去重。
- [ ] 历史数据不批量改写。`areas.color == 0` 时按领域稳定排序选择默认色。
- [ ] 当前发布批次仍是 `1.4.0`。完成实际 Release 构建时将构建号从 `+19` 升到 `+20`；MSIX 继续使用 `1.4.0.0`。
- [ ] `1.4.0+20` 仍是开发构建。只有选定最终安装包、写入更新说明并登记为已发布后，才把 `1.4.0` 标记为正式发布。
- [ ] 当前环境禁止创建 Git 提交。每个任务以测试结果和变更清单作为检查点，不执行 `git add` 或 `git commit`。

## Review Focus

实施和审查时必须逐项验证以下五类输入：

1. 历史领域的 `color == 0`：使用稳定默认色，不写回数据库，也不要求迁移。
2. `schedule.colors.v1` 缺字段、字段类型错误或 JSON 损坏：每个字段独立回退，页面继续显示。
3. 日程引用已删除或不存在的领域：任务归入“无领域任务”，固定日程归入“无领域固定日程”。
4. 多个分类使用相同颜色，或自定义领域超过默认色板数量：允许重复，图例仍按分类键展示。
5. 跨午夜日程被今日视图裁剪：分类元数据不得丢失，分类时长只累计当天实际显示的分钟数。

---

## Task 1: 建立默认色板、特殊颜色模型和颜色服务

**Files:**

- Create: `lib/core/area_palette.dart`
- Create: `lib/domain/models/schedule_colors.dart`
- Create: `lib/application/schedule_color_service.dart`
- Create: `test/core/area_palette_test.dart`
- Create: `test/application/schedule_color_service_test.dart`

- [ ] **Step 1: 先写默认色板失败测试**

在 `area_palette_test.dart` 中覆盖：

- 色板至少包含八种不透明颜色；名称数量与颜色数量一致。
- 前五种用于默认领域，后三种分别用于保护时间、无领域任务、无领域固定日程，三者互不相同。
- `resolveAreaColorArgb(storedColor, sortOrder)` 优先返回已保存颜色。
- `storedColor == 0` 时按 `sortOrder % palette.length` 稳定回退，负排序回退到第一个颜色。

- [ ] **Step 2: 运行测试，确认因为实现不存在而失败**

Run: `flutter test test/core/area_palette_test.dart`

Expected: FAIL，提示 `area_palette.dart` 或目标 API 不存在。

- [ ] **Step 3: 实现默认色板**

在 `area_palette.dart` 中定义固定的低饱和色板和名称：

```dart
const areaPaletteArgb = <int>[
  0xff2f86ff,
  0xff53c7a5,
  0xfff2b35d,
  0xfff06f7a,
  0xffb391d3,
  0xff5ec8e5,
  0xff7f92b2,
  0xffa8b86f,
];
```

保留 `resolveAreaColorArgb` 和 `hasCustomAreaColor` 两个纯函数。色板顺序一旦发布就不能随意调整，否则历史 `color == 0` 的领域会变色。

- [ ] **Step 4: 先写特殊颜色解析失败测试**

在 `schedule_color_service_test.dart` 中使用 `MemorySettingsRepository` 和内存工作区仓库，覆盖：

- 没有设置时返回三个默认特殊颜色。
- 完整 JSON 能往返保存。
- JSON 损坏时全部回退。
- JSON 只缺一个字段，或只有一个字段类型错误时，仅该字段回退。
- 透明、负数和超出 32 位范围的值回退。
- 用户保存一个特殊颜色时，另外两个字段保持不变。
- 两个分类允许保存同样的颜色。
- `areas.color == 0` 进入目录时使用稳定默认色。

- [ ] **Step 5: 运行服务测试，确认失败**

Run: `flutter test test/application/schedule_color_service_test.dart`

Expected: FAIL，提示颜色模型或服务不存在。

- [ ] **Step 6: 实现颜色模型和服务**

`schedule_colors.dart` 至少提供：

```dart
enum ScheduleSpecialCategory {
  protectedTime,
  unassignedTask,
  unassignedFixed,
}

final class ScheduleSpecialColors {
  const ScheduleSpecialColors({
    required this.protectedTime,
    required this.unassignedTask,
    required this.unassignedFixed,
  });

  final int protectedTime;
  final int unassignedTask;
  final int unassignedFixed;
}

final class ScheduleCategoryPresentation {
  const ScheduleCategoryPresentation({
    required this.key,
    required this.label,
    required this.colorArgb,
    required this.sortOrder,
  });

  final String key;
  final String label;
  final int colorArgb;
  final int sortOrder;
}
```

`ScheduleColorCatalog` 保存按领域 ID 建立的分类表，并提供 `forAreaOrSpecial(areaId, fallback)`。特殊分类使用稳定键：

- `special:protected`
- `special:unassigned-task`
- `special:unassigned-fixed`

`ScheduleColorService` 使用设置键 `schedule.colors.v1`，负责加载、逐字段校验、保存特殊颜色以及从工作区领域生成目录。服务层不能依赖 Flutter 组件或具体页面。

- [ ] **Step 7: 运行两个测试文件**

Run: `flutter test test/core/area_palette_test.dart test/application/schedule_color_service_test.dart`

Expected: PASS。

---

## Task 2: 让领域拥有稳定默认色，并在领域设置中编辑全部颜色

**Files:**

- Modify: `lib/application/workspace_service.dart`
- Modify: `lib/features/workspace/workspace_management_page.dart`
- Create: `lib/features/workspace/schedule_color_picker_dialog.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/app/planner_app.dart`
- Modify: `test/application/workspace_service_test.dart`
- Modify: `test/features/workspace/workspace_management_page_test.dart`

- [ ] **Step 1: 先补工作区服务失败测试**

新增以下用例：

- 初始化“学业、科研、生活、竞赛、工作”时依次保存前五个默认领域颜色。
- 新建领域优先使用当前尚未占用的色板颜色；全部占用后按领域排序稳定循环。
- `setAreaColor(areaId, colorArgb)` 只修改目标领域颜色，保留名称、排序和生活标记。
- 非不透明 ARGB 拒绝保存，并返回可显示的错误。

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/application/workspace_service_test.dart`

Expected: FAIL，现有服务仍把新领域颜色写成 `0`，且没有颜色更新方法。

- [ ] **Step 3: 实现领域默认色和更新方法**

修改 `createArea`、`ensureDefaultAreas`，删除“领域颜色当前未使用”的旧假设。选择默认色时基于当前领域的已解析颜色集合，优先未使用色。实现 `setAreaColor`，在保存前校验 ARGB。

- [ ] **Step 4: 先补设置页面失败测试**

覆盖以下交互：

- 每个领域行显示当前颜色、名称以及“领域”的说明，项目仍显示在其所属领域下面。
- 点击领域色块打开颜色选择对话框。
- 对话框显示至少八个 44×44 的可点击色块，当前选中项有勾选图标和语义标签。
- 保存后仓库中的领域颜色更新，返回页面仍显示新颜色。
- 页面底部独立显示“保护时间”“无领域任务”“无领域固定日程”三个特殊分类颜色。
- 修改特殊颜色后写入 `schedule.colors.v1`。
- 保存失败时保留原颜色并显示明确错误，不关闭整个设置页面。

- [ ] **Step 5: 运行页面测试，确认失败**

Run: `flutter test test/features/workspace/workspace_management_page_test.dart`

Expected: FAIL，页面还没有颜色入口和特殊颜色区域。

- [ ] **Step 6: 实现颜色选择对话框**

`schedule_color_picker_dialog.dart` 只负责选择颜色：

- 标题明确显示正在编辑的分类名称。
- 色块使用真实颜色、选中勾和文本/语义名称共同表达，不能只靠颜色。
- 支持键盘焦点、Enter/Space 选择、Escape 取消。
- 点击色块后立即返回新值，由设置页保存并关闭对话框；按 Escape 或关闭对话框不改数据。
- 使用现有玻璃材质和间距变量，不引入页面专属渐变。

- [ ] **Step 7: 把颜色入口接入领域设置页**

向 `WorkspaceManagementPage` 注入 `ScheduleColorService`，显示领域颜色与三个特殊颜色。特殊颜色不伪装成领域，不提供项目功能。更新路由和 `PlannerApp` 的依赖装配。

- [ ] **Step 8: 运行服务与页面测试**

Run: `flutter test test/application/workspace_service_test.dart test/features/workspace/workspace_management_page_test.dart`

Expected: PASS。

---

## Task 3: 在日程数据源中统一解析分类

**Files:**

- Modify: `lib/features/calendar/schedule_view_source.dart`
- Create: `test/features/calendar/schedule_view_source_test.dart`
- Modify: `integration_test/first_plan_flow_test.dart`
- Modify: `lib/main.dart`

- [ ] **Step 1: 先写数据源分类失败测试**

建立最小内存仓库，覆盖：

- 有领域的可移动任务使用该领域的键、名称和颜色。
- 有领域的固定日程使用相同领域展示数据。
- 无领域任务使用“无领域任务”。
- 无领域固定日程使用“无领域固定日程”。
- 保护时间使用“保护时间”。
- 日程引用已删除领域时按日程类型回退，而不是保留失效领域名称。
- 两个领域即使颜色相同，也具有不同的 `categoryKey`。

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/features/calendar/schedule_view_source_test.dart`

Expected: FAIL，`ScheduleViewItem` 尚未包含统一分类字段。

- [ ] **Step 3: 扩展 `ScheduleViewItem`**

新增必填字段：

```dart
final String categoryKey;
final String categoryLabel;
final int categoryColorArgb;
final int categorySortOrder;
```

提供从 ARGB 生成 `Color` 的展示 getter。保留 `ScheduleItemKind`，它继续决定图标、交互和业务行为，不再决定卡片颜色。

- [ ] **Step 4: 在数据源中一次性完成分类**

向 `RepositoryScheduleViewSource` 注入 `ScheduleColorService`。每次加载范围时先读取一个 `ScheduleColorCatalog`，再用它装配全部结果：

- 任务和固定日程优先按 `areaId` 找领域。
- 找不到领域时按任务/固定日程分别回退。
- 保护时间无条件进入保护分类。
- 不在页面层重新查询领域或设置。

- [ ] **Step 5: 更新生产和集成测试装配**

在 `main.dart` 创建一个共享的 `ScheduleColorService`，同时交给数据源、应用路由和领域设置页。修改 `first_plan_flow_test.dart` 的测试依赖，避免生产与测试走两套分类逻辑。

- [ ] **Step 6: 运行数据源与首个计划流程测试**

Run: `flutter test test/features/calendar/schedule_view_source_test.dart integration_test/first_plan_flow_test.dart`

Expected: PASS。

---

## Task 4: 统一图例、分类汇总和今日页面

**Files:**

- Create: `lib/features/calendar/schedule_category_summary.dart`
- Create: `lib/features/calendar/schedule_category_legend.dart`
- Modify: `lib/features/today/today_page.dart`
- Create: `test/features/calendar/schedule_category_summary_test.dart`
- Modify: `test/features/today/today_page_test.dart`

- [ ] **Step 1: 先写分类汇总失败测试**

覆盖：

- 同一分类的多条日程合并分钟数。
- 不同分类即使颜色相同也不合并。
- 结果先按 `categorySortOrder`，再按名称稳定排序。
- 空日程返回空图例。
- 一条跨午夜日程裁剪到当天后，只累计裁剪后的分钟数。

- [ ] **Step 2: 运行测试，确认失败**

Run: `flutter test test/features/calendar/schedule_category_summary_test.dart`

Expected: FAIL，共享汇总不存在。

- [ ] **Step 3: 实现纯函数汇总与共享图例**

`schedule_category_summary.dart` 不依赖具体页面，按 `categoryKey` 聚合颜色、名称、排序和分钟数。`schedule_category_legend.dart` 接收汇总结果并显示动态图例；颜色点旁必须有分类名称和语义标签。

- [ ] **Step 4: 先补今日页面失败测试**

覆盖：

- 删除“固定、保护、可移动任务、生活”的静态图例。
- 当前日程出现哪些分类，图例就显示哪些分类。
- 卡片背景、左边条和图标强调色均来自 `categoryColorArgb`。
- 卡片只显示分类名称；类型仍能从图标和辅助语义识别。
- 容量卡按分类展示时长，并与当天可见片段相加。
- 裁剪跨午夜日程时，复制后的 `ScheduleViewItem` 保留全部分类元数据。

- [ ] **Step 5: 运行今日页面测试，确认失败**

Run: `flutter test test/features/today/today_page_test.dart`

Expected: FAIL，页面仍按 `ScheduleItemKind` 着色和汇总。

- [ ] **Step 6: 修改今日页面**

删除 `_toneFor(kind)` 和类型静态图例。统一使用 `item.categoryColorArgb`，容量区域使用共享汇总结果。检查所有 `ScheduleViewItem` 的裁剪、复制路径，逐字段保留分类数据。

- [ ] **Step 7: 运行共享汇总与今日页面测试**

Run: `flutter test test/features/calendar/schedule_category_summary_test.dart test/features/today/today_page_test.dart`

Expected: PASS。

---

## Task 5: 让七日历和单日详情消费同一分类数据

**Files:**

- Modify: `lib/features/calendar/week_view_page.dart`
- Modify: `lib/features/calendar/day_view_page.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`

- [ ] **Step 1: 先补七日历失败测试**

覆盖：

- 顶部显示当前七天实际出现分类的动态图例。
- 同一领域的任务和固定日程显示相同颜色与相同分类名称。
- 无领域任务与无领域固定日程颜色不同。
- 卡片只显示分类名称，仍保留任务/日历/盾牌图标。
- 图例按分类键去重，不按颜色去重。

- [ ] **Step 2: 先补单日详情失败测试**

覆盖：

- 从七日历点击某天进入详情后，日程颜色和分类名称不变。
- 卡片边线、强调色和分类文本均来自统一分类数据。
- 屏幕阅读器能读出“标题、时间、分类、日程类型”。
- 刷新数据后颜色更新，不需要重启应用。

- [ ] **Step 3: 运行页面测试，确认失败**

Run: `flutter test test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart`

Expected: FAIL，两个页面仍调用 `kind.color(...)`。

- [ ] **Step 4: 修改七日历**

删除类型颜色映射，卡片使用 `item.categoryColorArgb`。在标题区域加入共享动态分类图例；内容过多时允许横向滚动或换行，不能挤压七列日历。

- [ ] **Step 5: 修改单日详情**

使用相同分类颜色和名称。类型信息由现有图标和辅助说明保留，不再把“固定日程”当作颜色分类显示。

- [ ] **Step 6: 运行三个日程页面测试**

Run: `flutter test test/features/today/today_page_test.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart`

Expected: PASS，并且同一测试数据在三个页面得到同一颜色和分类名称。

---

## Task 6: 版本、文档、全量验证和 Windows 构建

**Files:**

- Modify: `pubspec.yaml`
- Modify: `lib/data/repositories/drift_backup_repository.dart`
- Modify: `docs/release/version-policy.md`
- Modify: `版本号规则.md` only if the short rule does not yet define “正式发布”
- Modify: existing version consistency tests if they enumerate expected build numbers
- Modify: release notes or release ledger used by this repository

- [ ] **Step 1: 先运行版本一致性测试并记录当前基线**

Run: `flutter test test/release/version_consistency_test.dart`

Expected: 当前 `1.4.0+19` 基线通过。若文件路径不同，先用 `rg --files test | rg version` 定位现有测试，不新建重复测试。

- [ ] **Step 2: 更新为本批次下一次实际构建号**

将唯一应用版本更新为 `1.4.0+20`，同步备份清单中的版本常量；MSIX 保持 `1.4.0.0`。不要把 `1.4.0` 标为已发布。

- [ ] **Step 3: 更新版本规则中的正式发布定义**

文档明确：普通代码提交和测试 EXE 不算正式发布。只有选定最终 Release 安装包、补齐更新说明和校验记录、把发布批次登记为“已发布”，才触发后续版本批次判断。修正 `version-policy.md` 中仍把托盘功能描述为“未提交”的过时状态。

- [ ] **Step 4: 运行格式化和静态检查**

Run: `dart format --output=none --set-exit-if-changed lib test integration_test`

Expected: PASS。若失败，先运行 `dart format` 修正，再重新执行检查命令。

Run: `flutter analyze`

Expected: PASS，无 warning 或 error。

- [ ] **Step 5: 运行本功能测试组**

Run:

```powershell
flutter test `
  test/core/area_palette_test.dart `
  test/application/schedule_color_service_test.dart `
  test/application/workspace_service_test.dart `
  test/features/workspace/workspace_management_page_test.dart `
  test/features/calendar/schedule_view_source_test.dart `
  test/features/calendar/schedule_category_summary_test.dart `
  test/features/today/today_page_test.dart `
  test/features/calendar/week_view_test.dart `
  test/features/calendar/day_view_test.dart `
  test/release/version_consistency_test.dart
```

Expected: PASS。

- [ ] **Step 6: 运行全部单元和组件测试**

Run: `flutter test`

Expected: PASS。不得用跳过测试、删除断言或放宽断言的方式通过。

- [ ] **Step 7: 构建 Windows Release**

Run: `flutter build windows --release`

Expected: PASS，生成的程序可从全新进程启动，今日、七日历、单日详情和领域设置均能打开。

- [ ] **Step 8: 执行人工冒烟检查**

至少检查：

1. 修改一个领域颜色，三个日程页面同步变化。
2. 修改三个特殊颜色，重新打开页面仍保留。
3. 同一颜色分配给两个领域，动态图例仍显示两个分类。
4. 删除一个被日程引用的领域，任务与固定日程分别进入正确的无领域分类。
5. 跨午夜日程的今日容量只计算当天片段。
6. 关闭并重新启动应用，颜色仍正确。

- [ ] **Step 9: 生成开发构建交付物并记录状态**

输出名称使用：

`PersonalPlanner-1.4.0-build20-windows-x64-20261006`

在发布记录中标记为“开发构建/待验收”，附测试和构建结果。只有用户后续明确选定最终安装包并确认发布，才能把 `1.4.0` 改为“已发布”。

---

## Completion Criteria

- [ ] 今日、七日历、单日详情不再按固定/可移动/生活类型分配颜色。
- [ ] 领域颜色、保护时间、无领域任务、无领域固定日程均可在领域设置中调整。
- [ ] 同一日程在三个页面的颜色和分类名称一致。
- [ ] 无领域任务与无领域固定日程使用不同的可配置颜色。
- [ ] 卡片只显示分类名称，类型由图标和辅助语义表达。
- [ ] 五类审查输入都有自动化测试。
- [ ] `flutter analyze`、功能测试组和 `flutter test` 全部通过。
- [ ] Windows Release 构建可以从全新进程启动。
- [ ] 构建版本是 `1.4.0+20`，发布状态仍为“开发构建/待验收”。
