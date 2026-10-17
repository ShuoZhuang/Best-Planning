# 跨日分配器 ↔ 排程引擎：接口契约（Task 6 前置）

> 状态：**分配器已就绪并通过验证；引擎接线仍未提交**（第 21、24 轮各试一次，均回退）。
> 第 24 轮的接线**解决了三件事**（见 §8），只剩两个具体问题未解。
>
> 相关记录：`docs/testing/capacity-aware-scheduler-acceptance.md` §6。

---

## 1. 为什么需要这份文档

六轮失败有一个共同形状：每次针对一个症状改动分配器，改动的目标达成了，但相邻的
另一处随即失效。根本原因是**两侧对同一份数据的解释从未被写下来**：

- 分配器把 `DateTime(y, m, d)` 当作"某一天的名字"；
- 引擎用 `TimeZoneDatabase.toLocal(instantUtc, zoneId)` 把瞬间映射成本地日；
- 而容量、截止、最早开始分别以"本地日""UTC 时刻"两种形式在两边流动。

一旦两侧对"一天从哪一刻开始"的答案不同，跨日预算就会与日内放置错位，
而错位的表现是**分钟数静默丢失**（实测 120 → 90），不是异常。

---

## 2. 三条已实测的事实（不是推测）

### 2.1 分配器当前把日键当"UTC 日"，与引擎的本地日不同源

`lib/scheduling/day_allocation.dart` 用 `_localDayEnd(date) => DateTime(y, m, d + 1)`
并把结果与 `dueAtUtc`（真实 UTC 时刻）比较。`Asia/Shanghai` 下本地零点 = 前一天
16:00Z，两者相差 8 小时。

**实测**：`planningWindow` 取 UTC、`dueAtUtc = start + 2d` 的任务，
本应 6 个可用日，`_rankEligibleDates` 只收到 3 个。

> 注：把该比较改成 `DateTime.utc(y, m, d).add(24h)`（真正的 UTC 日终点）后，
> 分配器的 23 条用例中仍有 5 条失败（见 §5），说明这**不是唯一**的错位点。
> 因此该改动**未提交**。

### 2.2 分配器与引擎对"这次要排多少"必须同源

分配器内部按 `task.requiredMinutes − 已排分钟` 推剩余量，而引擎的目标是
`_targetFor(problem, task)`（含截止压力、均匀推进量与 `_ensurePlaceable` 的最小可排量）。

**实测**：`requiredMinutes: 150` 但已排 210 分钟的任务，分配器算出
`remaining = 150 − 210 = 0`，**一分钟都不分配**；引擎侧则期望继续按目标投放。

### 2.3 预算的单位必须是"这一天能承接的量"

**实测**：分配器给出 `{10-05: 60, 10-06: 30, 10-07: 30}`（合计 120），
引擎接进去只排出 **90** 分钟。

原因：预算被切成了"目标 ÷ 片段数"的等分碎片，而引擎的放置循环在
"这一天的预算用完"时就换天，无法把余量补到任何一天上。

**结论**：预算必须是**引擎能消费的单位**——一天的完整可承接量，而不是目标的等分。

---

## 3. 契约（提案）

### 3.1 日键

```text
DayKey := DateTime(y, m, d)        // 不带时区，表示"本地自然日"这一个名字
```

- **日键是全序的**：比较日键的先后即比较日期的先后，与任何时区无关。
- 日键**不是瞬间**。任何需要与 UTC 时刻比较的地方，都必须改用该日
  **账本携带的 UTC 边界**（见 §5.3 的契约修订）。
- 分配器与引擎**共用账本的边界**，不得各写一份换算式。

> ⚠️ 本节已被 **§5.3 取代**。本轮探针证明：任何"在分配器内部猜日键与 UTC 关系"
> 的写法都是错的（本地零点、UTC 零点、次日零点各错一处）。保留在此是为了记录
> 走过的弯路。

### 3.2 任务目标

