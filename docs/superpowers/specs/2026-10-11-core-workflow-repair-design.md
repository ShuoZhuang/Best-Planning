# Personal Planner 核心工作流修复设计

**状态：** 已确认需求的实施基准  
**日期：** 2026-10-11  
**适用基线：** `1.7.1+42`，提交 `e84a16f2`  
**目标发布批次：** `1.8.0`；内部任务不单独抬版本号

## 1. 目的

本设计一次解决下列用户可见问题，并锁定各模块之间的行为边界：

- 七日时间轴的卡片位置与文字时间不一致；
- 已关闭的通知仍重复出现；
- 托盘图标左键单击不能稳定打开主界面；
- 导入课程缺少集中管理和可靠的改写入口；
- “延后当前计划”只有分钟且经常因精确落点冲突而失败；
- 自动排程会制造无法利用的短空档，局部调整又改动过多；
- 固定日程仍让用户手输日期和时间；
- “保护时间”从新建入口跳到设置，不能新建一次性或自定义重复保护时段；
- 新建入口及侧栏归属不一致，任务页子路由被错误标成“今日”；
- 调整预览出现裸 UUID，失败原因只有笼统的“可用时间不足”。

这里的“不会出错”不是口头保证，而是：每条行为都有唯一语义、失败时不破坏现有计划、自动化测试可判定、Windows 实机验收可复现，任一门槛不通过就不得发布。

## 2. 已核实的现状与根因

`1.7.1` 已经完成周期目标按周均匀分配，以及普通计划预览的批量标题解析和结构化未安排原因。
本设计把它们列为回归门槛，不要求实现代理重写；新增工作只补延后路径、课程管理、保护时间和本次
实测缺陷。这样可以避免已经通过的能力被第二套接口替换。

### 2.1 时间轴重复做了时区转换

`lib/features/calendar/week_view/timeline_day_column.dart` 先把 UTC 转成本地分钟来计算位置，随后又把这个“本地分钟”包装成 `DateTime.utc` 并再次调用 `_local` 格式化。Asia/Shanghai 下会再偏移 8 小时。现有测试注入的是恒等转换，所以没有覆盖真实时区。

### 2.2 通知开关只保存偏好，没有立即对账

`PlanningRulesPage` 保存开关后没有调用 `NotificationService.syncNextSevenDays()`；已排进 Windows 的 `planner.*` 通知仍然存在。周期目标提醒组件已经有开关参数，但页面没有完整加载、保存和传入该值。系统还缺少总开关。

### 2.3 托盘没有显式处理左键抬起消息

`windows/runner/tray_icon.cpp` 当前处理 `WM_LBUTTONDBLCLK` 和 `NIN_SELECT`，但没有处理常见的 `WM_LBUTTONUP`。不同 Windows Shell 行为下，单击可能没有触发恢复窗口。

### 2.4 课程只有“从某一天改一次”的入口

导入课程已经保存为带 `logicalCourseId`、`importBatchId` 和重复规则的固定日程；日视图也能改某一次、此后或整个系列。但产品没有按学期列出的课程管理页，周视图卡片也没有直达管理动作。

### 2.5 “延后”把期望下界误建模为精确锁定点

今日页把分钟换成 `RequestedMove.atInstant`，排程输入再把该块以 `locked: true` 钉在精确目标时刻。目标点一旦被固定日程、保护时间或另一个锁定块占用，方案直接失败；它不会寻找目标之后最近的合法时段，也没有局部级联策略。一次失败还可能留下待处理内存意图。

### 2.6 评分模型不知道“无法利用的短空档”

候选评分包含截止风险、优先级、精力、期望时段、同任务连续性、类别切换、碎片和移动旧块等因素，但没有判断某个空档是否能容纳任何未完成任务。于是 20 多分钟的空白可能既不是用户设置的休息，也放不下任何任务。

### 2.7 固定日程编辑器仍依赖文本解析

`event_editor_form.dart` 和日视图单次改写对话框使用文本框输入日期、时间。项目已有 `plannerPickerBuilder`，任务编辑器也已有 `showDatePicker` / `showTimePicker` 路径，因此这里属于控件不一致，不是缺少基础能力。

### 2.8 “保护时间”被混同为全局规则

