# M3 实施计划：新建任务与领域项目闭环

> 规格：`docs/superpowers/specs/2026-10-07-m3-task-editor-hierarchy.md`
> 路线图 §7。**不抬版本、不单独发布**；**不得带入 M4 及以后**（§14）。
> 方法：**先红后绿**，每个阶段先写失败测试。

## 阶段总览

| 阶段 | 内容 | 主要文件 |
| --- | --- | --- |
| P1 | 首屏七字段 + 「更多设置」收起分层 | `lib/features/tasks/task_editor_page.dart` |
| P2 | 固定底保存栏（缺失字段 + 约束摘要） | 同上 |
| P3 | 领域/项目规则核对与补强（切换清空说明、继承领域、一行说明+实例） | 同上、`lib/features/tasks/task_project_picker.dart` |
| P4 | 领域页：开关改名 + 颜色带标签按钮 | `lib/features/workspace/workspace_management_page.dart`、`schedule_color_picker_dialog.dart` |
| P5 | 缩放验证（100% / 150%）与完整验证 | 测试 |

---

## P1 首屏与「更多设置」分层

**先写的失败测试**（`test/features/tasks/task_editor_page_test.dart` 追加）：

1. 新建任务、未展开「更多设置」时，以下**七个**控件即可命中：
   `task-title`、`task-estimated-minutes`、`task-area`、`task-project`、
   `task-available-from`、`task-due-at`、`task-split-mode`。
2. 同一状态下，以下**不可见/不存在**：
   `task-editor-priority`、`task-energy-level`、`task-notes`、`task-preferred-window`、
   `task-min-chunk`、`task-max-chunk`。
3. 点开 `task-more-options`（新 key）后，上面那些**全部可见**。

**实现要点**：

- 把现有三节重排为：
  - `基本信息`：仅 `标题` + `预计时长`（**移出**优先级、精力、备注）。
  - `分类归属`：`领域` → `项目`（紧跟，保持既有过滤逻辑）→ 新建项目控件。
  - `时间与拆分`：`最早开始`、`截止`、`安排方式`。
  - `更多设置`（`ExpansionTile`，默认收起）：优先级、精力、片段长度、期望时段、备注、标签。
- `ExpansionTile` 的 key 用 `task-more-options`；内部控件沿用**既有 key**，避免大范围改测试。
- 收起时不能把内部控件留在树里（否则第 2 条测试会假绿）。
  `ExpansionTile` 默认不构建收起内容，符合要求；**不要**改用 `Visibility(maintainState: true)`。

**风险**：`_errors` 里的字段若被收进「更多设置」，保存失败时用户看不到错误。
→ 处理：P2 的底栏负责把 `_errors` 里**所有**缺失字段显示出来（不区分在不在展开区）。

## P2 固定底保存栏

**先写的失败测试**：

1. 保存按钮 `save-task` **不在**任何 `SingleChildScrollView` 的后代里
   （用 `find.ancestor` 断言）。
2. 底栏存在新 key `task-save-bar`。
3. 清空标题后，底栏出现「请填写任务标题」提示（key `task-missing-fields`）。
4. 底栏约束摘要（key `task-constraint-summary`）在选了领域/项目/时间后随之更新。

**实现要点**：

- 页面改为 `Scaffold`（若已在外层有 Scaffold，用 `Column` + 固定底栏即可；
  **先读现状决定**，不盲目套 Scaffold 以免嵌套出问题）。
- 底栏固定在滚动区**之外**，内容为：
  - 左：缺失字段（红，`Semantics(liveRegion: true)`，与 M2 的错误播报一致）；
  - 中：约束摘要（`领域 · 项目 · 最早开始 · 截止 · 拆分方式`）；
  - 右：`保存任务`、`取消`。
- 底栏高度在 150% 缩放下会变高，**不要写死高度**；用 `Padding` + `Wrap`。

## P3 领域与项目规则

**先写的失败测试**：

1. 选领域 A → 选其项目 A1 → 切到领域 B（A1 不属于 B）：
   断言项目被**清空**，且出现说明文字（key `task-project-cleared-notice`）。
2. 新建项目控件默认继承任务当前领域。
3. 编辑器内不出现「收集箱」字样（§3 全局约束）。

**实现要点**：

- 核对现有 `_selectArea` 是否已清空；**若已清空但无说明**，只补说明文字。
- 领域/项目各补**一行短说明 + 实例**，替换现有长句。

## P4 领域页

**先写的失败测试**（`test/features/workspace/workspace_management_page_test.dart`）：

1. 存在文案「计入个人生活时间」。
2. 存在带标签的「颜色」按钮（key `area-color-button`），可点开选色对话框。
3. **不再**存在无文字开关（断言旧的 `Switch` 相关 key 消失）。

**实现要点**：

- 只改**呈现层**；`WorkspaceService` 的字段与语义不动（§7 非目标）。
- 颜色按钮点开既有 `schedule_color_picker_dialog.dart`。

## P5 缩放与完整验证

1. **100% 缩放**：`tester.view.devicePixelRatio = 1.0`，窗口 1280×720，
   断言 `save-task` `findsOneWidget` 且 `tester.getRect` 落在视口内。
2. **150% 缩放**：`devicePixelRatio = 1.5`，同样断言。
   > 这两个断言就是 §7 第三条退出条件的自动化部分。**注意**：缩放不等于 DPI 感知，
   > 因此这一条是"自动化近似"，人工验收仍要在真实 150% 缩放下看一眼。
3. `flutter analyze --no-pub` 0 问题；`dart format` 0 改动；全量 `flutter test` 全绿。
4. Windows Release 构建成功（**内部验证构建，不发布**）。
5. M3 章节写入 `docs/release/1.6.2-build37-user-guide.md`；更新路线图 §19。

## 人工验收（我不代替）

§7 第一条要求"用默认值创建普通任务的人工计时小于 60 秒"。我会准备步骤与计时表，
**由人实际操作并记录秒数**。在此之前的自动化只能证明"字段不需要展开更多设置"，
**不能**证明"人能在 60 秒内做完"。

## 不做

- 不改领域模型、不改排程算法、不改数据库。
- 不新增周期任务开关。
- 不做 M4 的今日页动作、不做 M5 的周日历。
- 不抬版本、不单独打包、不建 Release。
