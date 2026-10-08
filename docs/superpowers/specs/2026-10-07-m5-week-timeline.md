# M5 规格：真实时间比例的周日历

> 冻结路线图 §9 的边界。**必须复用**当前数据源、颜色与移动逻辑（§9「已有能力」）；
> **紧凑模式保留**，不得强迫用户接受时间轴密度；**不抬版本、不单独发布**（§3）；
> **不带入 M6 及以后**（§14）。

## 1. 用户结果（§9 原文）

七日历保留现有紧凑卡片模式，并增加按真实时间比例排列的"周时间轴"。用户能够看见
**空档、冲突、任务时长和全天节奏**；点击某一天或卡片能进入当天详情。

## 2. 现状（审计结论，2026-10-07）

`week_view_page.dart`（441 行）已经是**八列紧凑模式**（昨天 + 今天起七天）：
列头用「昨天／今天／明天／周X」、点击列头进日视图、卡片可长按拖动并询问是否锁定、
颜色来自统一目录。**没有任何时间轴**。

| §9 要求 | 现状 | 差距 |
| --- | --- | --- |
| 顶部「紧凑／时间轴」切换，**记住本机选择** | ❌ 无切换 | **缺失** |
| 时间轴默认显示**有安排的有效时间范围**，可滚动看全天 | ❌ | **缺失** |
| 卡片高度与**持续时间成比例**；短任务保持**最小可点击高度** | ❌ 固定高度 | **缺失** |
| **同时发生的项目并排显示**，不得互相覆盖到只剩一个可见 | ❌ | **缺失** |
| 点击日期头进当天；点击卡片进对应详情 | ✅ 列头已可点；卡片点击已有 | 无（需在时间轴里同样成立） |
| 长标题限行数，完整标题通过详情或 **Tooltip** | ⚠️ 紧凑卡片已有 ellipsis，需核实 Tooltip | 待补 |
| 颜色继续用统一目录 | ✅ `scheduleCategoryCardStyle` | 无（时间轴必须复用，不得另建） |
| **紧凑模式保留** | ✅ | 无（不得替换掉） |

## 3. 非目标

- 不改数据源（`schedule_view_source.dart` 不动）。
- 不改颜色目录与分类派生（复用 `schedule_category_card_style.dart`）。
- 不改拖动的语义与 `WeekMoveController`。
- 不做 M6 课表导入、M7 统计、M8 引导。
- 不改数据库结构、不改包身份、不改版本号。

## 4. 布局算法（**纯逻辑，单独文件以便穷举测试**）

时间轴要回答两个问题：**每一块画在哪、多高、多宽**。这三个都容易算错且难以靠肉眼看出来，
因此按 M1（`task_list_filter.dart`）与 M5 的一贯做法，**抽成不依赖 Flutter 的纯函数**：

`lib/features/calendar/week_view/timeline_layout.dart`

```dart
/// 一列（一天）的像素几何。
final class TimelineMetrics {
  const TimelineMetrics({
    required this.windowStartMinute,  // 可见范围内的起始「当天第几分钟」
    required this.windowEndMinute,
    required this.pixelsPerMinute,
    required this.minimumBlockHeight, // 极短任务的最小可点击高度
  });

  int get windowMinutes => windowEndMinute - windowStartMinute;
  double get contentHeight => windowMinutes * pixelsPerMinute;
  double topFor(int minute) => (minute - windowStartMinute) * pixelsPerMinute;
  double heightFor(int minutes) { ... } // 见 §4.2
}

final class TimelineBlock {
  const TimelineBlock({
    required this.itemId,
    required this.top,
    required this.height,
    required this.lane,
    required this.laneCount,
  });
  double get widthFraction => 1 / laneCount;
}

List<TimelineBlock> layoutTimelineDay({
  required List<ScheduleViewItem> items,
  required TimelineMetrics metrics,
  required int Function(ScheduleViewItem) startMinuteOf,
  required int Function(ScheduleViewItem) endMinuteOf,
});
```

### 4.1 可见时间范围（"有效时间范围"）

- 输入：当天所有条目（已按当天裁剪）；
- 输出：`(windowStartMinute, windowEndMinute)`，取**所有条目的最早开始 ~ 最晚结束**，
  再按 30 分钟向内取整、并**至少留 2 小时**；
- **全天无安排**时回落到 08:00–22:00（一个可用的默认视野，而不是 0 高度的空图）。

> "默认显示有效范围、允许滚动查看全天"= 初始滚动位置落在该范围，而整个 0:00–24:00 都可滚到。

### 4.2 高度（"与持续时间成比例"）

- `height = max(durationMinutes * pixelsPerMinute, minimumBlockHeight)`。
- **相同时长 ⇒ 相同高度**（纯函数保证）；**不同时长 ⇒ 有可观察的比例差异**
  （用 `pixelsPerMinute` 线性映射，不做任何压缩或封顶——除了最小高度那一档）。

### 4.3 并排（"同时发生的项目并排显示，不允许相互覆盖后只剩一个可见"）

这是本节唯一有真正算法难度的地方。**目标定成**：

> 时间上**重叠**的两块，在视觉上**绝不能重叠**；同一时刻可见的所有块**都能被看到**。

**做法（团／clique）**：