新建入口选择保护时间后直接进入 `/settings/rules`。设置页的午餐、晚餐、固定休息是长期默认规则，无法表达“某天 14:00–15:00 不安排”或“每周二自定义保护时间”。

### 2.9 侧栏只精确识别 `/tasks`

`_PlannerShell._selectedIndex` 只对 `/tasks` 返回任务索引；`/tasks/new`、`/tasks/new/task` 和周期目标子路由落入默认的“今日”。这就是创建不同事项时侧栏看起来归属不同的直接原因。

## 3. 全局不变量

下列规则优先于单页交互：

1. 数据库存 UTC；日期、星期和“延后 N 天”的日历语义使用事项自己的 IANA 时区。
2. 固定日程、保护时间、睡眠、真正锁定的计划块不可被自动移动或覆盖。
3. 任何调整先生成预览；未通过验证、用户取消或应用失败时，当前确认计划逐字不变。
4. 一次调整请求只能影响它绑定的一个 proposal，不能泄漏到下一次“生成计划”。
5. 自动修复优先少动：先减少被移动块数量，再减少总位移分钟，最后才比较软偏好。
6. 休息不是“浪费”。用户明确建立的保护时间、规则要求的间隔和睡眠都不计为坏空档。
7. 不向用户显示数据库 id、任务 UUID 或内部异常文本；所有错误必须带事项标题和可操作原因。
8. 旧数据原位兼容。迁移失败必须回滚事务，不能留下半迁移数据库。
9. 所有新入口支持键盘操作、清晰焦点、语义标签和 44×44 以上的点击区域。
10. 本批次由一个实现代理在一个工作树内串行完成。不得让多个代理同时编辑 `router.dart`、排程核心、数据库 schema 或组合根。

## 4. 时间轴行为

### 4.1 单一时间表示

时间轴布局边界统一为“本地日内分钟”：

```dart
typedef LocalMinute = int; // 0 <= value <= 1440
```

- UTC → 本地时区只在 `ScheduleViewSource` 或时间轴入口转换一次；
- 位置、卡片文字、悬浮提示和无障碍语义共用同一组 `startMinute/endMinute`；
- `_TimelineCard` 不得把分钟再包装成 UTC `DateTime`；
- 跨午夜事项在各本地日期切片后渲染，单列范围不得超过 0～1440；
- 夏令时地区的“本地日期”由 `TimeZoneDatabase` 决定，不能依赖主机 `DateTime.toLocal()`。

### 4.2 验收

- Asia/Shanghai 的 12:00–13:00 卡片位于 12 点且显示 `12:00–13:00`；
- Europe/Berlin 夏令时切换日的位置与文字一致；
- 跨午夜 23:30–00:30 分成两段，分别落在两天；
- 紧凑与时间轴两种视图显示同一时间。

## 5. 通知行为

### 5.1 偏好模型

`NotificationPreferences` 增加：

```dart
final bool enabled;              // 总开关，默认 true
final bool taskStartEnabled;
final bool calendarStartEnabled;
final bool deadlineEnabled;
final bool conflictEnabled;
final bool recurringGoalEnabled;
```

总开关关闭时，各分类值保留但不生效，方便再次开启后恢复原选择。

### 5.2 保存即生效

- 保存通知设置必须原子地完成“持久化偏好 → 重新对账”；
- 总开关关闭时，立即取消所有 id 前缀为 `planner.` 的待处理通知；
- 单类关闭时，立即取消该类已排通知，其他类别保留；
- 周期目标提醒与其他四类走同一保存、加载和取消链；
- 启动、唤醒、计划应用、任务状态变化和设置保存都调用同一个幂等 reconcile；
- 关闭通知后不得因下一次计划生成而重新排入。

### 5.3 失败反馈

若 Windows 通知接口返回失败，页面显示“设置已保存，但系统通知清理失败，可重试”，并提供“重新同步”按钮。不能静默显示成功。

## 6. 托盘行为

### 6.1 左键

左键单击托盘图标执行唯一动作：打开主界面。

