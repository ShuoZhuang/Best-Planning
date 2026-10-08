# M3 验收记录：新建任务与领域项目闭环

规格：`docs/superpowers/specs/2026-10-07-m3-task-editor-hierarchy.md`
计划：`docs/superpowers/plans/2026-10-07-m3-task-editor-hierarchy.md`
路线图：§7（`docs/superpowers/plans/2026-10-07-product-experience-master-roadmap.md`）

## 1. 退出条件逐条对照

| # | 退出条件（§7） | 状态 | 证据 |
| --- | --- | --- | --- |
| 1 | 用默认值创建普通任务的人工计时 **< 60 秒**，实际操作时间记入验收记录 | **通过** | 用户实测 **40 秒**（2026-10-07）。见 §4.1 |
| 2 | 领域、项目、最早开始、截止时间、拆分方式无需展开「更多设置」 | **通过** | `task_editor_page_test.dart`「首屏七个字段无需展开即可见」 |
| 3 | 保存按钮在 100% 和 150% Windows 缩放下始终可见 | **通过** | 自动化（`devicePixelRatio` 1.0/1.5）＋用户 2026-10-07 在**真实 150% 缩放**下确认"看得到"。见 §4.2 |
| 4 | 任务计划块绝不早于最早开始时间 | 通过（既有，无回归） | `test/scheduling/` 既有用例；全量 898 通过 |
| 5 | 连续任务不会被拆分；可拆分任务遵守最短/最长片段 | 通过（既有，无回归） | 同上 |
| 6 | 领域切换不会保存无效项目关系 | **通过** | 切换领域后清空项目 + `task-project-cleared-notice`；既有「项目跟随领域过滤」用例 |
| 7 | 不出现"先进入收集箱再详细设置"的路径 | **通过** | `task_editor_route_test.dart` 断言页面无「收集箱」字样 |
| 8 | `flutter analyze` 0 问题、`dart format` 0 改动、全量 `flutter test` 全绿 | **通过** | analyze 0；format 351 文件 0 改动；**898 通过** |
| 9 | M3 章节写入用户指南草稿；更新路线图 §19 | **通过** | `docs/release/1.6.2-build37-user-guide.md` §3；路线图 §19 |

**结论：9 条全部通过**（其中第 1、3 条含用户人工验收）。

## 2. 本轮实际改了什么

### 2.1 信息层级（首屏 vs「更多设置」）

`lib/features/tasks/task_editor_page.dart` 从"一棵单列滚动树"改为：

```text
Column
├─ Expanded(SingleChildScrollView)
│   ├─ 基本信息：标题、预计时长
│   ├─ 分类归属：领域 → 项目 → 清空说明 → 新建项目
│   ├─ 时间与拆分：最早开始、截止、安排方式
│   └─ 更多设置（ExpansionTile，默认收起）
│        优先级、精力、最短/最长片段、期望时段、备注
└─ 固定底保存栏（不在滚动区内）
```

**为什么把领域/项目提到首屏**：§7 要求"项目分区必须在首屏可见"，而项目按领域过滤，
两者分屏会让人以为它们无关。

### 2.2 固定底保存栏

- 保存按钮移出滚动树（`find.ancestor(of: save, matching: Scrollable)` → `findsNothing`）；
- 底栏左上是**还缺什么**：既看 `_errors`（点过保存后的服务端错误），也看**当下就成立**的
  缺项（标题为空、预计时长非数字）——因为没点保存时 `_errors` 是空的，只依赖它会让用户
  在点之前得不到任何提示；
- 底栏左下是**关键约束摘要**：领域 / 项目 / 拆分方式 / 最早开始 / 截止；
- 缺失提示进 `liveRegion`，与 M2 的错误播报同一套做法。

**为什么要固定**：原本保存按钮是滚动树的最后一个 `Wrap`，滚到"期望时段"一带就看不见它，
150% 缩放下更容易发生——这正是 §7 第三条退出条件要挡的事。

### 2.3 领域切换不再静默清空

`_selectArea` 现在在清空前记下**被丢掉的项目名**，界面用
`task-project-cleared-notice` 说出「原项目「X」不属于当前领域，已清空」。
原来的行为是静默清空：用户选了项目、换个领域，项目就没了，且没有任何解释。

### 2.4 领域页的两个控件

`lib/features/workspace/workspace_management_page.dart`：

- 领域行原来的**无文字 `Switch`** → 旁边加上可见的「计入个人生活时间」，并用
  `Semantics(label: '<领域名>：计入个人生活时间')` 让屏幕阅读器一并念出是哪个领域；