```text
DayAllocationInput.targetMinutesByTask[taskId] : int
```

- 语义：**引擎本次希望为该任务安排的分钟数**（即 `_targetFor` 的结果）。
- 分配器**不得**自行用 `task.requiredMinutes` 推导此值。
- 分配器返回 `remaining` 时，扣减必须与此值同源，**不得二次扣减**
  （见 §2.2 的 150/210 实例）。

### 3.3 每日预算

```text
TaskDayBudget.minutesByLocalDate[dayKey] : int
```

- 语义：**引擎该日最多可为该任务新增的分钟数**。是一个**上限**，不是"必须正好用掉"。
- **可选性**：键不在表中 ⇒ 该日不可用（0 分钟）。
- **单位约束**：每个值必须是**粒度整数倍**（`granularityMinutes`），
  否则引擎排不出恰好那么多，余量会变成缺口。
- **完整性约束**：同一天所有任务的预算之和**不得超过**该日账本的 `remainingMinutes`。
  由分配器在分配时扣减账本保证。
- **落地约束**：预算应当**集中在排名靠前的日期并填满**，而不是等分到 K 天。
  等分会让引擎无法消费（见 §2.3）。

### 3.4 分配顺序（值对象，不改契约）

`compareTasksForAllocation` 已实现"受限优先 → 截止 → 压力 → 优先级 → ID"，
本契约不改变它，只要求它**在扣除预算之前**给出稳定全序。

---

## 4. 验收判据（实施 Task 6 时必须同时满足）

1. `near` 探针：`requiredMinutes: 120`、`minChunk 30`、`maxChunk 60`、
   `dueAtUtc = start + 2d`、`planningWindow` 为 UTC ⇒ **`scheduledMinutes == 120`**
   （当前实测 90）。
2. 分配器 23 条用例全绿（当前全绿，任何改动不得破坏）。
3. Task 1 的 5 条红灯转为绿灯，且**不新增**任何红灯。
4. 全量 `flutter test` 的失败集合**恰好等于**改动前的失败集合。

---

## 5. 根因：日键缺少"本地 → UTC 边界"这一项输入（本轮已实测定位）

改 `_eligibleDates` 的截止边界为 `DateTime.utc(y, m, d) + 24h` 后，分配器仍有
**恰好 5 条**失败，且**可复现**（不是随机或夹具噪声）。失败集合：

| 用例 | 期望 | 实测 |
| --- | --- | --- |
| 截止更早者先分配 | 240 | 600 |
| 35% 负载的日子胜过 92% | `{5: 30}` | `{6: 30}` |
| 截止之后的日子不得分走预算 | `{5, 6}` | `{10, 11}` |
| 150/30 选择 5 天 | 150 | 90 |
| 连续周期轮换 | 不同集合 | 相同集合 |

### 5.1 探针输出（决定性证据）

夹具 `dueAtUtc = localMidnightUtc(10-08) = 2026-10-07T16:00Z`，账本只含
`{10-05, 10-06, 10-10, 10-11}`：

```text
day=5  endUtc=2026-10-06T00:00Z  endAfterDue=false   ← 被排除，但它应当可用
day=6  endUtc=2026-10-07T00:00Z  endAfterDue=false   ← 被排除，但它应当可用
day=10 endUtc=2026-10-11T00:00Z  endAfterDue=true    ← 被保留，但它应当被截止排除
day=11 endUtc=2026-10-12T00:00Z  endAfterDue=true    ← 被保留，但它应当被截止排除
```

结果 `budget = {10-10: 120, 10-11: 120}`，与期望 `{5, 6}` 正好相反。

### 5.2 结论：任何"纯 UTC 日键"方案都不可能正确

`DateTime.utc(y, m, d) + 24h` 把 10-05 的终点算成 `10-06T00:00Z`，
而 10-05 这个**本地日**在 `Asia/Shanghai` 下的真实终点是 `10-06T16:00Z`——
相差 8 小时，足以让"截止 10-08 本地零点"把 10-05 与 10-06 全部误判为已过期。