- 同时接受 `WM_LBUTTONUP`、`NIN_SELECT` 和 `NIN_KEYSELECT`；
- 双击只会重复执行同一个幂等打开动作，不得第二次又隐藏窗口；
- 打开顺序为：若最小化则 `SW_RESTORE`，若隐藏则 `SW_SHOW`，最后请求前台和焦点；
- 窗口已显示时仍将其带到前台；
- 不创建第二个窗口实例；
- 右键仍只打开“打开主界面 / 退出”菜单；
- 锁屏门已启用时，打开的是锁屏界面，不绕过验证。

### 6.2 Windows 限制

`SetForegroundWindow` 可能受 Windows 前台进程规则限制。实现应先恢复并显示，再尝试 `SetForegroundWindow`，必要时调用 `FlashWindowEx` 提醒用户；不能因为抢焦点被拒绝就认为“打开失败”。

## 7. 新建入口与导航归属

### 7.1 信息架构

全局入口改为 `/new`，页面标题为“新建事项”，分成两组：

- 任务：普通任务、周期目标；
- 时间占用：固定日程、保护时间。

选择后进入所属模块：

- `/tasks/new/task`、`/tasks/recurring/new` 高亮“任务”；
- `/calendar/new`、`/calendar/protected/new` 高亮“日历”；
- `/new` 本身不高亮任何业务栏，或保留打开它之前的栏位；实现只能二选一，默认采用“不高亮”。

### 7.2 路由匹配

- `startsWith('/tasks')` → 任务；
- `startsWith('/calendar')` → 日历；
- `startsWith('/settings')` → 设置；
- `/new` → `null`；
- 返回按钮回到发起入口；直接深链进入时回到所属模块首页。

所有编辑器共用 `PlannerEditorScaffold` 的标题区、返回行为、底部保存栏、错误摘要和最大内容宽度。字段可以不同，骨架不能忽左忽右。

## 8. 固定日程日期与时间

### 8.1 控件

日期和时间字段改为只读、可点击字段：

- 日期调用 `showDatePicker(builder: plannerPickerBuilder)`；
- 时间调用 `showTimePicker(builder: plannerPickerBuilder)`；
- 允许键盘触发 Enter/Space；
- 字段文字按本地格式显示，不要求用户输入 `YYYY-MM-DD` 或 `HH:mm`；
- 日期、时间仍可复制，但不能直接输入非法文本。

### 8.2 联动

- 修改开始时间时，默认保持原时长并联动结束时间；
- 若用户已经手动改过结束时间，再改开始时间只在新结束不晚于开始时自动修正；
- 结束早于或等于开始时，明确询问“跨到次日”或要求重选，不做静默猜测；
- 重复日程的截止日期也用日期选择器；
- 日视图的“改这一次 / 此次及以后 / 整个系列”复用同一组件和校验。

## 9. 自定义保护时间

### 9.1 数据表示

复用固定日程及重复规则，不另建平行时间模型。`CalendarEvent` 增加：

```dart
enum CalendarEventKind { fixed, protected }
```

数据库 `calendar_events` 增加非空 `kind TEXT NOT NULL DEFAULT 'fixed'`。旧记录迁移后全部为 `fixed`。保护时间仍可一次性或按周重复，但：

- 不参与任务完成统计；
- 不作为“固定日程投入”统计；
- 在排程输入中映射为 protected window，而不是 fixed event；
- 在日历上使用“保护时间”统一配色；
- 不能标记完成。

### 9.2 编辑器

`/calendar/protected/new` 提供：标题、开始日期、开始时间、结束日期、结束时间、是否每周重复、星期、重复结束日期、备注。标题默认“保护时间”，用户可改。

设置页继续负责午餐、晚餐、固定休息等长期默认规则；它不再充当一次性保护时间编辑器。

### 9.3 删除与编辑

保护时间支持与固定日程相同的范围：仅本次、此次及以后、整个系列。删除或改写后触发重排原因记录和通知重新对账。

## 10. 课程管理

### 10.1 页面与入口

新增 `/calendar/courses`，入口放在日历页工具栏“管理课程”。按学期筛选，默认当前学期。每个逻辑课程聚合展示：课程名、星期与节次/时间、周次、单双周、地点、教师、领域、项目、启用状态、来源批次。

日历课程卡片的更多菜单包含“管理这门课”，按 `logicalCourseId` 打开对应详情。

