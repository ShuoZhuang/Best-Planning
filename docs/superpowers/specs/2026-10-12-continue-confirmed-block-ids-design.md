# 让引擎以「原 id」延续已确认的块

**状态**：**提案，未实现**。需要一次明确的设计确认。

**背景**：这是 `2026-10-11-core-workflow-repair-implementation-plan.md` 的 Task 12c
遗留的一处结构性缺口。它**不在原计划授权范围内**，因此没有在 1.8.0 批次里动手。

---

## 1. 问题：`minimizeChangedBlocks` 在生产路径上是空操作

`lib/scheduling/local_repair.dart` 的 `minimizeChangedBlocks` 按
`ScheduleProblem.referenceBlocks`（块 id → 调整前的开始时刻）把**还能回到原位**的块放回原位。
它是「少动块、少位移」（规范 §11.4 第 3、4 条）的唯一执行点。

但在真实装配下它**一个块都不会动**：

| 事实 | 位置 |
| --- | --- |
| 引擎给新排的块起 id 的规则是 `block:<taskId>:<开始微秒>:<时长>` | `schedule_engine.dart` 的 `_blockId` |
| 确认计划里块的 id 是 `<提案 id>:<引擎块 id>` | `drift_plan_repository.dart:267` |
| `referenceBlocks` 的键取自确认计划 | `repository_schedule_problem_source.dart` |

两族 id **永远不会相等**，因此 `referenceBlocks` 的每一项都匹配不上引擎排出的块
（生产路径上实际走的是「参照完全匹配不上 ⇒ 逐值返回输入」那条分支，
已有用例 `minimize_changed_blocks_test.dart` 的「参照匹配不上任何块时」钉住）。

**证据**：`test/scheduling/engine_minimizes_changes_test.dart` 的「已知缺口」用例。

**为什么单元测试没发现**：那 9 条用例直接喂进「参照与块同 id」的构造数据。
**函数是对的，接线是空的**——单元测试天然看不到接线。本批次同类缺陷已出现三次
（`recurringNotifications` 从未被构造、`referenceBlocks` 被 `withCurrentInputHash` 丢掉、
这一处）。

---

## 2. 目标与非目标

**目标**：让「保持原位」这件事在真实装配下可表达，从而
（a）`minimizeChangedBlocks` 真的生效；（b）§3 矩阵第 8 行的「只最小改动后续块」有自动化证据；
（c）为 §11.4 第 6 条（不制造坏空档）的方案级比较提供可比的多份候选（Task 13b 的前置）。

**非目标**：不改变「一次生成从零排一遍」的算法结构；不引入增量排程；
不改变锁定块与手动拖动钉住（`pinnedUnlockedBlockIds`）的既有语义。

---

## 3. 提议的改动

### 3.1 核心：候选携带它要延续的块 id

`PlannedBlock` 增加一个可空字段，表示「这一块是**延续**自某个已确认块」：

```dart
final class PlannedBlock {
  const PlannedBlock({
    required this.id,
    required this.taskId,
    required this.range,
    this.locked = false,
    this.explanationCode,
    this.continuedFromId,   // 新增：已确认块的持久化 id
  });
}
```

放置时：

- 候选与某个已确认块**对应**（见 3.2）⇒ `id` 用 `continuedFromId`，
  且**保持 `locked: false`**（延续不等于锁定）；
- 候选没有对应 ⇒ 走现在的 `_blockId(task.id, candidate)`。

`_blockId` 的实现不变——它仍然服务于「新排进来的块」。

### 3.2 「对应」的判据

一个已确认块与一个候选对应，当且仅当**两者属于同一任务**，且该任务在当前放置阶段
**还没有**用过它。

理由：`PlannedBlock` 是任务级分块的结果，同一任务可能有多块；按「同任务、先到先得」
配对是唯一不需要额外信息的稳定判据。**不按时间最近配对**：那会让「块被移动」这件事
本身就破坏配对，而配对恰恰要在移动之后仍然成立。

