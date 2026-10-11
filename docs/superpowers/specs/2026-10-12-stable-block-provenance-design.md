# 稳定来源关联、块级延后、局部级联与方案级坏空档比较

**状态**：**已获批准，正在实施**（原「提案」状态已结束）。

**裁定要点**（2026-10-11，用户正式决定）：

1. **采纳修复方向，但必须先修订设计**——不得照原文档实施；
2. 接受 `golden_week.json` 发生合理变化，但**不得直接覆盖基准文件**，
   必须提交逐块前后对比，确认没有重复安排、休息被吞、已确认块丢失或总安排时长异常；
3. 同意算法版本升到 `12`——**稳定身份、块级延后、局部级联、方案级坏空档比较
   作为同一次算法升级**完成，最后统一升到 12。它是内部排程算法版本，不是软件版本号；
4. 接受预览从「删除＋新增」改为「移动」，但**必须根据来源关联判断，
   不能通过复用数据库主键实现**。

---

## 0. 本版（第二版）相对第一版的**更正**

第一版有四处被裁定驳回。逐条记录，因为**错误的推断过程本身就是风险**：

| # | 第一版的说法 | 事实 | 更正 |
| --- | --- | --- | --- |
| 1 | 「`applyProposal` 不需要改：`block.id` 用延续来的原 id ⇒ 持久化 id 前后一致」 | **错。** `persistedId = '${proposal.proposalId}:${block.id}'`（`drift_plan_repository.dart:267`），而 `applyProposal` 存回的 `PlannedBlock.id` **就是** `persistedId`。复用旧 id 会让每确认一次就再套一层提案前缀，**id 无限增长** | `id` 与来源身份**分开**：新增 `continuedFromId`，`id` 始终保持引擎生成的新值 |
| 2 | 「已确认未锁定的块**以原 id 进入 `blocks`**」 | **危险。** 旧块成为占用却没有自动扣除任务待排时长 ⇒ **同一件工作可能被安排两次**；且与「仍然从零生成」自相矛盾 | **不从零路径塞旧块**。全量生成保持从零，**生成后**再建一对一来源关联 |
| 3 | 配对判据「同任务、先到先得」 | **不确定且不公平**：同一任务的多个块之间没有可比较的依据 | 改为**确定性代价匹配**（同任务 → 时长差最小 → 位移最小 → 原/新 id 作最终排序键） |
| 4 | 「稳定身份是 Task 13b 的前置」（未定义调用点） | **不完整。** 只解决身份识别，没有定义生产调用点 | 明确两条路径：**普通生成 = 全量生成**；**延后 = 调整路径**（以当前确认计划为基线、以准确 `targetBlockId` 调用 `localRepairCascade`） |

另外新增一处**原设计完全遗漏**的内容：**块级延后必须保留块级请求**，
不得继续降成任务级 `availableFromUtc`（见 §4）。

---

## 1. 问题一：`minimizeChangedBlocks` 在生产路径上是空操作

`lib/scheduling/local_repair.dart` 的 `minimizeChangedBlocks` 按
`ScheduleProblem.referenceBlocks`（块 id → 调整前的开始时刻）把**还能回到原位**的块放回原位。
它是「少动块、少位移」（规范 §11.4 第 3、4 条）的唯一执行点。

但真实装配下它**一个块都不会动**：

| 事实 | 位置 |
| --- | --- |
| 引擎给新排的块起 id 的规则是 `block:<taskId>:<开始微秒>:<时长>` | `schedule_engine.dart` 的 `_blockId` |
| 确认计划里块的 id 是 `<提案 id>:<引擎块 id>` | `drift_plan_repository.dart:267` |
| `referenceBlocks` 的键取自确认计划 | `repository_schedule_problem_source.dart` |

两族 id **永不相等** ⇒ `referenceBlocks` 每一项都匹配不上引擎排出的块
（生产路径实际走「参照完全匹配不上 ⇒ 逐值返回输入」那条分支，
已有用例 `minimize_changed_blocks_test.dart` 的「参照匹配不上任何块时」钉住）。