### 10.2 操作语义

- 编辑单次：写例外，不改系列；
- 编辑此次及以后：截断旧规则并创建新系列；
- 编辑整个课程：修改该逻辑课程在当前学期内的全部系列片段；
- 暂停课程：从指定本地日期起停止生成，但保留历史；
- 删除：先预览受影响次数，再二次确认；默认删除整个逻辑课程在当前学期内的系列与例外；
- 撤销导入：仍按 import batch 执行，与删除单门课程分开；
- 修改课程时间、周次、地点或归属后必须重新检测冲突并预览。

### 10.3 读取端口

新增只读端口，不让页面直接查 Drift：

```dart
abstract interface class CourseSeriesRepository {
  Future<List<CourseSeriesSummary>> listCourses({String? termId});
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId);
}
```

写操作由 `CourseManagementService` 编排，底层复用日历系列改写和导入回滚事务。

## 11. 延后当前计划

### 11.1 对话框

对话框提供“分钟 / 小时 / 天”分段选择：

| 单位 | 快捷值 | 自定义约束 |
| --- | --- | --- |
| 分钟 | 5、10、15、30、45 | 1～1440，最终按 5 分钟粒度向上对齐并在确认前展示实际值 |
| 小时 | 1、2、3、6 | 1～72 的整数 |
| 天 | 1、2、3、7 | 1～365 的整数 |

确认区显示“原时间 → 最早目标时间”。文案必须说明：只调整当前计划块，不修改任务截止时间；若目标点被占用，会找其后的最近合法时段。

### 11.2 时间语义

- 分钟、小时：从原计划开始 UTC 加经过时长；
- 天：在事项时区中增加本地日历日并保留本地钟点，再转换为 UTC；不能简单加 24 小时；
- “延后”只允许正数；提前属于独立操作，不在本批次；
- 目标是 `notBeforeUtc` 下界，不是必须精确占用的点；
- 不得越过任务硬截止时间。若没有完整合法片段，返回结构化失败，不自动改截止时间。

### 11.3 请求模型

延后不再写入全局 `PendingMoveDrafts` 再等待下一次生成。使用 proposal 绑定的显式请求：

```dart
enum DeferUnit { minutes, hours, days }

final class DeferPlanBlockRequest {
  final String blockId;
  final int amount;
  final DeferUnit unit;
  final DateTime sourceStartUtc;
  final String timeZoneId;
}

Future<PlanProposal> createAdjustmentProposal(
  PlanAdjustmentRequest adjustment,
);
```

请求仅存在于这次调用和产生的 proposal 中。生成失败、取消预览、应用成功或应用失败后都不能影响下一次生成。

### 11.4 局部修复顺序

排程器按以下字典序选方案，前一项相同时才比较后一项：

1. 满足全部硬约束；
2. 被延后的目标块开始时间不早于 `notBeforeUtc`；
3. 移动的其他块数量最少；
4. 所有被移动块的总位移分钟最少；
5. 目标块距离 `notBeforeUtc` 最近；
6. 不制造无法利用的短空档；
7. 再比较截止风险、优先级、精力和期望时段。

先在当天做向后级联；当天放不下时才考虑后续日期。只有未锁定可移动块能被级联。固定日程、保护时间、睡眠、过去的块和锁定块保持原位。

### 11.5 失败原子性

若找不到合法方案：

- 不写数据库；
- 不改变确认计划；
- 不留下 pending move；
- 返回任务标题、请求目标和结构化原因；
- 给出可执行选项，例如“改为延后到明天”“调整截止时间”“取消”。

## 12. 短空档与排程质量

### 12.1 空档分类

相邻占用之间的间隔按本地时间分类：

- `intentionalBreak`：用户保护时间或规则要求的休息；
- `usableGap`：至少能放入一个当前未完成任务的合法最小片段；
- `orphanGap`：大于所需过渡休息，但小于所有可候选任务的最小片段；
- `freeTime`：没有任务需要填入，或用户日容量已达到上限。

只有 `orphanGap` 计入惩罚。系统不能为了“看起来紧凑”吞掉保护时间或排满所有自由时间。

### 12.2 评分

在 `CandidateScoreBreakdown` 增加可解释项：

