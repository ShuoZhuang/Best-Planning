# Schedule Card Color Depth Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保留“领域 + 保护时间 + 无领域任务”的分类方式，修复今日、七日历和单日详情中卡片颜色发白、亮度过高、描边过亮的问题，恢复旧版深色、克制、有重量的视觉，同时产出可安装体验的 `1.4.2` 修复版。

**Architecture:** 新增一个纯函数式的共享视觉派生器，以现有分类色为输入，从 `PlannerPalette.surface` 和 `PlannerPalette.outline` 派生不透明的深色填充与低亮描边。今日、七日历、单日详情只消费该派生结果，不再各自叠加透明度。领域色仍负责小面积强调色、图标、时间轴圆点和图例；任务类型仍由图标及语义表达，不重新参与配色。

**Tech Stack:** Flutter/Dart、现有 `PlannerTheme`/`PlannerPalette`、Flutter widget tests、Windows runner、MSIX。

**Spec:** `docs/superpowers/specs/2026-10-06-schedule-area-colors-design.md`，以及 2026-10-06 用户确认的视觉纠偏：保留领域分类，卡片恢复旧版深色权重；今日、七日、单日详情颜色一致；卡片文字只显示领域标签。

## Global Constraints

- 执行根目录固定为 `G:\best-planing\.worktrees\native-implementation`，当前分支为 `feature/native-implementation`。本计划内所有相对路径和命令都从该目录运行，不要误改 `G:\best-planing` 主工作树中的同名文件。
- 不修改分类优先级：`保护时间 > 领域 > 无领域任务`。
- 不恢复“固定 / 保护 / 可移动 / 生活”按任务类型着色的旧逻辑。
- 不修改 `areaPaletteArgb` 的八个原始领域色，不改变用户已保存的领域颜色。
- 不调整全局背景、玻璃材质、鼠标高光或按钮主题；本次只修复日程卡片的填充、描边和强调色消费方式。
- 卡片表面不得再使用 `tone.withValues(alpha: 0.10)`、`tone.withValues(alpha: 0.18)` 或高亮 `alpha: 0.72` 描边。
- 今日、七日历、单日详情必须调用同一个共享函数，禁止三个页面维护不同的透明度或混色比例。
- 保留当前卡片标题、时间、领域标签、图标、点击、拖拽、焦点、语义标签和键盘行为。
- 当前工作树有用户已有的未提交改动。不得重置、覆盖或整理无关文件。当前工作区策略若不允许提交，不运行 `git commit`；每个任务只记录测试命令与 diff 检查点。若执行环境明确允许提交，可使用每个任务末尾给出的建议提交信息。
- 当前正式体验版本是 `1.4.1+21` / MSIX `1.4.1.0`。本修复是 Patch，目标版本固定为 `1.4.2+22` / MSIX `1.4.2.0`。用户验收前标记为候选构建，不宣称正式发布。
- Windows 构建继续使用现有应用标识、发布者、证书和升级链，确保可从 `1.4.1.0` 原位升级且保留本地数据。

## Fixed Visual Formula

新增以下不可变接口，三个页面只能通过它取得卡片颜色：

```dart
@immutable
final class ScheduleCategoryCardStyle {
  const ScheduleCategoryCardStyle({
    required this.accent,
    required this.fill,
    required this.border,
  });

  final Color accent;
  final Color fill;
  final Color border;
}

ScheduleCategoryCardStyle scheduleCategoryCardStyle(Color categoryColor)
```

实现公式固定为：

```dart
ScheduleCategoryCardStyle scheduleCategoryCardStyle(Color categoryColor) {
  return ScheduleCategoryCardStyle(
    accent: categoryColor,
    fill: Color.lerp(PlannerPalette.surface, categoryColor, 0.26)!,
    border: Color.lerp(PlannerPalette.outline, categoryColor, 0.32)!,
  );
}
```

以上 `fill` 和 `border` 必须是完全不透明色。以学业蓝 `#2F86FF` 为例，结果必须是：