## 2. 问题二：延后被降成**任务级**下界

`repository_schedule_problem_source.dart` 把「指定块的延后请求」转成**整个任务的**
`availableFromUtc`：

```dart
deferredTaskStarts[block.taskId] = notBefore;   // 任务级
...
availableFromUtc: _laterOf(task.availableFromUtc, deferredTaskStarts[task.id]),
```

后果：**延后一块会把它自己其余的块也一起推后**。规范 §11.1 的文案是
「只调整当前计划块」，§11.4 第 3、4 条也要求「移动的其他块数量最少」——
任务级下界与这两条都不符。

## 3. 问题三：`localRepairCascade` 生产零调用

它被 12 条用例覆盖、行为正确，但断言搜索只命中它自己的定义与测试文件。
**函数是对的，接线是空的**——本批次同类缺陷已出现多次
（`recurringNotifications` 从未被构造、`referenceBlocks` 被 `withCurrentInputHash` 丢掉、
`minimizeChangedBlocks` 因 id 不同族而空操作）。

## 4. 问题四：候选级坏空档惩罚**实测不可用**

`maximumUnusableGapPenalty` 逐值实测：`0` 全绿；`-50`／`-100`／`-150`／`-500` **各 2 红**
（黄金周缺口 30→90、不区分任务类型的间隔 10→60）。**没有「小一点就安全」的空间**，
因此「调小权重」不是出路。规范 §11.4 第 6 条本来就要求在**方案**层面比较，
而不是在单个候选放置上打分。

---

## 5. 设计

### 5.1 `id` 与来源身份分开（对应更正 1）

```dart
final class PlannedBlock {
  const PlannedBlock({
    required this.id,             // 本提案内引擎生成的新 id，**始终是新的**
    required this.taskId,
    required this.range,
    this.locked = false,
    this.explanationCode,
    this.continuedFromId,         // 新增：可空，指向**当前确认计划**里的块 id
  });

  /// 它延续自哪一块；`null` 表示这是新排进来的块。
  final String? continuedFromId;
}
```

**语义分工必须写死，否则两族 id 会再次混用**：

| 用途 | 用哪个 id | 理由 |
| --- | --- | --- |
| 落库（`applyProposal` → `persistedId`） | `id` | 保持 `'<提案 id>:<新块 id>'` 不变，**绝不叠加** |
| 查原位（`minimizeChangedBlocks` 的 `referenceBlocks`） | `continuedFromId` | 参照的键本来就是确认计划的 id |
| 判「移动」（`PlanDiffer`） | `continuedFromId` | 同一来源块在前后两版之间的关联 |
| 引擎内部占用／冲突 | `id` | 同一次生成内的唯一标识 |

**`continFromId` 本批次只作为提案期关联，不需要数据库迁移**
（确认裁定第 1 点）：它存在 `ProposedBlock`／`PlannedBlock` 的内存结构里，
落库时被丢掉，下次生成再由 §5.2 的匹配重新建立。

`_blockId` 的实现不变——它仍然服务于「新排进来的块」。

### 5.2 从零生成 → 生成后建一对一来源关联（对应更正 2、3）

**普通「生成计划」路径完全不改**：仍然是一次从零排一遍，
`existingBlocks` 仍然只喂 `_movesExistingBlock` 评分、**不进 `blocks`**。
因此不存在「旧块占位但任务时长未扣除 ⇒ 同一工作排两次」的风险。

生成之后，把**新块**与**当前确认计划的块**做一对一匹配：

```
1. 同一 taskId；
2. 时长差最小；
3. 开始时间位移最小；
4. 原块 id 与新块 id 作为最终排序键（保证顺序确定）。
```

- 匹配上的新块 ⇒ 设 `continuedFromId = 旧块.id`；
- 多出来的新块 ⇒ `continuedFromId = null`（新排进来）；
- 未被匹配的旧块 ⇒ 视为**删除**。