**顺序必须确定**：已确认块按 (taskId, startUtc, id) 排序后依次配对；否则同一输入
可能得到两种 id 分配，而 id 会落库。

### 3.3 `existingBlocks` 的角色变化

现在：`existingBlocks` 只喂 `_movesExistingBlock` 评分（`schedule_engine.dart:1004`），
**不进** `blocks`，因此不占时间。

改动后：已确认未锁定的块**以原 id 进入 `blocks`**。这会带来两个必须处理的连带后果：

1. **占用**：它们进入 `blocks` 后就会被 `_decorateOccupancy` 一类逻辑当成占用。
   这正是「稳定性」想要的效果（旧安排不再被当成空档），
   但会改变可用时间，因此**必然改变分块**。
2. **与 `lockedBlocks` 的关系**：`problem.lockedBlocks` 里同时装着真锁定的块和
   「上一轮确认计划里未锁定」的块（见 `schedule_engine.dart` 关于均匀分布那段注释）。
   改完之后**同一批块可能出现在两处**（`lockedBlocks` 与 `existingBlocks`），
   必须去重，否则会**插两次、id 冲突**。

   → **这一条是最大的风险点**，见 §5.1。

### 3.4 若采纳，需要同步的地方

`withCurrentInputHash`（`planning_service.dart`）**逐字段重建** `ScheduleProblem`。
本批次已经因为漏掉新字段而静默丢过一次 `referenceBlocks`。任何新增字段都必须同步那里，
并在注释里点名。

---

## 4. 影响面

| 面 | 影响 | 处置 |
| --- | --- | --- |
| `golden_week.json` | 分块位置会变（旧安排不再被当空档） | 必须重新生成，并**人工逐值复核**新结果是否更合理，而不是无脑覆盖 |
| 算法版本 | 必须抬到 `12` | 设计 §5.1：任何改变结果的改动都要抬版本 |
| `applyProposal` | **不需要改**：`persistedId = '<提案 id>:<block.id>'`，`block.id` 是延续来的原 id ⇒ 同一块的持久化 id 前后一致 | 见 §5.2 的一个例外 |
| 撤销（`restoreVersion`） | `restoredId` 的生成方式不受影响 | 复核 3 条撤销用例 |
| `pinnedUnlockedBlockIds` | 手工拖动钉住的块本来就以原 id 进 `lockedBlocks`，语义不变 | 复核 C8 「重放不一致」用例 |
| `plan_differ` | 块 id 稳定后，预览的措辞会从「删除 + 新增」变成「移动」 | 见 §5.2：**输出类型变、判定逻辑不变** |

---

## 5. 已知风险

### 5.1 同一批块同时出现在 `lockedBlocks` 与 `existingBlocks`（高）

`RepositoryScheduleProblemSource` 目前把确认计划里**未锁定**的块放进 `existingBlocks`，
而 `lockedBlocks` 里另有「真锁定」与「拖动钉住」两类。改完之后：
未锁定的块要进 `blocks`，而引擎已经会原样收下 `lockedBlocks`——两条路都指向同一块。

**处置**：在装配层做**单一来源**：确认计划里每个块只进一处——
真锁定／钉住 ⇒ `lockedBlocks`；未锁定 ⇒ `existingBlocks`（并因 3.3 而进 `blocks`）。
并用一条用例断言「结果里没有任何 id 出现两次」。

### 5.2 `plan_differ` 的「移动」判定（中）

`plan_differ.dart` 的注释已经写明：`moved` = **同一块 ID 仍在**但任务／时间／锁定状态变了。
因此它**不依赖**「id 变化」，不需要改判定逻辑。

但**输出的类型会变**，这才是要复核的点：

- **现在**（id 不稳定）：同一块从 09:00 挪到 14:00，两轮 id 不同 ⇒ 报
  `removed`(09:00) ＋ `added`(14:00)；