- 颜色控件**本来就已经带标签**（`更换"<领域名>"领域颜色`，且色板对话框标题是
  `设置"学业"颜色`），本轮核对确认后**没有改动它**——只补了一条测试把它钉住，
  免得以后有人把它退回成一个无文字圆点。

## 3. 测试清单（新增 7 条）

| 文件 | 条数 | 钉住什么 |
| --- | --- | --- |
| `test/features/tasks/task_editor_page_test.dart` | +4 | 首屏七字段＋「更多设置」默认收起；固定底栏/缺失字段/live region/约束摘要；领域切换清空并说明；100% 与 150% 缩放下按钮在视口内 |
| `test/app/task_editor_route_test.dart` | +1（新文件） | 在**真实外壳** `_PlannerShell` 里挂载成功、底栏与七字段都在、无「收集箱」。挡的是"外壳改成无界高度 → `Column + Expanded` 直接炸"的回归 |
| `test/features/workspace/workspace_management_page_test.dart` | +2 | 每个领域的生活开关都带「计入个人生活时间」＋领域名；颜色控件都带「颜色」＋领域名 |

**改动了 1 条既有测试**（不是放宽，是跟随结构变化）：「新建显示个人默认值…」原本直接读
`task-min-chunk`/`task-max-chunk`/`task-preferred-window`，这些现在在「更多设置」里，
因此先展开再断言；另外原本用全页 `textContaining('2026-10-06 09:15')` 找最早开始时间，
现在底栏摘要也会写出同一个时间而命中两处，于是改为**限定在该字段内**查找。
后一处是"新功能让旧断言变宽"的典型——如果不收窄，这条断言以后会因为摘要文案变化而假绿。

## 4. 人工验收结果（2026-10-07 用户实机）

### 4.1 60 秒计时（§7 第一条）——**40 秒，通过**

用户实际操作：打开软件 →「任务」→「新建任务」→ 填标题 → 看默认时长 → 选领域 → 选项目
→ 直接点底栏「保存任务」，**未展开「更多设置」**，用时 **40 秒**（< 60 秒）。

这同时证明首屏分层有效：**不展开「更多设置」就能把任务建完**——七个首屏字段覆盖了
"用默认值创建普通任务"所需的全部信息。

### 4.2 真实 150% 缩放（§7 第三条）——**"看得到"，通过**

用户把 Windows 显示缩放设为 150% 后确认底栏的「保存任务」看得见。这一条自动化只能
用 `devicePixelRatio` 近似（**不等于**真实 DPI 感知），因此人工确认是必要的。

### 4.3 用户在验收时另外发现的一个真实缺陷（已修，见 §6）

## 5. 本记录明确不做的事
- 不改领域模型、不改排程算法、不改数据库（§7「已有能力」划界）。
- 不新增"周期任务"开关（§7 周期事项边界）。
- **不把标签输入搬进编辑器**：§7 的「更多设置」提到"标签与备注"，但本工程里标签入口在
  **任务详情页**（`TaskDetailPage(tags: ...)`，路由装配在 `router.dart` 的 `/tasks/:taskId`），
  编辑器从来就没有标签控件。把标签搬进来是一次**功能搬迁**，不是信息层级调整，
  因此本轮只收起了**备注**，并在规格里记下这一点。
- 不做 M4 的今日页动作、不做 M5 的周日历（§14）。
- 不抬版本、不单独打包、不建 Release。

## 6. 用户在验收时发现的日期选择器缺陷（**两次反馈；我第一次修错了方向，第二次才对**）

> 用户第 1 次反馈：**"为什么选择日期的时候今日的这个数字不见了"**（截图里 10 月 7 日那格只剩一个蓝圆）。
> 用户第 2 次反馈：**"你解决了个啥啊，而且我点击其他日期怎么还是选定在这里"**、
> **"7的颜色你也没有修好，图一不还是看不见，只有鼠标移过去看得见"**。

**两次反馈指向同一处代码里的两个错误，都是我写的；第一次我"修"的方向也是错的。**

### 6.1 我为什么会错两次：读错了源码

Flutter SDK 的 `packages/flutter/lib/src/material/` 下**有两份日期格实现**：

- `date_picker.dart` 里**还留着一份旧的 `_Day`**（约 2856–2985 行）；
- 而**真正被编译进这一版**的是 `calendar_date_picker.dart` 的 `_Day`（约 1185 行起）——
  `date_picker.dart` 只是 `import 'calendar_date_picker.dart'` 并使用 `CalendarDatePicker`。