**为什么不用「同任务先到先得」**：同一任务的多个块之间没有可比较依据，
结果取决于遍历顺序；而 §11.4 第 3、4 条要的正是"少动"，那要求配对本身是**代价最优**的。

**匹配必须确定性**：第 4 条排序键保证同一输入永远得到同一份配对，
否则 `continuedFromId` 会漂，而它会决定预览措辞与最小化结果。

### 5.3 块级调整上下文进入 `ScheduleProblem`（对应更正 4 的前半）

`ScheduleProblem` 增加一个可空的调整上下文，**取代**任务级下界模拟：

```dart
/// 一次「调整当前计划块」的上下文（1.8.0，规范 §11.3／§11.4）。
final class BlockAdjustmentContext {
  const BlockAdjustmentContext({
    required this.targetBlockId,   // 要调整的那一块（确认计划里的 id）
    required this.notBeforeUtc,    // 下界，**不是**必须精确占用的点
    required this.kind,            // 目前只有 defer；将来可扩展
  });

  final String targetBlockId;
  final DateTime notBeforeUtc;
  final BlockAdjustmentKind kind;
}

enum BlockAdjustmentKind { defer }
```

`ScheduleProblem` 增加 `BlockAdjustmentContext? adjustment`。

**装配层不再写 `deferredTaskStarts`**，因此**不再抬高任务的 `availableFromUtc`**：
一个任务的其他块不再被延后牵连。规范 §4.1 的教训在这里同样适用——
**任务级字段模拟块级意图**就是"用错的抽象层级表达一件事"。

`withCurrentInputHash`（`planning_service.dart`）**逐字段重建** `ScheduleProblem`，
本批次已因漏字段静默丢过一次 `referenceBlocks`。新增字段**必须**同步那里并在注释里点名。

### 5.4 两条生产路径（对应更正 4 的后半）

| 路径 | 触发 | 行为 |
| --- | --- | --- |
| **全量生成** | 生成计划按钮、领域变化后的自动重排 | 从零排一遍 → §5.2 建来源关联 → `minimizeChangedBlocks` → 方案级比较（§5.5） |
| **调整路径** | 「延后当前计划块」 | 以**当前确认计划为基线**，用准确的 `targetBlockId` 调用 `localRepairCascade` → 方案级比较（§5.5） |

调整路径的硬要求：

1. 使用**准确的 `targetBlockId`**（不是任务 id）；
2. 每个当前块在候选方案中**只能出现一次**（否则同一工作被排两次）；
3. **当天无合法方案时，才搜索后续日期**（§11.4 末段：先在当天做向后级联）。

### 5.5 方案级比较：接上真正的方法级选择（Task 13 的决定）

**候选级权重保持 `maximumUnusableGapPenalty = 0`，不再尝试负权重。**

为调整操作生成**有限、确定的**合法方案集合，然后按规范 §11.4 的顺序逐级比较：

| 级 | 比较项 | 实现位置 |
| --- | --- | --- |
| 1 | 硬约束全部满足 | 方案生成阶段（不可行者不进集合） |
| 2 | 目标块开始时间**不早于** `notBeforeUtc` | 同上 |
| 3 | 移动其他块的数量 | `LocalRepairPlan.compare` |
| 4 | 所有被移动块的总位移分钟 | `LocalRepairPlan.compare` |
| 5 | 目标块距离 `notBeforeUtc` | `LocalRepairPlan.compare` |
| 6 | **`orphanGap` 数量** | **新增：`gap_classifier.dart`** |
| 7 | **`orphanGap` 总分钟** | **新增** |
| 8 | 其他软偏好 | 既有评分 |
| 9 | 最终稳定签名 | `LocalRepairPlan._signature` |

**第 6、7 级用 `gap_classifier.dart` 的四类分类**（本批次已实现并有用例）：

- `intentionalBreak`（保护时间／规则休息）与 `freeTime`（无任务可填、或日容量已达上限）
  **永远不计为坏空档**；
- 只有 `orphanGap`（大于过渡休息、但小于所有候选任务的最小片段）计入。