```dart
ScoringFactor.orphanGapBefore
ScoringFactor.orphanGapAfter
ScoringFactor.adjustmentDisplacement
ScoringFactor.adjustmentMovedBlockCount
```

若一个 20 分钟空档放不下任何剩余任务，算法应优先把相邻可移动块靠拢，或把可拆任务片段合法地填入；若硬约束决定它必须存在，界面把它显示为“空闲 20 分钟”，而不是声称计划错误。

## 13. 预览与失败解释

`1.7.1` 基线已经实现 `TaskTitleLookup`、批量标题解析、`UnscheduledReason` 和
`UnscheduledReasonCode`。本批次不得另造第二套原因模型；这里要求的是把新增的延后/局部修复路径
接入现有能力，并防止任何备用预览路径退回裸 UUID。

### 13.1 不显示 UUID

预览层继续通过现有 `TaskTitleLookup.titlesFor()` 批量把 `taskId` 映射到标题；禁止逐项查询。
任何找不到标题的项使用现有占位文案，仍不得回退到 UUID。

### 13.2 结构化原因

排程引擎继续在拒绝候选时累计事实，不由 UI 猜测。现有原因包含最早开始、截止窗口、连续空档、
最小片段、每日上限、保护时间、固定日程、锁定块、休息间隔和总体容量。延后失败必须复用这些原因
及 `requiredMinutes`、`availableMinutes`、`constraintLabel` 证据；只有现有枚举确实无法表达新事实时，
才增加单一新枚举值并补齐所有翻译测试。

`UnscheduledTask` 继续包含 `taskId`、`shortageMinutes`、主原因和证据。新增要求是：延后失败也进入同一
标题解析和翻译链，显示“贫困生材料提交：目标之后最大连续空档只有 10 分钟”，不能退回
“可用时间不足”或内部 id。

## 14. 数据迁移与兼容

- schema 从当前 v8 升到 v9；唯一结构变化是 `calendar_events.kind`，默认 `fixed`；
- 迁移在单个事务内执行；升级前后的记录数、外键和时间字段必须校验；
- v8 备份可恢复到 v9，恢复后所有旧日程仍为固定日程；
- v9 备份不得声称能被旧版 1.7.1 读取；用户指南需说明前向兼容边界；
- 不改 MSIX identity，不改用户数据目录，不重命名已有 release 资产。

## 15. 发布与版本

当前 `1.7.1+42` 已正式发布。本批次包含课程管理、自定义保护时间和分单位延后等用户可见新功能，依据 `docs/release/version-policy.md` 必须抬 Minor，目标为 `1.8.0`，不能记成 `1.7.2`。

- 所有内部任务共用同一个 `1.8.0` 发布批次，不按任务抬版本；
- 开发期间不提前改 `pubspec.yaml`；发布候选冻结时分配下一个未使用的全局 build；
- 任一候选代码变化都分配新 build，不用 MSIX revision 伪装代码变化；
- 最终必须同时交付便携目录、ZIP、签名 MSIX、`.cer`、安装脚本、用户指南、Release Notes 和 SHA-256 清单；
- 只有 GitHub Release、tag、台账和最终资产一致时才算正式发布。

## 16. 不在本批次内

- 云同步、移动端、多人协作；
- 自动修改任务截止时间；
- “提前当前计划”；
- 用 AI 重新解释失败原因；
- 完全重写排程器或替换 Drift；
- 把所有空闲时间强行排满。

## 17. 最终验收矩阵

| 场景 | 必须结果 |
| --- | --- |
| 上海时区午餐 12:00–13:00 | 位置、文字、提示、语义均为 12:00–13:00 |
| 通知总开关关闭 | 已排 `planner.*` 全部取消，重启和重排后不恢复 |
| 托盘左键一次 | 隐藏/最小化窗口恢复并显示；不产生第二实例 |
| 课程有错误 | 可从管理课程找到并选择修改范围，保存前看到冲突预览 |
| 固定日程日期时间 | 全部通过选择器完成，无需输入格式字符串 |
| 新建保护时间 | 进入独立编辑器，保存后成为排程硬禁区 |
| 新建普通任务 | 侧栏高亮任务，不再高亮今日 |
| 延后 30 分钟且目标被占 | 在目标之后最近合法位置排入，并只最小改动后续块 |
| 延后 1 天遇 DST | 保持本地钟点，不以固定 24 小时计算 |
| 延后失败 | 原计划不变，显示标题和具体约束，不显示 UUID |
| 两任务间 20 分钟不可用空档 | 有更优合法解时消除；无解时明确显示为空闲而非偷偷占用 |
| 旧 v8 数据升级 | 所有旧日程仍可见，kind 均为 fixed，备份恢复通过 |