我第一次读的是那段**旧实现**，据此写下"Flutter 先按 selected 解析 `dayForegroundColor`、
之后无条件用 `todayForegroundColor` 覆盖"，并照这个（错误的）模型改了主题。
真实实现的取色是**按 `isToday` 分流**的：

```dart
// calendar_date_picker.dart 的 _Day.build —— 这才是真正跑的那份
final dayForegroundColor = resolve(
  (theme) => widget.isToday ? theme?.todayForegroundColor : theme?.dayForegroundColor, states);
final dayBackgroundColor = resolve(
  (theme) => widget.isToday ? theme?.todayBackgroundColor : theme?.dayBackgroundColor, states);

final decoration = widget.isToday
    ? ShapeDecoration(color: dayBackgroundColor, shape: dayShape.copyWith(side: todayBorderSide))
    : ShapeDecoration(color: dayBackgroundColor, shape: dayShape);
```

**结论：改这一块之前必须先读 `calendar_date_picker.dart` 的 `_Day.build`，它是唯一的事实来源。**

### 6.2 我写错的两个属性，对应你看到的两个现象

| 我写错的属性 | 后果 | 你看到的现象 |
| --- | --- | --- |
| `todayBackgroundColor: transparent`。我还在注释里断言"那个圆由 `_HighlightPainter` 画、一覆盖就抹掉"——**这个断言是错的**，圆就是 `dayBackgroundColor` 本身 | **今天那格被抹掉了选中圆**。表头会跟着选中日期变，但 7 号不再显示圆，于是看起来像"选中卡在 7 号" | **"我点击其他日期怎么还是选定在这里"** |
| `todayForegroundColor: accent` | 今天被选中时数字是 accent 色，画在深色面板上几乎看不见；鼠标悬停那层 overlay 让它勉强可辨 | **"图一不还是看不见，只有鼠标移过去看得见"** |
| 顺带：`dayBackgroundColor` 写成 `WidgetStatePropertyAll(transparent)` | 选中**任何**日期都没有实心圆 | 与第一条叠加 |

### 6.3 修法

照抄 Flutter 自己的 M3 默认结构（`date_picker_theme.dart` 的默认实现），只把颜色换成调色板的值：

| 状态 | 前景 | 底色 |
| --- | --- | --- |
| 选中（今天与其它日期一致） | `textPrimary` | **`accent` 实心圆** |
| 未选中的今天 | `textPrimary` | 透明（只有 `accent` 描边） |
| 其它未选中 | `textPrimary` | 透明 |

对比度：`textPrimary`(#f4f7fb) 在 `accent`(#2a6cd2) 上 = **4.68:1**（WCAG AA ✓）。
修复前是 accent 字 + accent 圆 = **1.0:1**。

### 6.4 回归测试

`test/design/date_picker_selection_test.dart`（**5 条，新文件**）——
**直接断言"今天"那两个属性在 `selected` 状态下解析出什么**，因为那正是画到屏幕上的值：

1. 今天被选中时底色**不能全透明**（缺陷 1）；
2. 今天被选中时前景／底色对比度 **≥ 4.5:1**（缺陷 2）；
3. 未选中的今天**不画实心圆**（否则会和"已选中"混淆）；
4. 非今天的日期被选中时**同样有实心圆**（否则只有今天能看到选中态）；
5. 点 15 号后，选中语义标记**离开 7 号**、落到 15 号。

**为什么上一版测试没抓住这两个缺陷**（值得记下来）：上一版只断言"数字颜色不是 accent、
是 `textPrimary`"，**它对着旧代码也能通过**——旧代码里"今天"走的确实是 `todayForegroundColor`，
而那条测试只读了 `Text.style.color`，**完全没覆盖"那个圆会不会画出来"**。

### 6.5 为什么你看到的还是旧样子

**修复只存在于源码里，而你运行的是已安装的 MSIX**（`1.6.1.0`，构建于修复之前）。
按路线图 §3／§14，里程碑中间**不重新打包、不抬版本**，所以我没有去重装 MSIX。
带修复的便携版本放在 `G:\best-planing\release\M3-fix-portable-20261007\`，
双击其中的 `personal_planner.exe` 即可验证（`data\app.so` 已确认含本次改动）。

### 6.6 顺带更正我自己先前的一句话

我在 M2 讲过 accent `#2a6cd2` 上的浅色文字不达标（当时说白色是 3.27:1）。这次按 WCAG
相对亮度复算是 **5.03:1**（纯白）与 **4.68:1**（`textPrimary`），**两者都达标**。
M2 那次的口算有误，以本节的复算与测试为准。深色反而更低（`#142131` 只有 3.23:1），
所以这里取浅色而不是深色。