1. 把当天的条目按开始时间排序；
2. 求**极大团**：连续把"与当前团中任一块都重叠"的条目并入同一团；一旦某条与团中**所有**块都不重叠，
   就另起一团。团内的块**两两重叠**，因此团的大小就是"必须并排的最大数量"；
3. 团内按开始时间顺序分配 `lane = 0,1,2…`，`laneCount = 团的大小`；
4. 画的时候 `left = lane * width / laneCount`，`width = width / laneCount`。

**为什么不用"与已放下的块比较、找第一个空位"那种贪心**：它对**交叉区间**会出错。
例：A 09:00–11:00、B 09:30–10:00、C 10:30–11:30。
按开始时间贪心会把 A、B 放成两列，C 发现 lane 0 空闲（A 已结束？不，A 到 11:00）——
不同实现的答案不一致，且很容易出现"A 与 C 各占一半宽、却仍然左右重叠"的画面。
团的做法对这种情况给出**确定的**答案：`{A,B,C}` 是一团（A 与 C 重叠），三列各 1/3。

**每个团独立计算列数**，而不是全天统一列数：否则一个拥挤的上午会把整个下午也压成 1/3 宽。
（团内的块可能比团本身窄——这是并排布局的固有代价，比"互相盖住"要好。）

## 5. 视图切换与持久化（"记住本机选择"）

- 顶部加一组「紧凑／时间轴」切换（`SegmentedButton` 或两个 `ChoiceChip`）；
  **M2 的教训**：`SegmentedButton` 每个分段在语义树里会产生两个同名节点，因此
  **用 `ChoiceChip` + 独立 `Key`**，与任务页筛选栏同一做法。
- 选择持久在设置键 `calendar.weekViewMode.v1`，值取 `WeekViewMode` 的 `name`。
- **读失败一律回默认 `compact`**（与 `AnalyticsChartPreferenceService` 同一取舍：
  设置文件可能来自旧版本、被手改过或写坏，不该让日历打不开）。
- 新增 `lib/application/week_view_preference_service.dart`，形状照抄既有偏好服务。

## 6. 强制测试

| 要求 | 测试（`test/features/calendar/timeline_layout_test.dart`，纯逻辑） |
| --- | --- |
| 同样时长 ⇒ 同样高度 | 两条 60 分钟的块高度相等 |
| 不同时长 ⇒ 可观察比例 | 30 分钟的高度是 60 分钟的一半（未触及最小高度时） |
| 极短任务 | 5 分钟的块高度 == `minimumBlockHeight`，且**大于**按比例算出的值 |
| **交叉区间不重叠** | A 09–11、B 09:30–10、C 10:30–11:30 → 三块 `laneCount` 都是 3，`lane` 互不相同 |
| 完全同时 | 两块 09–10 → 两列各 1/2 |
| 相邻但不相交 | A 09–10、B 10–11 → **都占满整宽**（`laneCount == 1`），不得并排 |
| 嵌套 | A 09–12、B 10–11、C 10:30–11:30 → `{A,B,C}` 一团、三列（三者两两重叠） |
| 空列 | 无条目 → 空列表，且 `window` 回落到 08:00–22:00 |
| 跨午夜 | 一块 23:00–01:00 且已按当天裁剪 → 只画当天那一段，高度不超过窗口 |
| 全天无安排 | 见"空列" |

| 要求 | 测试（`test/features/calendar/week_view_test.dart`，Widget） |
| --- | --- |
| 切换存在且默认紧凑 | 默认渲染紧凑卡片；`week-view-timeline` 出现后渲染时间轴 |
| 记住选择 | 用 `MemorySettingsRepository` 预算一个 `timeline`，进页面即为时间轴；切换后写回设置 |
| 颜色复用统一目录 | 时间轴卡片颜色 == 同一事项在紧凑模式下的颜色 |
| 点击日期头进当天 | 时间轴的列头与紧凑模式同样可点，回调收到正确的那一天 |
| 点击卡片进详情 | 时间轴卡片可点，回调收到该条目 |
| 长标题限行 + Tooltip | 卡片标题 `maxLines` 受限，且 `Tooltip` 存在（完整标题可看） |
| **紧凑模式不回归** | 既有的紧凑模式用例全部保留并通过 |
| 150% 缩放可操作 | `textScaleFactor` 1.5 下时间轴仍渲染出卡片且可点 |

## 7. 退出条件（§9）

- [ ] 同样时长的事项显示同样高度，不同时长有可观察的比例差异。
- [ ] 跨天、午夜、重叠、极短任务和全天无安排**都有测试**。
- [ ] 七列视图在**最小支持窗口宽度和 150% 缩放**下仍可操作。
- [ ] 日期气泡、日期标题和卡片**均能进入正确日期或详情**。
- [ ] **紧凑模式行为不回归**。
- [ ] `analyze` 0 问题、`format` 0 改动、全量 `flutter test` 全绿、六条集成测试逐条通过。
- [ ] M5 章节写入 `docs/release/1.6.2-build37-user-guide.md`；更新路线图 §19。

## 8. 复现命令

```powershell
$env:TEMP = "G:\best-planing\.flutter-tmp"; $env:TMP = "G:\best-planing\.flutter-tmp"
Set-Location 'G:\best-planing\.worktrees\native-implementation'
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/features/calendar/
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' analyze --no-pub
& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test
```