- 强调色：`#2F86FF`
- 填充色：`#1B3B67`，接近旧版 `primaryContainer #163B67` 的视觉重量
- 描边色：`#2C5388`，不得使用 72% 的高亮原色描边

> **执行后的修订（2026-10-06，已落地）**：本计划原定填充比例 `0.26`。按它实施、构建并安装后，
> 用户看着实际界面反馈"仍然偏淡"——`0.26` 只解决了"不透明、不漂移"，对色板里较浅的颜色反而比
> 修复前更亮（无领域任务实测 `#213145` → `#303E52`）。经用户确认，填充比例改为 **`0.18`**，学业蓝
> 的填充因此是 `#193356`；描边比例不变（`0.32`，`#2C5388` 等描边值全部不变）。
> **下文表格里的 `0.26`、`#1B3B67`、`#244C4F`、`#4E473C`、`#4D3544`、`#3D3E5B`、`#274C60`、
> `#303E53`、`#3A4841` 均已作废**。现行公式、八色常量表与判定依据见
> `docs/superpowers/specs/2026-10-06-schedule-area-colors-design.md` §7 与
> `docs/release/build-ledger.md` 的 `1.4.2+23` 条目。计划正文保留原样，以便回溯"为什么是这一版"。

内置八色的预期结果和验收数据：

| 原始色 | 填充色 | 描边色 | 填充亮度上限 | 强调色/填充对比度下限 |
|---|---|---|---:|---:|
| `#2F86FF` | `#1B3B67` | `#2C5388` | `0.07` | `3.0` |
| `#53C7A5` | `#244C4F` | `#37686B` | `0.07` | `3.0` |
| `#F2B35D` | `#4E473C` | `#6A6154` | `0.07` | `3.0` |
| `#F06F7A` | `#4D3544` | `#694C5D` | `0.07` | `3.0` |
| `#B391D3` | `#3D3E5B` | `#56577A` | `0.07` | `3.0` |
| `#5EC8E5` | `#274C60` | `#3B6880` | `0.07` | `3.0` |
| `#7F92B2` | `#303E53` | `#45576F` | `0.07` | `3.0` |
| `#A8B86F` | `#3A4841` | `#52635A` | `0.07` | `3.0` |

`PlannerPalette.textPrimary` 对全部填充的对比度必须不低于 `4.5:1`；`PlannerPalette.textSecondary` 不低于 `3:1`。颜色不是唯一分类信号：领域文字、保护盾牌、任务/固定日程图标必须保留。

## Review Focus

- 八个领域色都要覆盖，重点检查最亮的琥珀和青色、最灰的蓝灰色，不能只测学业蓝。
- 同一领域下的固定日程和可移动任务必须同色，只允许图标不同；保护时间和无领域任务仍使用各自专用色。
- 四种材质模式（无玻璃、克制、激进、极致）下卡片 `fill`/`border` 的 ARGB 必须一致，玻璃背景不得再次把卡片冲淡。
- 今日、七日历、单日详情显示同一事项时，`accent`、`fill`、`border` 必须逐值相等。
- 检查长标题、拖拽、点击、hover/focus、屏幕阅读语义和现有本地数据，不得因视觉修复发生行为回归。

---

### Task 1: 新增共享卡片视觉派生器

**Files:**

- Create: `lib/features/calendar/schedule_category_card_style.dart`
- Create: `test/features/calendar/schedule_category_card_style_test.dart`
- Reference: `lib/core/area_palette.dart`
- Reference: `lib/design/planner_theme.dart`

**Interfaces:**

- `ScheduleCategoryCardStyle`
- `scheduleCategoryCardStyle(Color categoryColor)`

- [ ] **Step 1: 先写精确值失败测试**

  在新测试文件中导入尚不存在的共享接口，固定学业蓝的结果，禁止测试只复刻实现而不检查常量：

  ```dart
  test('derives the approved deep study card colors', () {
    const source = Color(0xff2f86ff);
    final style = scheduleCategoryCardStyle(source);

    expect(style.accent.toARGB32(), 0xff2f86ff);
    expect(style.fill.toARGB32(), 0xff1b3b67);
    expect(style.border.toARGB32(), 0xff2c5388);
  });
  ```