## 18. 日历、计划预览与排程完整性（2026-10-13 修复的最终接口与不变量）

本节记录实施计划
`docs/superpowers/plans/2026-10-13-calendar-preview-and-scheduling-integrity-repair.md`
落地之后的**最终接口与不变量**。凡与 §12、§13 的旧表述冲突之处，**以本节为准**。
验收证据见 `docs/testing/calendar-preview-scheduling-integrity-acceptance.md`。

### 18.1 排程：剩余量是候选生成的显式输入

```dart
List<SchedulingCandidate> generate(
  SchedulableTask task,
  List<AvailabilitySlot> slots, {
  required int remainingMinutes,   // 无默认值：漏改的调用点必须编译失败
});
```

不变量：

- `0 <= remainingMinutes <= task.requiredMinutes`，否则 `ArgumentError`；
- **连续任务**只有 `remainingMinutes == task.requiredMinutes` 时产出那一整块，放置成功即不再迭代；
- **可拆分任务**的时长上限用 `remainingMinutes`（**不再**读 `task.requiredMinutes`）；
- `remainingMinutes < minChunkMinutes` 时，唯一候选时长是
  `shortRemainderAllowance(remainingMinutes, granularity)`；结果为 0 时不生成候选；
- 引擎每成功放置一块就**以新的剩余量重新生成**候选，不存在"初始候选集代表全部后续轮次"；
- 每日上限（`maxMinutesPerLocalDay`）与每日可移动上限在放置阶段**都是硬约束**：
  第二遍只放宽"最终余量凑不出片段"这一条软性偏好，**不放宽每日配额**。

算法版本因此从 `15` 抬到 **`16`**（内部排程算法版本，不是软件版本号）。

### 18.2 最终校验按同任务整组块判定"唯一短尾"

```dart
enum ChunkSetViolation {
  none, nonPositiveDuration, offGranularity, aboveMaximum,
  belowMinimumBeforeTail, multipleShortTails, shortTailMismatch,
  totalExceedsRequired, continuousTaskSplit,
}
ChunkSetValidation validatePlannedChunkSet({
  required SchedulableTask task,
  required Iterable<PlannedBlock> blocks,
  required int granularityMinutes,
});
```

- `PlanValidator.validate()` 按 task id 分组调用它，集合合法性**只由它**决定；
- `isValidPlannedChunk()` 保留为**单候选的快速前置检查**（它只可能更宽，不可能更严）；
- 判定顺序：正时长／网格／不超过 max ⇒ 总量不超 required ⇒ 常规块 = `>= minChunkMinutes`
  ⇒ 短块最多一个 ⇒ `remaining = required − regularTotal`；`remaining >= minChunkMinutes`
  则是"过早用了短尾"（`belowMinimumBeforeTail`），否则短块必须**严格等于**
  `shortRemainderAllowance(remaining, granularity)`；
- **不足一个粒度的余数允许作为真实缺口保留**，不得伪造块。

### 18.3 最终诊断只看最终计划

```dart
TaskPlacementDiagnostics diagnoseTaskPlacement({
  required ScheduleProblem problem,
  required SchedulableTask task,
  required int remainingMinutes,
  required AvailabilityAnalysis availability,
  required List<PlannedBlock> finalBlocks,
  required TimeZoneDatabase zones,
});
```

- 调用时机固定在 `_improve()` → 稳定块最小化 → 最终排序**之后**；
- **不得读取**放置循环里累计的拒绝证据（跨轮次证据已整体删除）；
- 候选资格判定与引擎放置**共用**同一个纯 evaluator（`evaluateCandidateEligibility`），
  禁止第二套"看起来差不多"的约束；