**硬性禁止**（不得为了减少坏空档而做）：

- 缩短 `minBreak`；
- 覆盖保护时间；
- 移动锁定块；
- 超过每日可排上限。

这四条是"减少坏空档"这一目标本身的**边界**：越过它们的方案不是"更紧凑"，
而是**违反了别的硬约束**，因此必须在级别 1 就被排除，而不是留到级别 6 再权衡。

### 5.6 `gap_classifier` 与 `unusable_gap` 的关系

两者并存，职责不同，**不要合并**：

- `unusable_gap.dart`：回答"要不要惩罚"（`findUnusableGaps`），被候选级评分使用；
- `gap_classifier.dart`：回答"这段间隔**是什么**"（四类），被方案级比较与解释层使用。

**排序注意事项**（已在 `unusable_gap.dart` 修过一处同类缺陷）：
判定游标必须在**全部排除条件之后**才推进，否则被排除的那一段会**吃掉后面那一段**。

---

## 6. 影响面

| 面 | 影响 | 处置 |
| --- | --- | --- |
| `golden_week.json` | 分块位置会变 | **不得直接覆盖**：先产出逐块前后对比表，逐项确认（见 §7 第 2 条） |
| 算法版本 | **统一升到 `12`** | 一次升级涵盖：稳定身份、块级延后、局部级联、方案级坏空档比较 |
| `applyProposal` | **不改**（真正不改：`id` 始终是引擎新 id，`persistedId` 仍是 `'<提案 id>:<id>'`） | 补一条"连续确认两次，id 不叠加"的用例 |
| `plan_differ` | 判据从"同一 `id` 仍在"改为"`continuedFromId` 相连" | **输出类型的变化是目的**（删除＋新增 → 移动），需用例固定 |
| 撤销（`restoreVersion`） | `restoredId` 生成方式不受影响 | 复核 3 条撤销用例 |
| `pinnedUnlockedBlockIds` | 手工拖动钉住的块语义不变 | 复核 C8「重放不一致」用例 |
| `withCurrentInputHash` | **必须同步新字段** | 否则重演丢 `referenceBlocks` 的缺陷 |

---

## 7. 风险

### 7.1 `golden_week.json` 的变化可能掩盖真实回归（高）

裁定第 2 点要求**逐块前后对比**。对比表必须逐项回答四个问题：

1. **有没有重复安排**（同一任务在同一时段出现两次）；
2. **有没有休息被吞**（两块之间的休息短于规则要求）；
3. **有没有已确认块丢失**（某一任务的已排时长明显减少）；
4. **总安排时长有没有异常**（与任务剩余总时长不符）。

**任一项不满足即视为回归**，必须先修算法再谈更新基准。

### 7.2 预览措辞变化（中）

`plan_differ` 的判据从 id 相等改为 `continuedFromId` 相连之后，
同一块从 09:00 挪到 14:00 会从 `removed` ＋ `added` 变成 `moved`。
这正是裁定第 4 点接受的变化，但**必须由来源关联判断**——不得靠复用数据库主键，
否则会引入 §0 更正 1 的 id 叠加。

### 7.3 `_improve` 可能把延续来的块搬走（中）

`_improve` 跳过 `locked` 的块。延续来的块**不锁定**，因此会被局部改进移动——
这是想要的（否则稳定性会冻结偏斜）。但它与「均匀分布任务先撤掉上一轮安排」
（`schedule_engine.dart` 相关注释）作用于同一批块，**两者的相对优先级必须有用例**。

### 7.4 调整路径与全量路径的一致性（中）

两条路径都产出 `ScheduleProposal`，而预览与落库只认后者。
必须有用例断言：**调整路径产出的方案同样满足硬约束**，
且它不会顺手动到与本次调整无关的块。

### 7.5 撤销后来源关联（低）

`restoreVersion` 用 `restoredId` 前缀，与块 id 无关。但"撤销之后块 id 变了一次"
意味着来源关联会指向撤销前的 id。这**恰好是我们想要的**（撤销也是一种调整），
但应有用例说明这是刻意的。