- [ ] **Step 2: 写八色不透明度、亮度和对比度测试**

  遍历 `areaPaletteArgb`，至少断言：

  ```dart
  expect(style.fill.toARGB32() >>> 24, 0xff);
  expect(style.border.toARGB32() >>> 24, 0xff);
  expect(style.fill.computeLuminance(), lessThanOrEqualTo(0.07));
  expect(contrastRatio(style.accent, style.fill), greaterThanOrEqualTo(3));
  expect(
    contrastRatio(PlannerPalette.textPrimary, style.fill),
    greaterThanOrEqualTo(4.5),
  );
  expect(
    contrastRatio(PlannerPalette.textSecondary, style.fill),
    greaterThanOrEqualTo(3),
  );
  ```

  在测试文件内写一个只用于断言的 WCAG 对比度函数：`(lighter + 0.05) / (darker + 0.05)`。

- [ ] **Step 3: 运行 RED 测试并确认失败原因正确**

  ```powershell
  flutter test --no-pub test/features/calendar/schedule_category_card_style_test.dart
  ```

  预期：因文件或接口尚不存在而失败。若因 Flutter 环境、缓存或权限失败，先修环境，不能把环境错误当成 RED。

- [ ] **Step 4: 实现最小共享派生器**

  在 `schedule_category_card_style.dart` 中使用 `@immutable`、`Color.lerp` 和上面的固定公式。不得加入按页面、任务类型或玻璃模式的分支。

- [ ] **Step 5: 运行 GREEN 测试**

  ```powershell
  dart format lib/features/calendar/schedule_category_card_style.dart test/features/calendar/schedule_category_card_style_test.dart
  flutter test --no-pub test/features/calendar/schedule_category_card_style_test.dart
  ```

  预期：全部通过。

- [ ] **Step 6: 检查本任务 diff**

  ```powershell
  git diff -- lib/features/calendar/schedule_category_card_style.dart test/features/calendar/schedule_category_card_style_test.dart
  ```

  仅在执行环境允许提交时使用建议提交信息：`fix: add shared deep schedule card colors`。

---

### Task 2: 七日历与单日详情改用共享深色样式

**Files:**

- Modify: `lib/features/calendar/week_view/week_view_page.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`
- Use: `lib/features/calendar/schedule_category_card_style.dart`

**Current Faults To Remove:**

- `week_view_page.dart` 中 `tone.withValues(alpha: 0.18)` 填充和 `tone.withValues(alpha: 0.72)` 描边。
- `day_view_page.dart` 中同样的 `0.18` 填充和 `0.72` 描边。

- [ ] **Step 1: 先把 widget 测试改成新契约**

  对学业、生活、保护时间、无领域任务各保留至少一个断言。页面测试通过查找对应 `Card`，读取：

  ```dart
  final card = tester.widget<Card>(cardFinder);
  final shape = card.shape! as RoundedRectangleBorder;
  final expected = scheduleCategoryCardStyle(categoryColor);

  expect(card.color, expected.fill);
  expect(shape.side.color, expected.border);
  ```

  同时断言卡片内的小图标或分类圆点使用 `expected.accent`。不要删除“卡片只显示领域标签”的现有断言。

- [ ] **Step 2: 运行 RED 测试**

  ```powershell
  flutter test --no-pub test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart
  ```

  预期：当前半透明填充或高亮描边与新期望不一致。

- [ ] **Step 3: 修改七日历卡片**

  在生成卡片的位置只计算一次：

  ```dart
  final visual = scheduleCategoryCardStyle(item.categoryColor);
  ```

  然后设置：

  ```dart
  color: visual.fill,
  surfaceTintColor: Colors.transparent,
  shape: RoundedRectangleBorder(
    borderRadius: existingRadius,
    side: BorderSide(color: visual.border),
  ),
  ```

  小图标、分类圆点或原有小面积强调元素改用 `visual.accent`。保留现有圆角、内边距、点击、拖拽和语义结构。

