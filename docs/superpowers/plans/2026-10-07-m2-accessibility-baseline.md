# M2 实施计划：可访问与可读基线

规格：`docs/superpowers/specs/2026-10-07-m2-accessibility-baseline.md`。路线图 §6、§14。

**执行顺序**：先写失败测试并看到与预期原因一致的失败 → 最小实现 → 局部验证 → 完整验证 →
人工走查（§5 两项）→ 登记里程碑。

---

## 步骤 1：语义测试与四个缺陷修复

**新文件** `test/app/accessibility_semantics_test.dart`

1. `A2-1 任务卡片的"查看详情"有可读名称` — 断言卡片上的详情入口在语义树里有非空 `label`。
   修法：给 `IconButton` 加 `Semantics(label: '查看<任务标题>详情')` 或改用带
   `semanticLabel` 的构型；`tooltip` **不**自动成为 `label`（这是实测结论）。
2. `A2-2 每个筛选项在语义树里只出现一次` — 断言四个筛选项各只有**一个**带该名称的语义节点。
   修法：把段内 `Text` 用 `ExcludeSemantics` 包起来，让名称只由 `ButtonSegment` 提供。
3. `A2-3 每个主导航项都有可激活角色与名称` — 断言六个导航项都有名称；选中项有选中态。
   修法：给 `NavigationRailDestination` 的 `label` 补语义（若 Flutter 未给未选中项 `isButton`
   角色，则在 destination 外显式包 `Semantics(button: true, ...)`）。
4. `A2-4 上述断言在修复前必须先红` — 本步骤的验收标准就是"先看到红"。

**涉及文件**：`lib/features/tasks/task_list_page.dart`、`lib/app/router.dart`

## 步骤 2：键盘与焦点测试

`test/app/accessibility_keyboard_test.dart`

1. Tab 顺序：主导航 → 顶栏动作 → 页面主要内容，断言焦点依次落在预期控件上（用
   `tester.sendKeyEvent(LogicalKeyboardKey.tab)` + `FocusManager.instance.primaryFocus`）。
2. `Enter` / `Space` 激活：焦点在筛选分段或按钮上时按键能触发（断言状态变化，而不是"没报错"）。
3. `Esc` 返回：在子页面按 `Esc` 回到上一级（复用既有 `shell-back-button` 的 `_parentLocation`）。
4. 焦点可见：断言 `Focus` 命中时确实有可见的焦点环（不靠颜色单独表达）。

**涉及文件**：`lib/app/router.dart`、`lib/design/planner_theme.dart`、`lib/features/tasks/task_list_page.dart`

## 步骤 3：对比度测量与令牌调整

`test/design/contrast_test.dart`

1. 四档材质（`off`／`restrained`／`aggressive`／`liquid`）× 关键页面跑 `textContrastGuideline`。
2. 关键页面：今日、任务、领域、日历、统计、设置（各取一条最小可渲染装配）。
3. **不达标的令牌按实测值调整**（预期候选：`textMuted` 用于 `bodySmall` 时偏暗）。
4. 非文本控件（边框、图标）单独测 ≥ 3:1。

**涉及文件**：`lib/design/planner_theme.dart`、`lib/design/planner_glass.dart`

## 步骤 4：表单错误播报

1. 新建任务页的错误文案用 `Semantics(liveRegion: true)` 播报。
2. 测试断言：提交非法表单后，错误节点被播报且文案本身可读（不只看红色）。

**涉及文件**：`lib/features/tasks/task_editor_page.dart`

## 步骤 5：减弱动画回归测试

1. `MediaQuery(disableAnimations: true)` 下断言 `app-pointer-highlight` 不再平滑拖尾
   （`planner_glass.dart` 已有该分支，此前无测试）。

**涉及文件**：`test/design/planner_glass_test.dart`（已有文件，追加用例）

## 步骤 6：完整验证

```powershell
flutter analyze --no-pub
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter test
flutter build windows --release --no-pub      # 内部验证构建，不抬版本
```

## 步骤 7：人工验证（**我做不了，必须由人执行**）

1. Accessibility Insights / Inspect 对着已安装的 `1.6.1.0` 看节点树，确认有独立控件节点；
   截图存档到 `release/`。
2. Narrator 走通"打开任务页 → 新建任务 → 保存 → 返回任务列表"，记录听到的内容。

结果写入 `docs/testing/m2-acceptance.md`；**未完成则 M2 不判定通过**。

## 步骤 8：登记

1. M2 章节写入 `docs/release/1.6.2-build37-user-guide.md`。
2. 更新路线图 §19 进度表（附测试输出与记录路径）。
3. **不抬版本、不单独打包、不建 GitHub Release**（§3、§14）。