反过来，把日键当**本地**零点（现行 `DateTime(y, m, d + 1)`）会在
`planningWindow` 为 UTC 的夹具里同样出错。**两种写法都错**，因为它们都在猜
一个只有时区数据库才知道的量。

**真正的根因**：日键 `DateTime(y, m, d)` 是"某一天的名字"，
而"这一天在目标时区下的 `[startUtc, endUtc)`"是**账本本可以携带、却没有携带**
的一项输入。

### 5.3 契约修订（取代 §3.1）——**已实施**（提交见 §5.5）

```text
DayCapacitySnapshot 携带该本地日的 UTC 边界：
    startUtc : DateTime?   // 该本地日在 timeZoneId 下的起点
    endUtc   : DateTime?   // == 次日起点，半开区间
```

- `buildDayCapacityLedger` 本来就在算这些边界（它按本地日切分可用时段），
  因此这是**把已有信息暴露出来**，不是新增换算。它**总是**显式填入两个值。
- 两个字段可空，为 `null` 表示"手写夹具不关心时区边界"，此时分配器按
  "`localDate` 即 UTC 日零点"理解（见 §5.5 的取舍说明）。
- 分配器的所有"与 `dueAtUtc` / `availableFromUtc` 比较"必须用账本边界，
  **不得**再用 `DateTime(y, m, d ± 1)` 或 `DateTime.utc(y, m, d) + 24h`。
- 判别式（唯一一种读法）：

  ```text
  排除当且仅当  dayStartUtc >= dueAtUtc        // 这一天整段都在截止之后
  排除当且仅当  dayEndUtc   <= availableFromUtc
  ```

  **注意是 `startUtc` 比截止、`endUtc` 比最早已开始**。两条边界的含义不同，
  因为"能不能放下一段"对截止是"这一天的起点还没过截止"，对最早开始是
  "这一天整段都已经在下界之后"。

### 5.4 为什么这解释了六轮失败

前六轮都在"猜测日键与 UTC 的关系"（用本地零点、用 UTC 零点、用次日零点），
而正确答案不在分配器里，**在账本里**。每种猜测都会让**不同的**子集日子被误判，
于是修好一处、另一处坏掉——这正是六轮表现的形状。

实施顺序（已按此执行）：

1. 给 `DayCapacitySnapshot` 加 `startUtc` / `endUtc`（由 `buildDayCapacityLedger` 填）；
2. 让分配器一律读它；
3. 跑 §4 的验收判据。

### 5.5 实施结果（实测）

**探针（`planningWindow` 为 UTC、`dueAtUtc = start + 2d`、目标 120、片段 30–60）：**

```text
账本边界（UTC 时区，逐日）：
  10-05 start=10-05T00:00Z end=10-06T00:00Z remaining=600
  10-06 start=10-06T00:00Z end=10-07T00:00Z remaining=600
  ...
预算 = {10-05: 60, 10-06: 60}
allocated = 120   shortage = 0        ← 修复前是 90
```

分配器的 23 条用例 + 日容量账本 + 均分器共 **55 条全绿**（改动前也是 55 条全绿，
因此这是"行为不变 + 生产路径变正确"）。

**取舍（必须记录）**：`startUtc` / `endUtc` 做成**可空**，而不是必填。
理由：本仓库有大量手写 `DayCapacitySnapshot` 夹具（跨多个测试文件），
把它们全部改成必填会牵连与本次修复无关的文件；而**生产路径
（`buildDayCapacityLedger`）总是显式传入**，因此正确性不依赖缺省值。

代价：手写夹具表达不了跨时区的截止语义。**这是可接受的吗？**
可接受——因为需要跨时区语义的用例应当走 `buildDayCapacityLedger`
（像 §5.5 的探针那样），而不是手搓账本。

**仍待完成**：本改动只修好了**分配器**。把它接进引擎（Task 6 主体）
仍未完成：`schedule_engine.dart` 至今没有 `allocateTaskDays` 调用。