- **改动后**（id 稳定）：同一块报 `moved`。

也就是说这次改动会**改变预览页的措辞**：用户从「删除了一项、新增了一项」变成
「移动了这一项」。**后者才是对的**（§3 矩阵第 8 行要求的正是"排入目标之后最近合法位置"），
但它是一次**用户可见的文案变化**，必须由一条用例固定住，而不是靠观察。

→ 用例：同一 id 从 A 时刻移到 B 时刻 ⇒ `PlanChangeType.moved`。

### 5.3 `_improve` 阶段可能把延续来的块搬走（中）

`_improve` 跳过 `locked` 的块。延续来的块不锁定，因此**会被局部改进移动**——
那正是我们想要的（否则稳定性会冻结偏斜）。但要注意它与
「均匀分布任务先撤掉上一轮安排」（`schedule_engine.dart` 那段注释）的交互：
两条机制都作用于同一批块，**必须有用例覆盖它们的相对优先级**。

### 5.4 撤销语义（低）

`restoreVersion` 用 `restoredId` 前缀，与块 id 无关。但「撤销之后块 id 变了一次」
意味着 `referenceBlocks` 会在下一轮指向**撤销前**的 id。这**恰好是我们想要的**
（撤销也是一种调整），但应当有一条用例说明这个行为是刻意的。

---

## 6. 验收判据（采纳后必须全部满足）

1. `engine_minimizes_changes_test.dart` 的「已知缺口」用例**改为**断言
   「原位无冲突时块被放回，且 `movedBlockIds` 为空」——即该缺口关闭；
2. 新增用例：结果里没有任何块 id 出现两次（§5.1）；
3. 新增用例：`plan_differ` 把「同 id 不同时刻」报为移动（§5.2）；
4. 新增用例：延续来的块可以被 `_improve` 移动，且均匀分布任务仍能恢复均匀（§5.3）；
5. `golden_week.json` 重新生成并**人工复核**通过；
6. 算法版本 = `12`，两处（引擎常量与 fixture）一致；
7. 全量回归 0 失败。

---

## 7. 需要你决定的事

1. **是否采纳本提案**（它改动的是排程核心的起点语义，超出 1.8.0 批次授权）；
2. 若是，**是否接受 `golden_week.json` 的分块结果变化**——这会改变用户已确认计划在
   下一次生成时的落点，属于**用户可感知的行为改变**，需要明确认可；
3. 是否同意把算法版本抬到 `12`（意味着历史计划不再能按 `11` 复现）；
4. 是否接受预览措辞的变化（§5.2：同一块从「删除＋新增」变为「移动」）。
   **我判断这是修正而非退化**，但它会改变用户在预览页看到的东西。

---

## 附：本文中每条代码引用的核对结果

| 论断 | 核对方式 | 结果 |
| --- | --- | --- |
| 引擎块 id 形如 `block:<taskId>:<微秒>:<时长>` | 读 `schedule_engine.dart` 的 `_blockId` | 属实 |
| 持久化 id 形如 `<提案 id>:<引擎块 id>` | 读 `drift_plan_repository.dart:267` 的 `persistedId` | 属实 |
| `existingBlocks` 只喂评分、不进 `blocks` | 全文件搜索 `existingBlocks` 仅命中 `_movesExistingBlock` 与文档注释 | 属实 |
| `_improve` 跳过 `locked` 的块 | 搜索 `if (block.locked) continue;` 命中 `schedule_engine.dart:1272` | 属实 |
| `plan_differ` 按**同一 id 仍在**判「移动」 | 读 `plan_differ.dart` 的变更类型说明 | 属实（§5.2 原先的说法据此更正） |
| `withCurrentInputHash` 逐字段重建 `ScheduleProblem` | 本批次已因此丢过一次 `referenceBlocks` | 属实 |