- [ ] **Step 4: 修改单日详情卡片**

  使用同一接口和同一字段映射。不得复制 `Color.lerp` 公式到页面文件。

- [ ] **Step 5: 运行 GREEN 测试并排查旧透明度残留**

  ```powershell
  dart format lib/features/calendar/week_view/week_view_page.dart lib/features/calendar/day_view/day_view_page.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart
  flutter test --no-pub test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart
  rg -n "withValues\(alpha: 0\.(10|18|72)\)" lib/features/calendar
  ```

  预期：两组测试通过；与日程卡片颜色有关的旧表达式不再出现。若同文件还有无关透明效果，逐项确认用途，不能机械删除。

- [ ] **Step 6: 检查本任务 diff**

  ```powershell
  git diff -- lib/features/calendar/week_view/week_view_page.dart lib/features/calendar/day_view/day_view_page.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart
  ```

  仅在允许提交时使用建议提交信息：`fix: deepen calendar schedule cards`。

---

### Task 3: 今日页面改用同一套颜色

**Files:**

- Modify: `lib/features/today/today_page.dart`
- Modify: `test/features/today/today_page_test.dart`
- Use: `lib/features/calendar/schedule_category_card_style.dart`

**Current Fault To Remove:**

- 今日卡片使用 `tone.withValues(alpha: 0.10)`，比七日历还浅；左侧强调条和图标却使用 100% 原色，造成“浅底 + 亮条”的割裂。

- [ ] **Step 1: 先更新今日页视觉断言**

  对现有 `Container`/`DecoratedBox` 读取 `BoxDecoration`：

  ```dart
  final decoration = container.decoration! as BoxDecoration;
  final border = decoration.border! as Border;
  final expected = scheduleCategoryCardStyle(categoryColor);

  expect(decoration.color, expected.fill);
  expect(border.top.color, expected.border);
  ```

  左侧强调条、时间轴圆点和分类图标继续断言为 `expected.accent`。至少覆盖领域任务、保护时间、无领域任务。

- [ ] **Step 2: 运行 RED 测试**

  ```powershell
  flutter test --no-pub test/features/today/today_page_test.dart
  ```

  预期：当前 `alpha: 0.10` 填充或旧描边与新期望不一致。

- [ ] **Step 3: 修改今日卡片实现**

  在单个事项构建方法中计算 `visual`，映射如下：

  - 卡片背景：`visual.fill`
  - 卡片完整边框：`visual.border`
  - 左侧强调条、时间轴圆点、分类图标：`visual.accent`
  - 主文字：保持 `PlannerPalette.textPrimary`
  - 次文字：保持 `PlannerPalette.textSecondary`

  不改当前安排侧栏、容量统计、图例的数据来源；它们仍使用分类原色作为小面积标识。

- [ ] **Step 4: 运行 GREEN 测试**

  ```powershell
  dart format lib/features/today/today_page.dart test/features/today/today_page_test.dart
  flutter test --no-pub test/features/today/today_page_test.dart
  ```

- [ ] **Step 5: 加入跨页面一致性回归断言**

  在三个现有页面测试中使用同一个已知分类色，分别读取实际卡片颜色，并断言都等于共享派生器结果。测试不需要跨页面同时 pump；每个页面各自验证同一组 ARGB 即可。

- [ ] **Step 6: 检查本任务 diff**

  ```powershell
  git diff -- lib/features/today/today_page.dart test/features/today/today_page_test.dart
  ```

  仅在允许提交时使用建议提交信息：`fix: align today cards with calendar colors`。

---

### Task 4: 四种材质模式、行为与文档验收

**Files:**

- Modify: `docs/superpowers/specs/2026-10-06-schedule-area-colors-design.md`
- Modify only if tests need shared fixtures: `test/helpers/*`
- Verify: all files modified in Tasks 1-3