- `hasEligibleCandidate == true && remainingMinutes > 0` ⇒ 主原因固定
  `unexplainedSchedulingFailure`，并生成 blocking conflict
  `ConflictCode.schedulingInvariantViolation`；`classifyProposal()` 必然是 `blocked`；
- `PlanApplicationService.apply()` 在 stale 检查之后、validator 之前先检查
  `proposal.conflicts`，非空立即返回 `invalid`——因此 `allowPartial` **也绕不过**；
- `excludedGaps` 按起点排序后合并相邻同 code 的区间，相同输入输出顺序稳定；
- 诊断数据随内存提案走（`ScheduleProposal.placementDiagnostics`），**不写日志与遥测**。

### 18.4 `UnscheduledReason` 的字段不再承担两种含义

```dart
UnscheduledReason({
  required UnscheduledReasonCode code,
  required int placementRemainingMinutes,   // == UnscheduledTask.shortageMinutes
  int? constraintRequiredMinutes,           // 某条约束要求的分钟，不是总缺口
  int? constraintAvailableMinutes,          // 同一约束口径下的可用分钟
  String? constraintLabel,
})
```

- UI **不得**计算 `constraintRequiredMinutes − constraintAvailableMinutes` 并称为"还缺"；
- "还缺多少"只在**标题**里显示 `UnscheduledTask.shortageMinutes`；
- 原因正文只描述约束（例如"最短片段要求 30 分钟，当前最长合法空档 20 分钟"）。

### 18.5 保护时间标签以类型传递，不解析 id

- `BusyInterval` 携带 `ProtectedTimeKind? protectedKind`；`ProtectedTimeExpander.expand()`
  写入 `rule.kind`，睡眠／固定日程／锁定块保持 `null`；
- 唯一文案函数 `protectedTimeKindLabel(ProtectedTimeKind)`
  在 `lib/design/protected_time_labels.dart`，文案为 **早餐／午餐／晚餐／固定休息**；
- 日历与预览都调用它，**不再**有 `intervalId.split(':')` 推断；
- `AnalyticsDao` 属于数据层，**不得**反向依赖 `lib/design/`：它继续把统计窗口投影为字符串，
  但默认规则与 JSON 规则两条路径都必须显式覆盖 `breakfast → 早餐`，由契约测试保证与界面一致；
- `ScheduleViewItem.isCompleted` **只表示任务完成**（`TaskStatus.completed`）：
  固定日程无论钟点是否已过都恒为 `false`。

### 18.6 日历刷新使用显式失效信号

```dart
enum ScheduleViewChangeKind { calendar, plan, task, planningRules, colors, workspace }

abstract interface class ScheduleViewInvalidation {
  Stream<int> get revisions;             // 单调递增；broadcast
  void notify(ScheduleViewChangeKind kind);
}
```

装配规则（唯一实例、app-scoped，由组合根创建与释放）：

| 写入点 | 发什么 | 时机 |
| --- | --- | --- |
| `CalendarService.onScheduleInputChanged` | `calendar` | 既有重排记录之后；记录抛错也发（数据已落库） |
| `PlanApplicationService` / `PlanUndoService.onPlanChanged` | `plan` | 既有提醒同步之后；同步失败也发（计划已提交） |
| `CourseManagementService.onCalendarChanged` | `calendar` | 仅 `saveCourse` / `deleteCourse`（绕过 CalendarService 的两条）；经 CalendarService 的路径**不得**重复发 |
| `SettingsService.onPlanningRulesChanged` | `planningRules` | 仅 `saveUserRules` / `saveDateOverride` 成功后 |
| `ScheduleColorService.onColorsChanged` | `colors` | 仅颜色写入成功后 |
| `WorkspaceService.onWorkspaceChanged` | `workspace` | 仅改变日历分类名称／颜色的 area 写入成功后 |
| 任务变化 | **不发 bus 信号** | 由 `TaskRepository.watchAllTasks()` 驱动 |

`RepositoryScheduleViewSource.watch()` 的契约：

