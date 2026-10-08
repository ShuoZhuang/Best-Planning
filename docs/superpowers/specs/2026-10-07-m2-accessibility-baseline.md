# M2 规格：可访问与可读基线

> 本文件冻结路线图 §6（M2）的边界。路线图：`docs/superpowers/plans/2026-10-07-product-experience-master-roadmap.md`
> （sha256 `a1853a86…`）。**不得把 M3 及以后的内容顺手带入本里程碑**（§14）。
>
> 版本口径：M2 **不抬版本、不单独发布**；只产生内部验证构建（§3、§14、`version-policy.md` §4.0）。

## 1. 用户结果（路线图 §6 原文）

键盘用户能到达主要导航、按钮和表单；Narrator 与 UI Automation 能读出控件名称、角色、状态和
错误。四档玻璃模式下文字、边框、焦点和错误提示都能看清。

## 2. 非目标（明确不做）

- **不改排程算法**（路线图 §6 禁止范围）。
- **不重做页面布局**（同上）：只加语义、焦点与对比度，不动位置与结构。
- **不加新的主题档位**（同上）：仍然是"无／克制／激进／极致"四档。
- **不以关闭玻璃效果代替对比度修正**（同上）：四档都必须可用，不能靠"把材质关掉"过关。
- **不做 M3 的表单重构**：本里程碑只给现有字段补语义与焦点，不重排"首屏字段"。
- 不新增功能、不改数据模型、不改包身份。

## 3. 已确认的缺陷（本里程碑要修的）

以下都是**实跑语义树得到的**，不是推测。复现方式见 §6。

| # | 缺陷 | 影响 | 证据 |
| --- | --- | --- | --- |
| A2-1 | 任务卡片的"查看详情"图标按钮语义**标签为空**（`IconButton` 只有 `tooltip`，`SemanticsNode` 的 `label` 是空串） | 屏幕阅读器读到一个没有名字的按钮；键盘用户看到的是一个没有说明的图标 | 语义树：`[BUTTON, ENABLED, HAS_ENABLED] label="" value="" hint=""` |
| A2-2 | 任务页筛选栏的每个分段**各产生两个 button 节点**，且标签完全相同（父 `SegmentedButton` 段 + 子 `TextButton` 各自成节点） | Narrator 会把每个筛选项念两遍；自动化工具里同一控件出现两次 | 语义树：`[SELECTED,BUTTON,…] label="全部 2"` 下面还有一个 `[BUTTON,…] label="全部 2"` |
| A2-3 | ~~未选中的 `NavigationRailDestination` 没有可激活角色~~ **——这条是误判，已撤回** | 复核发现 Flutter 把它标成 **`role=tab`** 而不是 `button`，并且**每个导航项都带**"Tab 1 of 2"这样的组内位置，选中态也齐 | 语义树（`NavigationRail`）：`label=[今日⏎Tab 1 of 2] selected=true` 与 `label=[任务⏎Tab 2 of 2] selected=false`——**两项形状一致**，名称、组内位置、选中态都有 |
| A2-4 | 全库**没有任何无障碍测试**（`SemanticsTester` / 对比度 guideline 出现 0 次） | 上述缺陷能长期存在而无人发现；§6 的五条强制测试一条都没有 | 全量检索 `test/` 命中 0 |

### A2-3 的更正记录（为什么撤回）

第一版规格把"未选中项没有 `isButton`"当成缺陷。复核 Flutter 源码与实测语义树之后撤回：

- `NavigationRailDestination` 的语义角色是 **`tab`**（`SemanticsFlag.isSelected` +
  组内位置文本），这是**正确的控件角色**——导航栏本来就是一组互斥的标签页，
  不是一组按钮；
- 关键证据是**两项形状一致**：选中项与未选中项的名称、`Tab n of m`、`selected` 一应俱全，
  差别只有 `selected` 本身，那正是应有的差别。

**教训（写下来免得下次再犯）**：`isButton == false` **不等于**"没有角色"。判定角色缺失前，
必须先把完整标志集合与角色的来源读出来，否则会去"修"一个本来就对的东西——而修法（自己套
`Semantics(button: true)`）恰好会**把正确的 `tab` 角色改错**。本里程碑因此**不改导航栏**。

**尚未确认、不能声称已修**的两项（需要真实环境，见 §5）：

- **UI Automation 只暴露 `FLUTTERVIEW`**（路线图 §1.3 第 9 条）：需要 Accessibility Insights
  或 Inspect 对着**已安装的包**看，我无法凭空验证，因此只准备步骤并要求人工执行。
- **对比度**：需要先测出实际比值才能判断哪几处不达标（`textMuted` 与 `textSecondary` 在
  合成背景上的表现必须实测，不能靠肉眼估）。

## 4. 实施范围（对应路线图 §6「实施范围」六条）