- [ ] **Step 1: 给设计规格增加“深色卡片视觉纠偏”小节**

  写明三点：卡片表面使用不透明派生色；公式固定为 `surface→category 26%`、`outline→category 32%`；领域原色只用于小面积强调与图例。删除或改写任何暗示页面可自行选择透明度的描述。

- [ ] **Step 2: 验证四种材质模式不改变卡片 ARGB**

  复用现有主题构造方式，分别以无玻璃、克制、激进、极致模式 pump 页面。至少对一张学业卡和一张保护时间卡断言 `fill`、`border` 与共享派生器完全相等。若现有测试工具没有主题模式参数，新增最小 helper，不要改生产 API。

- [ ] **Step 3: 运行相关测试与静态检查**

  ```powershell
  flutter test --no-pub test/features/calendar/schedule_category_card_style_test.dart test/features/calendar/week_view_test.dart test/features/calendar/day_view_test.dart test/features/today/today_page_test.dart
  flutter analyze --no-pub
  dart format --output=none --set-exit-if-changed lib test integration_test
  ```

  预期：全部退出码为 0。若 `dart format --output=none` 报格式差异，先对本次修改文件执行 `dart format`，不能格式化无关用户文件。

- [ ] **Step 4: 运行全量测试**

  ```powershell
  flutter test --no-pub
  ```

  记录测试总数、耗时和退出码。

- [ ] **Step 5: 本机手动视觉检查**

  使用包含学业、生活、保护时间、无领域任务的数据，检查今日、七日历、单日详情：

  - 卡片明显比当前 `1.4.1` 候选截图更深，不再发灰发白。
  - 描边可辨认但不发光，主按钮仍是页面最醒目的元素。
  - 同领域固定日程与任务同色，只显示领域标签，类型由图标区分。
  - 保护时间和无领域任务颜色独立。
  - 四种玻璃模式切换时，背景可变化，卡片表面颜色不漂移。
  - 长课程名没有溢出，点击、拖拽、进入单日详情正常。

  保存至少五张验收截图：今日（无玻璃、极致）、七日历（无玻璃、极致）、单日详情（极致）。截图放入当前版本发布记录所使用的验收目录，不要提交用户真实隐私数据。

- [ ] **Step 6: 检查规格与实现一致**

  ```powershell
  rg -n "0\.26|0\.32|不透明|领域|保护时间|无领域" docs/superpowers/specs/2026-10-06-schedule-area-colors-design.md lib/features/calendar/schedule_category_card_style.dart
  git diff --check
  ```

  仅在允许提交时使用建议提交信息：`docs: specify deep category card treatment`。

---

### Task 5: 升级到 1.4.2 并产出可安装体验包

**Files:**

- Modify: `pubspec.yaml`
- Modify: the file that declares `appVersion` (locate with the command below and update that exact source file)
- Modify: the existing app-version test (locate with the command below)
- Modify: `docs/release/build-ledger.md`
- Verify: `版本号规则.md`
- Verify: `docs/release/version-policy.md`
- Verify: `docs/release/windows-release.md`

- [ ] **Step 1: 先核对版本规则和所有版本源**

  ```powershell
  Get-Content -Raw 版本号规则.md
  Get-Content -Raw docs/release/version-policy.md
  rg -n "1\.4\.1|1\.4\.1\.0|appVersion|msix_version|output_name" pubspec.yaml lib test docs
  ```

  确认本次仅为视觉缺陷修复，按 Patch 升级：应用 `1.4.2+22`，MSIX `1.4.2.0`。

- [ ] **Step 2: 先把版本测试改为 1.4.2 并运行 RED**

  更新现有版本测试的期望值后运行该测试。命令中的实际测试路径使用上一步 `rg` 找到的文件：

  ```powershell
  flutter test --no-pub <app-version-test-path>
  ```

  预期：生产代码仍报告 `1.4.1`，测试失败。