> 这也解释了为什么 `SearchOutcomeKind` 至今无法在界面上出现：
> 没有跨日分配，就没有"状态预算耗尽"可言。Task 9 的最后一步被 Task 6 阻塞。

---

## 6. 引擎接线的实测记录（第 21 轮，已回退）

按 §3 契约把分配器接进引擎后**实测**（改动已回退，因为下面第 3 条不可接受）：

### 6.1 达成的效果（证明接线方向正确）

- **Task 1 的红灯转绿 2 条**：
  - `schedule_engine_test`「普通任务的跨日负载」→ 绿；
  - `capacity_aware_week_planning_test`「150/30 不得固定选择前五个日期」→ 绿。
  这是**跨日分配真正生效**的直接证据：普通任务不再天然挤向窗口前部。
- 基线红灯由 5 条降到 3 条。

### 6.2 接线必须成对传的两个数（契约 §3.2，已实测）

```dart
targetMinutesByTask: {
  for (final task in problem.tasks)
    task.id: math.max(0, targets[task.id]! - (scheduledByTask[task.id] ?? 0)),
},
alreadyScheduledMinutesByTask: {
  for (final task in problem.tasks) task.id: scheduledByTask[task.id] ?? 0,
},
```

- 只传 `targetMinutesByTask`（不给 `alreadyScheduledMinutesByTask`）：
  分配器会把已排分钟**再减一次**，预算偏小（实测"远期任务"只排 90 而非 120）。
- 两者都传 ⇒ `remaining = (targets − scheduled) − (planned − scheduled) = targets − planned`，
  两边同源，与引擎的 `remaining` 一致。

### 6.3 不可接受的代价（回退原因）

1. **`even` 任务的按日分布被破坏**：210 分钟、四天各余 120、最小片段 50 时得到
   `[50, 50, 50, 60]`，而既有用例（`recurring_even_distribution_test`，用户实测回归）
   要求 `[50, 50, 55, 55]`。
   原因：旧路径用 `even_distribution_allocator.dart` 的**水位分配**（真均衡），
   新路径用 `day_allocation.dart` 的**轮转 + 余数落在排名首位**。
   已在 `even` 分支加"按开放天数摊份额"的修正，但**实测未生效**，
   说明 `even` 任务当前并不走那条分支（`chunkMinutes` 与调用路径需进一步确认）。
2. **另外 2 条既有用例转红**：`movable_daily_limit_test`「锁定块不计入可移动上限」、
   `week_view_test` ×2（跨页面刷新）。
3. **规模性能退化约 7 倍**：全量 `flutter test` 由约 1.5 分钟变成约 11 分钟。
   算法 17 明确要求性能不得退化，因此这一条单独就足以阻止提交。

### 6.4 下一步（有据可依，不要再盲改）

1. **先让 `even` 走回水位分配**：`even_distribution_allocator.dart` 的水位逻辑是
   正确的，且已有 18 条用例覆盖。可选做法是在 `allocateTaskDays` 内部对
   `TaskDistributionPolicy.even` 复用该逻辑（而不是在轮转里补丁），
   或让引擎对 `even` 任务**照旧调用** `allocateEvenDistribution`、只对非 `even`
   任务用 `day_allocation`。
2. **定位性能退化**：11 分钟 vs 1.5 分钟是数量级问题。最可能的来源是
   **每个候选都要查 `budgetPolicy`**（`_budgetRemaining` 每次遍历 `blocks`），
   而候选数是"起点 × 时长"展开的（规模用例里数百万）。
   处置方向与 Task 2 修过的 `PolicyLookupCache` 同形：**把当日已用分钟做成增量表**，
   而不是每个候选重算。
3. 三条代价都解决后再跑 §4 验收判据。

**教训**：接线这次失败的原因与前面七轮不同——前七轮是"分配器算错"，
这一轮分配器是对的，**错在把它接上去的代价**（`even` 语义 + 性能）。
因此回退是正确的：接线本身有效（两条红灯转绿），但必须连同 `even` 与性能一起解决。