---

## 8. 验收判据（全部满足方可标记完成）

1. **`continuedFromId` 语义**：`id` 始终是引擎新 id；落库仍是 `'<提案 id>:<id>'`；
   **连续确认两次 id 不叠加**；
2. **来源匹配确定性**：同一输入连算两次，配对逐值相同；按四条代价键匹配，
   不是"同任务先到先得"；
3. **`minimizeChangedBlocks` 真的生效**：`engine_minimizes_changes_test.dart`
   的「已知缺口」用例改为断言"原位无冲突时块被放回，且 `movedBlockIds` 为空"；
4. **块级延后**：延后一块**不再**推后同一任务的其他块（新增用例直接钉住这一点）；
5. **`localRepairCascade` 有生产消费方**，且以准确 `targetBlockId` 调用；
   候选方案中每个当前块**只出现一次**；当天无解才搜后续日期；
6. **方案级比较按 §5.5 的九级顺序**；`intentionalBreak` 与 `freeTime`
   **永不计为坏空档**；不得为减少坏空档缩短休息／覆盖保护时间／移动锁定块／超每日上限；
7. **预览显示「移动」**，且判据是 `continuedFromId` 而非数据库主键；
8. `golden_week.json` 的**逐块前后对比表**已产出并通过 §7.1 四问；
9. **算法版本 = `12`**，引擎常量与 fixture 两处一致；
10. 全量回归 0 失败，`analyze` 干净。

---

## 9. 实施顺序（照裁定的九步，不重排）

1. **修订本设计文档**（本次提交）；
2. 增加 `continuedFromId` 与块关联测试；
3. 增加块级调整上下文（`BlockAdjustmentContext`），**停止任务级下界转换**；
4. 把 `localRepairCascade` 接入延后生产路径；
5. 接入有限方案生成和方案级比较（§5.5 九级）；
6. 验证预览显示「移动」；
7. 审核 `golden_week` 前后差异（§7.1 四问）；
8. 算法版本统一升到 `12`；
9. 运行全量回归。

**在这些条件满足前，不得把 §4.2(a)、§4.2(c) 或 Task 13 第 6 条标记为完成。**

---

## 附：本文每条代码引用的核对结果

| 论断 | 核对方式 | 结果 |
| --- | --- | --- |
| 引擎块 id 形如 `block:<taskId>:<微秒>:<时长>` | 读 `schedule_engine.dart` 的 `_blockId` | 属实 |
| `persistedId = '<提案 id>:<block.id>'`，且 `applyProposal` 存回的 `PlannedBlock.id` 就是它 | 读 `drift_plan_repository.dart:267` 与 `:297` | **属实——第一版据此得出"不用改"的结论是错的** |
| `PlannedBlock` 目前只有 `id/taskId/range/locked/explanationCode` | 读 `schedule_problem.dart:94–112` | 属实 |
| `ScheduleProblem` **没有**任何调整上下文 | 搜 `adjustment`／`targetBlockId`／`notBefore` 于 `schedule_problem.dart`：**零命中** | 属实 |
| `existingBlocks` 只喂评分、不进 `blocks` | 全文件搜索仅命中 `_movesExistingBlock` 与文档注释 | 属实 |
| 延后目前写成任务级 `availableFromUtc` | 读 `repository_schedule_problem_source.dart:147–181` | 属实 |
| `localRepairCascade` 生产零调用 | 断言搜索只命中定义与测试文件 | 属实 |
| `maximumUnusableGapPenalty` 任何负数都失败 | 逐值实测 `0`／`-50`／`-100`／`-150`／`-500` | 属实（记录于验收表 §9） |
| `_improve` 跳过 `locked` 的块 | 搜索 `if (block.locked) continue;` | 属实 |
| `withCurrentInputHash` 逐字段重建 `ScheduleProblem` | 本批次已因此丢过一次 `referenceBlocks` | 属实 |