- [ ] **Step 3: 同步所有版本源并运行 GREEN**

  - `pubspec.yaml`：`version: 1.4.2+22`
  - MSIX：`msix_version: 1.4.2.0`
  - MSIX 输出名：沿用现有命名规则，把旧版本片段换为 `1.4.2-build22`
  - `appVersion`：`1.4.2`

  再运行版本测试和：

  ```powershell
  rg -n "1\.4\.1|1\.4\.1\.0" pubspec.yaml lib test
  ```

  预期：版本测试通过；生产版本文件不再残留 `1.4.1`。历史发布文档中的旧版本记录可以保留。

- [ ] **Step 4: 构建 Windows Release**

  按 `docs/release/windows-release.md` 设置项目既有的 Flutter、`PUB_CACHE`、`TEMP`、`TMP` 和 analytics suppression 环境，不要临时安装另一套 SDK。运行：

  ```powershell
  flutter build windows --release --no-pub
  ```

  预期：`build/windows/x64/runner/Release` 生成可运行程序。直接启动一次，确认今日和七日历能打开且颜色正确。

- [ ] **Step 5: 生成便携包和 ZIP**

  按现有发布目录约定复制完整 Release 目录，文件夹名固定为：

  ```text
  PersonalPlanner-1.4.2-build22-windows-x64-20261006
  ```

  生成同名 ZIP。必须包含 DLL、`data`、插件等完整运行依赖，不能只复制 EXE。

- [ ] **Step 6: 生成并签名 MSIX**

  ```powershell
  dart run msix:create --build-windows false
  ```

  若插件符号链接失效，只按 `windows-release.md` 的既有恢复步骤重建项目内的插件链接，再重新运行 `flutter build windows --release --no-pub` 和上面的 MSIX 命令；不得修改系统级 Flutter 安装。

  使用现有证书签名，验证：

  - 包清单版本是 `1.4.2.0`
  - 签名有效且时间戳状态符合既有发布规则
  - 包标识、发布者和安装路径没有改变

- [ ] **Step 7: 做原位升级和启动验证**

  在已安装 `1.4.1.0` 的机器上安装 `1.4.2.0`，不得先卸载旧版。验证：

  - Windows 将其识别为同一应用的升级
  - 应用可从开始菜单和安装目录启动
  - 原有任务、领域颜色、课表、设置仍在
  - 今日、七日历、单日详情使用新的深色卡片
  - 四种材质模式可切换且不会保存失败

- [ ] **Step 8: 更新构建台账**

  在 `docs/release/build-ledger.md` 新增 `1.4.2+22 / 1.4.2.0` 条目，写入：

  - commit/工作树状态与未提交说明
  - analyze、targeted tests、full tests 的命令和结果
  - EXE、便携文件夹、ZIP、MSIX、证书、安装指南的绝对路径
  - ZIP 和 MSIX 的 SHA-256
  - 签名验证、原位升级、启动、本地数据保留结果
  - 状态：`候选构建，等待用户体验确认`，不要写“正式发布”

- [ ] **Step 9: 最终完整性检查**

  ```powershell
  git diff --check
  git status --short
  ```

  对照本计划逐项勾选。任何测试失败、签名无效、MSIX 不能升级、数据丢失、页面颜色不一致，都不得声明完成。

  仅在执行环境明确允许提交且所有验收通过时使用建议提交信息：`fix: restore deep schedule card colors for 1.4.2`。

## Definition of Done

- 共享视觉派生器存在，三个页面没有各自的卡片透明度公式。
- 八个内置颜色的精确值、亮度、文本对比度、强调色对比度测试通过。
- 今日、七日历、单日详情的分类颜色逐值一致。
- 四种材质模式不会改变卡片 `fill`/`border`。
- 卡片只显示领域/保护时间/无领域任务分类标签，类型继续由图标表达。
- 全量 `flutter analyze`、格式检查、全量测试通过。
- Windows Release、完整便携文件夹、ZIP、已签名 MSIX、证书和安装说明齐全。
- `1.4.1.0 → 1.4.2.0` 原位升级成功，本地数据保留。
- 构建台账有路径、哈希、签名和验证证据；版本仍是候选构建，等待用户确认。