| 路线图要求 | 本里程碑的落地做法 |
| --- | --- |
| 为侧边导航、顶栏动作、任务卡片、日历卡片、筛选、对话框、设置入口和表单字段补齐语义 | 逐个补 `Semantics` 标签/角色；**先写语义测试**（§6），修到测试绿 |
| 定义稳定的 Tab 顺序；焦点可见，Enter/Space 激活，Esc 关闭/返回 | 用 `FocusTraversalGroup` 固化顺序；测试断言 Tab 顺序与 `Focus` 可见；Esc 已有 `shell-back-button`，补测试 |
| 表单错误既显示文字，也进入语义播报；不能只靠红色表达 | 错误文案用 `Semantics(liveRegion: true)` 播报；测试断言错误节点被播报且文案可读 |
| 正文与背景对比度 ≥ 4.5:1，大号文字与非文本控件 ≥ 3:1 | 用 `textContrastGuideline` 在**四档材质**下测关键页面；不达标的令牌按实测值调整 |
| `prefers-reduced-motion` 生效时关闭跟随指针高光的平滑拖尾与非必要过渡 | 已有 `MediaQuery.disableAnimations` 分支（`planner_glass.dart`），**补测试钉住**它 |
| 对已存在的 `Semantics` 先验证安装包实际节点 | §5 的人工步骤，不因源码里有组件就认定合格 |

## 5. 必须由人执行的两项（我做不了，不代替）

1. **Accessibility Insights / Inspect 看已安装的 `1.6.1.0`**：确认节点树里有独立控件（而不是
   只有一个 `FLUTTERVIEW`），并截图存档。
2. **Narrator 走通**：打开任务页 → 新建任务 → 保存 → 返回任务列表，记录听到的每一句。

这两项**没做就不勾选**，并按 `docs/testing/m1-acceptance.md` 的口径写"未完成"。

## 6. 强制测试（路线图 §6 五条 → 可执行形式）

| 路线图条目 | 落地测试 |
| --- | --- |
| Widget 测试检查主导航、筛选、卡片和表单的语义标签与选中状态 | `test/app/accessibility_semantics_test.dart`：断言**筛选分段恰好一个**可聚焦节点且带选中态、**任务卡片的操作按钮有非空且带任务名的名称**；主导航按 A2-3 的更正结论断言"**每个导航项都有名称与组内位置、选中项带选中态**"，而**不**断言角色是 button（Flutter 用的是正确的 `tab`） |
| Widget 测试验证 Tab 顺序、Enter/Space 激活、Esc 返回 | 同文件：断言关键页面的 Tab 顺序确定、`Enter`/`Space` 能激活按钮、`Esc` 返回上一级 |
| 四档材质分别完成关键页面截图对比和对比度测量 | 新建 `test/design/contrast_test.dart`：四档材质 × 关键页面跑 `textContrastGuideline`；不达标的令牌按实测调整 |
| Accessibility Insights 或 Inspect 看到独立控件节点 | **人工**（§5），记录进验收记录 |
| Narrator 人工走通 | **人工**（§5） |

另加一条**回归**测试：`MediaQuery(disableAnimations: true)` 下指针高光不再平滑拖尾
（`planner_glass.dart` 已有该分支，此前无测试）。

## 7. 退出条件（路线图 §6 强制测试 + §14 完整验证）

- [x] §3 A2-1、A2-2、A2-4 三个缺陷修掉并有测试钉住；**A2-3 已撤回**（误判，导航栏不动）。
- [x] §6 的四份自动化测试全绿（另加 Esc 2 条、减弱动画 2 条，共 21 条）。
- [x] 四档材质的对比度实测达标（正文 ≥ 4.5:1，大号文字/非文本控件 ≥ 3:1）；不达标的令牌已按
      实测值调整（**没有关掉玻璃材质**）。
- [x] 键盘走查：Tab 顺序确定、焦点可见、Enter/Space 激活、**Esc 返回上一级（本轮新加）**。
- [x] `flutter analyze` 0 问题、`dart format` 0 改动、全量 `flutter test` **891 通过**。
- [x] Windows Release 构建通过（作为内部验证构建）。
- [x] **§15 的五条 Windows 集成测试逐条跑通**（其中 `first_plan_flow_test.dart` 此前一直失败，
      本轮补齐教程闸门后通过）。
- [ ] §5 两项人工验证完成并记录；**未完成则整个 M2 不判定通过**。
      → 已先做一轮 MSAA 取证（见 `docs/testing/m2-acceptance.md` §4.0）：对照 Notepad 7 个子节点，
      本应用只有 1（`FLUTTERVIEW`），**启动 Narrator 前后都是 1**。**官方工具复核与 Narrator 走查仍未做。**
- [x] M2 章节写入 `docs/release/1.6.2-build37-user-guide.md`。
- [x] 更新路线图 §19 进度表（附测试输出与记录路径，不只改文字）。

## 8. 复现命令

```powershell
# 先按 README.md 设好 TEMP 与 PATH
$env:TEMP = "G:\best-planing\.flutter-tmp"; $env:TMP = "G:\best-planing\.flutter-tmp"
Set-Location 'G:\best-planing\.worktrees\native-implementation'

& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/app/accessibility_semantics_test.dart
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/design/contrast_test.dart
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' analyze --no-pub
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test
```

**语义树的临时复现方式**（本规格 §3 的证据就是这么得到的）：用
`tester.ensureSemantics()` 取 `pipelineOwner.semanticsOwner.rootSemanticsNode`，
递归打印每个节点的 `flags` 与 `label`。该探针是**临时**的，不入库。