---

## 7. `even` 任务的按日分摊算法（本轮推导，**实施前必读**）

§6.3 第 1 条（`[50, 50, 50, 60]` 而不是 `[50, 50, 55, 55]`）的根因已经定位到
**分配器内部**，不需要再靠引擎侧试错。

### 7.1 现行写法为什么必然给出错误形状

`day_allocation.dart` 的落地循环对 `even` 任务是：

```text
chunkMinutes = min(最小片段, 最大片段) 向上取整到粒度     // 本例 = 50
每一轮：每个参与日各加 min(chunkMinutes, 该日余量)
```

对"目标 210、四天各余 120、粒度 5"：

| 轮 | 结果 |
| --- | --- |
| 第 1 轮 | `[50, 50, 50, 50]`，剩 10 |
| 第 2 轮 | 排名第一的那天 +10 ⇒ **`[60, 50, 50, 50]`** |

**余数永远落在排名第一的日期上**，因为 `placedAnything` 的循环先把它填满。
这就是实测形状。计划 §3.1 要的"每天尽量均衡"**不是**这个意思。

### 7.2 正确的判据（可直接实现）

对 `even` 任务，参与日集合确定之后，应当**按天数等分而不是按片段轮转**：

```text
K        = 参与日个数（§3.4 第 6 条已经算好）
base     = ⌊目标 / K⌋ 向下取整到粒度          // 210/4 = 52 → 50
remainder= 目标 − base × K                    // 210 − 200 = 10
```

然后：

1. 每个参与日先拿 `base`；
2. 余量按**粒度**逐份发给排名靠前的日期，发完为止
   （本例：`10 / 5 = 2` 份 ⇒ 排名前两位各 +5 ⇒ **`[55, 55, 50, 50]`**）。

这与既有用例期望的"两个 50 与两个 55"**完全一致**（顺序按排名，不要求
`[50, 50, 55, 55]` 的字面顺序——用例比较的是分布集合）。

### 7.3 为什么不能复用 `even_distribution_allocator.dart`

那个文件的**水位分配**（每轮把一份粒度给"当前新增最少且仍有余量"的日期）
已经能给出正确形状，且被 18 条用例覆盖。它与 §7.2 是同一件事的两种写法。

两条路都可行，但**必须选一条并让另一条不参与生产路径**：

- **方案 A（推荐）**：`allocateTaskDays` 内部对
  `TaskDistributionPolicy.even` 直接按 §7.2 计算，不再走轮转循环。
- **方案 B**：引擎对 `even` 任务继续调用 `allocateEvenDistribution`
  （保留水位分配），只对非 `even` 任务用 `allocateTaskDays`。

**不要**在轮转循环里对 `even` 打补丁——§6.3 已经试过，实测未生效，
因为那条分支的进入条件与 `chunkMinutes` 的关系并不直观。

### 7.4 性能（§6.3 第 3 条）的处置方向

7 倍退化最可能的来源：`budgetPolicy` 的 `_budgetRemaining` **每个候选都遍历一遍
`blocks`**，而候选数是"起点 × 时长"展开的（规模用例里数百万）。

处置与 Task 2 修过的 `PolicyLookupCache` **完全同形**：把"该任务在该本地日已排分钟"
做成**增量维护的 `Map<String, Map<DateTime, int>>`**：

- `blocks` 每新增一块 ⇒ 该任务的当日计数 `+= duration`；
- 候选判定改为查表，O(1)。

注意 `blocks` 也会被**移除**（§3.3 撤掉上一轮 `even` 安排那条路径），
因此增量表必须同时支持扣减，或者在那一步之后重建一次。

---

## 8. 第 24 轮接线实测（**增量表已实现，接线仍回退**）

按 §6.2 的两个数与 §7.4 的增量表重新接线后实测：

### 8.1 已解决