1. 订阅后立即加载一次；
2. 监听 `tasks.watchAllTasks()` 与 `invalidation.revisions`；
3. 任一信号到达后重新执行**完整**的 `_load(startUtc, endUtc)`；
4. 同一时刻多个信号合并为**至多一次在途加载 ＋ 一次待处理加载**；
5. 用**单调 generation** 丢弃晚到的旧结果；旧结果不得覆盖新结果；
6. 最后一个监听者取消后释放内部订阅与 controller；
7. 加载失败通过 stream error 交给页面，**流不关闭**，下一次信号仍能恢复；
8. **不得**用定时轮询数据库实现。

失效信号只在事务／写入**成功后**发送；失败、取消与 stale 发零信号。

### 18.7 日视图操作区固定宽度且只显示可执行动作

每行固定为 `[占满剩余宽度的卡片] [48 px 操作槽]`：

- 所有行都有 48 px 槽，卡片右边界因此逐行对齐；
- 有至少一个动作时显示**单个** `more_vert`；没有动作时用**等宽空槽**，
  **不显示灰色按钮**（不可用的操作不渲染，而不是渲染成 `onPressed: null`）；
- 菜单只列可执行动作：编辑／调整所属领域／删除／去设置；
- 规则来源保护时间只有「去设置」；自定义保护时间「编辑／删除」；
  任务块不显示任何固定日程动作；
- 删除仍走二次确认；菜单关闭后焦点回到触发按钮；不以颜色区分危险。

### 18.8 预览的恢复路径与按钮层级

- `PreviewIssue` 携带 `taskId`、`excludedGaps`、`actions`；
  `buildPreviewIssues()` **只按 reason code** 映射恢复动作，不读任务属性猜原因；
- 动作映射：`deadlineWindowTooShort`／`continuousGapTooShort`／`minimumChunkTooLarge`
  ⇒ 编辑任务；`dailyLimitReached` ⇒ 调整规划规则 ＋ 编辑任务；`protectedTimeOccupied`
  ⇒ 管理保护时间 ＋ 编辑任务；`availableTimeNotReached` ⇒ 编辑任务；
  `insufficientCapacity` ⇒ 编辑任务 ＋ 调整规划规则；
  `unexplainedSchedulingFailure` ⇒ 重新生成；
- 存在 `excludedGaps` 时给可展开的「查看未使用空档」，每行写**本地**日期时间与排除原因，
  首屏最多 6 行、其余折叠为"另有 N 段"，数据本身不截断；
- 按钮层级固定为：

  | 状态 | 主操作 | 部分应用 |
  | --- | --- | --- |
  | 完整可行 | `FilledButton`「确认应用」 | 不显示 |
  | 可解释的真实缺口 | 每条问题卡显示恢复动作；底部**没有**全宽主按钮 | `OutlinedButton`「仍应用可安排部分」＋二次确认（逐条列出准确 shortage，并说明未安排部分仍留在待办中；取消零写入） |
  | 无法解释／结构错误 | `FilledButton`「重新生成计划」（**可点**） | 不显示 |
  | stale | `FilledButton`「重新生成计划」 | 不显示 |

- 「信任自动调整」**只在设置页**；预览页不再有该开关。开关的持久化与"完整提案自动应用"
  逻辑不变，且打开它**仍然不会**自动应用 warning／blocking 提案。

### 18.9 命名与范围

- 标题为「**近期日历**」，空状态为「当前范围暂无安排」，教程说明写"昨天及未来七天"；
- 列范围**仍是**"昨天 ＋ 今天起七天"共**八列**（`index -1..6` 与既有拖动 key 保持不变）；
  修正的是**命名**，不是删掉昨天那一列。

### 18.10 验收门禁（自动化）

| 门禁 | 命令 | 门槛 |
| --- | --- | --- |
| 格式 | `dart format --output=none --set-exit-if-changed lib test integration_test tool` | 零改动 |
| 静态分析 | `flutter analyze --no-pub` | 零问题 |
| 全量测试 | `flutter test --no-pub` | 零失败 |
| 跨视图一致性 | `flutter test integration_test/calendar_preview_consistency_test.dart -d windows` | 零失败 |
| 缩放／键盘／语义 | `test/app/accessibility_semantics_test.dart`、`test/features/calendar/*`、`test/features/planning/plan_preview_test.dart` | 零失败 |
| 人工 | `docs/testing/manual-windows-checklist.md` §J | 需 Windows 实机执行；未执行前不得记为通过 |