| 项 | 结果 |
| --- | --- |
| `even` 按日分布 | ✅ `recurring_even_distribution_test` **转绿**（round 23 的 `index++` 修好了它） |
| 普通任务跨日负载 | ✅ `schedule_engine_test`「普通任务的跨日负载」**转绿** |
| 150/30 普通任务 | ✅ `capacity_aware_week_planning_test`「150/30 不得固定选择前五个日期」**转绿** |
| 规模用例性能 | ✅ `scale_smoke_test` 单文件 **12 秒**（基线 10.2 秒的 `elapsedMs=10236`），**
未退化** |

增量表的实现方式（本轮已验证可用）：

```dart
final taskMinutesByDate = <String, Map<DateTime, int>>{};
void chargeTaskMinutes(PlannedBlock block) {
  final byDate = taskMinutesByDate.putIfAbsent(block.taskId, () => {});
  final date = _localDate(block.startUtc, problem.timeZoneId);
  byDate[date] = (byDate[date] ?? 0) + block.durationMinutes;
}
for (final block in blocks) chargeTaskMinutes(block);   // 建初值：按**当前** blocks
// 放置成功处：blocks.add(block); chargeMovable(block); chargeTaskMinutes(block);
```

`budgetPolicy` 与 `plannedMinutesForTaskByDate` 都改为查这张表。

### 8.2 仍未解决（回退原因）

**① `movable_daily_limit_test`「锁定块不计入可移动上限」与账本口径直接冲突**（本轮定位）

这不是"接线写错了"，而是**两套互相矛盾的额度口径**：

| 来源 | 主张 | 依据 |
| --- | --- | --- |
| `movable_daily_limit_test` | 锁定块 300 + 可移动上限 360 ⇒ 300 分钟的可移动任务**仍应排下**（锁定额度与可移动额度分开计） | 该用例的注释：「否则用户一锁定就会把当天预算吃满」 |
| `day_capacity_ledger.dart` | `usedMovableMinutes` **包含**锁定块 ⇒ 许可 360、锁定 300 时只剩 **60** | 直接引用计划 §2 原文，并记录了反向做法的实测症状（许可 180、锁定 60、本该剩 120 却报 180，于是引擎把锁定块占着的时间又排了一遍） |

**两者不可能同时成立。** 已把账本实际给出的数字钉成用例
（`day_capacity_ledger_test`「锁定块占用可移动额度 ⇒ 许可 360、锁定 300 时只剩 60」），
好让分歧成为可决断的一条，而不是模糊地带。

**必须先决断**（这是产品/计划层面的取舍，不是实现细节）：

- 选 **A（账本口径）**：改 `movable_daily_limit_test` 的期望，锁定块占额度。
- 选 **B（测试口径）**：账本另立 `lockedMinutes` 字段并从 `remainingMinutes` 里加回，
  即"锁定额度不占可移动额度"。这会让 §2 的 `usedMovableMinutes` 定义需要修订。

**② `week_view_test` ×2 转红**（跨页面刷新、早餐规则）。走完整装配 + 界面，需单独定位。

**③ 全量 `flutter test` 仍约 11 分钟**（基线约 1.5 分钟）。
**注意**：`scale_smoke_test` 单独跑只有 **12 秒**（基线 `elapsedMs=10236`），
因此瓶颈**不在规模用例**，而在别的（尚慢）测试文件上。
下一轮应当**逐文件计时**定位，而不是继续猜。


### 8.3 下一步

1. 先修 `movable_daily_limit` 的账本口径（§8.2 第 1 条）——它是**正确性**问题，
   且与分配器直接相关。
2. 逐文件计时找出 11 分钟的来源（`week_view_test` 是首要嫌疑）。
3. 两者都解决后再提交接线。

**注意**：`golden_week` 与 Task 1 的两条断言（`360` / `{5}`）在接线后仍是红，
那是**预期**的（Task 1 的判据需要在接线后重新校准，golden 归 Task 13）。




