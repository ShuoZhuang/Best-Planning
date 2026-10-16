# 算法 17：容量感知分层排程修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本计划采用单写者顺序执行；禁止多个代理并行修改同一工作树或同一 Task。

**Goal:** 在不破坏现有算法版本 16 已修复能力的前提下，把排程核心升级为“逐日真实规则 + 全局跨日分配 + 日内放置 + 方案级改进”的分层确定性算法，彻底消除工作日无故拥挤、周末长期闲置、可见空闲被误报为容量不足、局部优化破坏均匀分布以及重排范围失控。

**Architecture:** 排程分成五个有明确契约的阶段：输入归一化、逐日容量账本、跨日预算分配、日内放置、方案级校验与选择。硬约束使用统一判定器，日期选择使用字典序目标而不是权重相加，日内偏好继续由候选评分处理。普通生成、自动重排和块级延后使用不同的方案比较配置，但共享同一套容量、合法性和诊断事实源。

**Tech Stack:** Dart 3、Flutter、Drift/SQLite、现有 `TimeZoneDatabase`、`flutter_test`、现有本地优先架构；不得引入联网服务、随机求解器或新的运行时依赖。

**Document Status:** 可执行方案已冻结，代码实施未开始。

**Baseline / Target:** 产品基线 1.8.0、排程算法 16；本计划只把排程算法候选版本推进到17，不擅自决定下一产品版本号。

**Spec:** `docs/superpowers/specs/2026-10-01-personal-intelligent-scheduling-design.md`

**Related accepted designs and repair baselines:**

- `docs/superpowers/plans/2026-10-08-v1.7.1-recurring-goal-even-distribution-fix.md`
- `docs/superpowers/specs/2026-10-12-stable-block-provenance-design.md`
- `docs/superpowers/plans/2026-10-13-visible-free-time-false-shortage-repair.md`
- `docs/superpowers/plans/2026-10-13-calendar-preview-and-scheduling-integrity-repair.md`
- `docs/testing/v1.7.1-recurring-even-distribution-acceptance.md`
- `docs/testing/v1.8.0-visible-free-time-shortage-acceptance.md`

## Global Constraints

- 本计划只修改排程核心、排程输入装配、计划预览所需的排程解释以及应用前一致性校验；课程资料管理、保护时间管理、通知、托盘、安装器和统计页面不在本计划内。
- 当前生产基线是 `DeterministicScheduleEngine.algorithmVersion == '16'`。实现期间保持 16；只有 Task 13 的全部自动化、黄金样例和 Windows 人工验收通过后，才在同一提交中升为 `'17'`。
- 固定日程、保护时间、睡眠、课程过渡、锁定块、最早开始、截止时间、允许星期、连续任务、片段上下限、休息间隔和每日硬上限仍是硬约束。任何软目标不得突破它们。
- 所有区间统一采用半开语义 `[startUtc, endUtc)`。`A.endUtc == B.startUtc` 不算重叠。
- UTC 时刻只用于存储和区间运算；星期、工作日/周末、每日上限、轮换与日负载全部通过 `TimeZoneDatabase` 换算后的本地日期计算。不得直接对 UTC 时刻读取 `.weekday`。
- 周末没有固定奖励，工作日也没有固定惩罚。日期选择只依据真实容量、最终负载、任务节奏、截止风险和用户明确设置。
- 高、中、低精力在本批次仍是软偏好。没有任何合法依据时，不得把“高精力任务”解释成“只能在高精力时段安排”。
- 相同业务输入、相同本地时区、相同当前时刻、相同算法版本必须产生逐值相同的提案。不得依赖 `Map` 插入顺序、数据库未声明排序、进程随机数或系统区域格式。
- 一次生成只在应用边界捕获一次 `nowUtc`，随后通过 `ScheduleProblem.planningWindow.startUtc` 显式传递。排程、分配、诊断、目标比较和校验器内部禁止调用 `DateTime.now()`。
- 已完成、正在执行、用户锁定以及本次手动钉住的块不得被普通优化移动。延后只针对指定块，不能退化为整个任务的最早开始时间。
- 任何生成、重排、延后、局部修复和方案改进都必须通过同一 `PlanValidator` 以及本计划新增的方案质量校验。
- “有缺口”不等于“可用时间不足”。只有容量证据证明合规容量小于剩余量时，才允许使用容量不足文案。
- 搜索达到预算、内部状态矛盾和硬无解必须使用不同状态，不得统一翻译成“可用时间不足”。
- 预览不得显示裸任务 UUID。标题缺失时显示中性占位文案，并保留内部 ID 仅用于日志关联。
- 应用提案前必须重放输入哈希、算法版本、一次性覆盖和调整要求；过期或非法提案零写入。
- 允许部分应用只放宽“确实装不下的分钟”，不得放宽结构错误、硬约束、未兑现的延后要求或不可解释的排程器失败。块级延后不得让相对调整前基线的新缺口增加；否则整次调整失败并保留原计划。
- 每个任务的已完成、已记录、已锁定、已确认和本次新增分钟只能在各自定义的口径中计算一次。禁止重复扣减或重复生成。
- 生产日志、测试夹具和文档不得写入真实任务标题、真实 UUID、真实数据库路径或截图中的个人信息。
- 不直接编辑 `app_database.g.dart`。如需数据库字段，修改表定义与迁移步骤，再运行现有生成流程。
- 不修改用户当前未提交的 `docs/superpowers/plans/2026-10-15-course-lineage-deletion-and-import-recovery-repair.md`。
- 每个任务遵循红灯、最小实现、绿灯、相关回归、提交的顺序。任何停止条件触发后不得继续堆补丁。
- Task 1 至 Task 13 必须按依赖顺序由一个写入者执行。允许另一个代理做只读审查或运行不写文件的验证，但不得与实现者同时修改 `lib/`、`test/`、生成文件或本计划。每个 Task 的提交和工作区清洁检查完成后，下一 Task 才能开始。

## Review Focus

- **日期边界与逐日规则：** 规划窗口同时覆盖工作日、周末、月末、年末和 DST 切换时，每个本地日必须使用自己的睡眠、保护时间、精力和每日上限。
- **总空闲与任务可排容量：** 日历可见空白、硬约束后空闲、任务合规容量、片段可落地容量必须分开，重叠占用只能扣一次。
- **全局均衡与任务完成：** 低负载日期应被使用，但均衡不得制造额外缺口、违反截止或把一个任务拆成大量无意义片段。
- **增量调整与稳定性：** 普通重排不得因微小评分改善移动大量已确认块；指定延后必须先走局部级联，失败后保留原计划。
- **失败与超时：** 硬无解、软偏好受限、搜索预算耗尽、结构异常、预览过期必须产生不同且可验证的结果。

---

## 1. 当前基线与问题边界

### 1.1 算法版本 16 已有能力，必须保留

以下能力已经在生产代码和测试中存在，不属于“重新实现”范围：

1. 候选按当前剩余量逐轮生成，合法短尾可以落地。
2. `CandidateEligibilityContext` 统一判断块重叠、每日任务上限、每日可移动上限与休息。
3. `TaskPlacementDiagnostics` 在最终块集合上重新生成结构化失败原因。
4. `UnscheduledTask` 已携带主原因和全部原因，不再只有 UUID 与缺口。
5. `continuedFromId` 区分提案块身份和上一版来源身份。
6. `minimizeChangedBlocks` 已接入普通生成路径。
7. `localRepairCascade`、多锚点方案比较和块级延后已有生产调用。
8. `PlanApplicationService` 已按“哈希、阻断冲突、validator、延后兑现、部分授权、落库”的顺序拦截。
9. 预览已有标题解析和“不回退裸 ID”的测试。
10. `EvenDistributionPlan` 已形成按日预算，初次放置和 `_improve` 会检查任务自己的日额度。

实现本计划时，以上任一测试变红都视为回归，不得用更新 golden、放宽断言或删测试解决。

### 1.2 当前仍存在的结构缺口

1. `PlanningRuleResolver.resolveForWindow()` 只把工作日和周末的精力、保护时间合并；睡眠、每日可移动上限和生活配额仍取窗口首日。该方法还被日历视图使用，不能用破坏性改签名的方式直接替换。
2. `EvenDistributionInput` 只知道同一周期实例的已排分钟，不知道该日所有任务的总负载。
3. 当目标不足以让全部日期各获得一个 `minChunk` 时，均分器按“余量降序、日期升序”选前 K 天；容量相同时会长期选择较早日期。
4. 普通任务的日期选择没有独立的日负载目标。候选评分相同后按最早开始时间打破平局，天然向窗口前部聚集。
5. `CandidateScorer` 把截止、优先级、精力、连续性、碎片等相加。一个高分软偏好仍可能覆盖跨日均衡意图。
6. 按日预算在任务放置前静态计算。前面任务改变了容量后，后续任务不会统一重算全局日分配。
7. `_improve()` 逐块接受更高候选分，不比较整份计划的完成度、日负载、稳定性和坏空档。
8. 当前“均匀”主要衡量同一任务分钟，没有明确比较最终总负载。
9. 搜索预算耗尽没有独立提案状态，容易与真正无解混淆。
10. 计划质量没有统一底线，合法但极端拥挤、过度拆分或大范围移动的方案仍可能进入预览。

### 1.3 本计划不承诺的内容

- 不承诺数学意义上的全局最优。带连续片段、截止、每日上限和稳定性成本的排程属于组合优化问题。本计划承诺可复现、可解释、有界搜索和明确质量下界。
- 不新增“仅限高精力时段”用户设置。现有精力字段继续是软偏好；未来若增加硬模式，必须独立设计字段、迁移与界面。
- 不自动改变现有用户的工作日或周末设置。
- 不把所有空白时间填满。休息、准备、课程过渡和计划缓冲都有合法价值。
- 不把算法升级自动应用到旧确认计划。只有用户重新生成、触发明确重排或执行块级调整时才产生版本 17 提案。

## 2. 术语与唯一口径

| 术语 | 严格定义 |
| --- | --- |
| 日硬空闲 `hardFreeMinutes` | 当日本地日窗口扣除固定、保护、睡眠和课程过渡后的区间并集分钟；不扣任何任务块 |
| 视觉空白 `calendarGapMinutes` | 日硬空闲继续扣除当前基线中所有占住时间的任务块后的区间并集分钟 |
| 任务合规容量 `constraintEligibleMinutes` | 视觉空白继续应用最早开始、截止、允许星期、连续/拆分、每日任务上限后的分钟 |
| 可落地容量 `placeableMinutes` | 合规容量继续应用粒度、最短片段、休息和当前块集合后真正可放入的分钟 |
| 日许可容量 `licensedCapacityMinutes` | `min(日硬空闲, 当日可移动上限)`，不得小于 0 |
| 日已用量 `usedMovableMinutes` | 当前基线里当日所有计入可移动上限的任务块分钟，包含锁定/钉住的任务块，不含固定和保护日程 |
| 日剩余容量 `remainingMinutes` | `min(max(0, 视觉空白 - 本轮已分配量), max(0, 日许可容量 - 已用量 - 本轮已分配量))` |
| 日负载率 `utilizationPermille` | `ceil((usedMovableMinutes + allocatedMinutes) * 1000 / licensedCapacityMinutes)`；许可容量为0且分子为0时记0并禁止分配，分子大于0时记1001并产生结构异常，不除零 |
| 任务日预算 | 跨日阶段允许某任务在某本地日新增的分钟上限 |
| 任务节奏偏差 | 某任务实际累计分钟与其节奏目标累计分钟之间的绝对差 |
| 坏空档 | 大于休息阈值、又小于所有仍待排任务最短可用片段的未保护空档 |
| 稳定性成本 | 相对当前确认计划移动的块数、总位移分钟、删除和重建数量 |
| 硬无解 | 即使忽略全部软偏好，硬约束下仍不能完成 |
| 软受限 | 放宽一个或多个软偏好后可以完成 |
| 搜索未决 | 搜索达到预算，尚未证明有解或无解 |
| 结构异常 | 引擎仍存在合法候选却留下缺口，或输出违反内部不变量 |

## 3. 冻结的算法规则

### 3.1 五阶段数据流

```text
RepositoryScheduleProblemSource
  -> 逐日规则与时间归一化
  -> DayCapacityLedger
  -> DayAllocationPlan
  -> IntradayPlacement
  -> PlanObjective / PlanQualityValidator
  -> final diagnostics
  -> ScheduleProposal
  -> stale + validation + transactional apply
```

每一阶段只能消费上一阶段的显式输出。禁止在界面层、诊断层或优化层重新推测容量与约束。

### 3.2 硬约束判定顺序

候选必须依次通过：

1. 任务属于本次规划实例且仍有剩余量。
2. `[startUtc, endUtc)` 位于规划窗口。
3. 不早于当前可执行下界和任务最早开始。
4. 不晚于任务原始截止时间。
5. 本地星期在允许集合内。
6. 不与固定、保护、睡眠、课程过渡、锁定块重叠。
7. 连续任务获得完整连续区间；可拆分任务满足片段上下限，唯一最终短尾除外。
8. 满足任务自己的单日上限。
9. 满足当天自己的可移动总上限。
10. 满足片段间休息和已执行/正在执行冻结规则。

失败原因按本顺序记录全部证据，但最终主原因使用现有 `unscheduledReasonPriority`，不得用“最后一次失败”代替汇总。

### 3.3 字典序方案目标

禁止把所有目标压成一个总分。整份方案按 `ScheduleObjectiveProfile` 比较。

#### 初次生成 `initialGeneration`

1. 硬约束违规数，必须为 0。
2. 结构异常数，必须为 0。
3. 逾期任务未安排分钟。
4. 紧急任务未安排分钟。
5. 高优先级任务未安排分钟。
6. 中优先级任务未安排分钟。
7. 低优先级任务未安排分钟。
8. 最大单日负载率。
9. 所有日期超过目标水位的总量。
10. 周期目标节奏偏差。
11. 不必要片段数。
12. 日内软偏好损失。
13. 坏空档数量。
14. 坏空档总分钟。
15. 确定性签名。

#### 普通重排 `backgroundReplan`

前七项与初次生成相同，随后比较：

8. 被改变的已确认块数（移动、删除、拆分、合并、重建均计入）。
9. 总位移分钟。
10. 删除后重建的块数。
11. 最大单日负载率。
12. 超水位总量。
13. 周期节奏偏差。
14. 片段、偏好和坏空档指标。
15. 确定性签名。

#### 用户指定调整 `explicitAdjustment`

1. 硬约束违规数。
2. 指定调整未兑现数。
3. 相对调整前基线新增的未安排分钟；必须为0，否则该调整方案不可应用。
4. 被改变的非目标已确认块数；移动、删除、拆分、合并和重建都算改变，不能用删除绕过“少移动”。
5. 非目标块总位移分钟；删除的块不在此获得0位移优势，因为已经由第3、4项阻断或计数。
6. 目标块超出要求后的额外位移分钟。
7. 基线本来就存在的各优先级未安排分钟向量。
8. 日负载、节奏、片段、偏好和坏空档。
9. 确定性签名。

任何后一项的改善都不能补偿前一项的恶化。

“目标水位”不能写成隐藏常量。每次比较同一组日期时，先计算：

```text
totalProjected = sum(usedMovableMinutes) + 本轮进入比较的可分配需求分钟
totalLicensed = sum(licensedCapacityMinutes)
targetUtilizationPermille = clamp(ceil(totalProjected * 1000 / totalLicensed), 0, 1000)
totalOverTargetPermille = sum(max(0, utilizationPermille - targetUtilizationPermille))
```

`totalLicensed == 0` 时目标水位为0；任何正需求进入硬无解或预算耗尽分支，禁止除零。比较两个方案时必须使用同一输入推导出的目标水位，不能让每个方案各算一个有利于自己的分母。所有除法使用整数向上取整，不使用浮点数，确保跨平台逐值一致。

### 3.4 跨日分配规则

1. 连续任务和可选日期最少的任务先分配，避免灵活任务抢走稀缺日期。
2. 同等受限时，截止更早、截止压力更高、优先级更高、ID 更小的任务先分配。
3. 日期选择比较“放入后”的最终负载率，不比较原始空闲分钟。
4. 普通任务在截止允许时优先进入较低负载日；截止风险可以优先于均衡。
5. `even` 任务同时最小化任务自身日分钟差异和全局日负载差异。全局负载略优先，避免形式平均导致忙日更忙。
6. 当目标只能覆盖 K 个最小片段时，选择 K 个“放入后目标最优”的日期，禁止按日期取前 K 个。
7. 完全同分使用按周期轮换的稳定键，避免每周永久排除星期日。不得使用 Dart `hashCode` 或随机数。先取 `SHA-256(UTF-8(taskId))` 前8字节作为大端无符号整数 `taskSeed`；再令 `cycleOrdinal = floor(daysBetween(1970-01-05, cycleStartLocalDate) / 7)`、`rotationOffset = (taskSeed + cycleOrdinal) mod 7`、`rotationRank = (localDate.weekday - 1 - rotationOffset) mod 7`。Dart 实现负数取模时必须规范化为 `((value % 7) + 7) % 7`。先按 `rotationRank`、再按本地日期排序。这样相同周期逐值稳定，周期推进时起始星期轮转。
8. 周末空闲、工作日拥挤时，周末自然胜出；周末拥挤时不强行使用周末。
9. 已经确认但未锁定的块进入负载基线，也进入稳定性比较，但不成为硬占用。
10. 一个任务预算落地失败时，必须更新账本并重新分配剩余预算；不得沿用过期静态预算直接报缺口。

### 3.5 日内放置规则

跨日预算确定后，日内候选只在对应日期预算内竞争。比较顺序为：

1. 候选合法。
2. 覆盖当前预算所需的分钟。
3. 复用同一来源块的原位置。
4. 截止和进度压力。
5. 精力匹配。
6. 期望时段。
7. 同任务连续性和类别切换。
8. 片段数量。
9. 坏空档。
10. 开始时刻、任务 ID、候选 ID。

精力和期望时段只在同一日期预算内决定具体位置，不能把另一天的合法容量整体屏蔽。

### 3.6 动态重分配与有界回退

1. 日内放置失败后，将该日期对该任务标记为“本轮不可落地”，记录拒绝证据。
2. 把未落地分钟退回日容量账本。
3. 重新计算该任务剩余日期预算。
4. 如新预算挤占了较低优先级任务，允许在有界范围内撤回后者并重新分配。
5. 最多执行 `maxReallocationPasses = 3` 轮，最多访问 `maxAllocationStates = 10000` 个状态。
6. 达到预算但没有证明无解时返回 `budgetExhausted`，不得返回 `insufficientCapacity`。
7. 始终保留迄今最优的合法部分方案；是否允许应用仍由提案状态和用户授权决定。

### 3.7 缓冲与空档

- 课程过渡继续使用现有硬占用实现。
- 片段间休息继续是硬约束。
- 每天的恢复余量先作为软目标，不从可用容量中硬扣除。目标值为 `min(30, floor(licensedCapacityMinutes * 0.10 / granularity) * granularity)`。
- 截止压力高或无法完成时可以使用恢复余量，但解释中要标记“使用了计划缓冲”。
- 小于休息阈值的间隔归类为自然过渡，不算坏空档。
- 保护时间覆盖的间隔不算坏空档。
- 当前没有任何待排任务或当日已达硬上限时，剩余空档是自由时间，不算坏空档。
- 坏空档只能在方案级比较中生效。`SchedulingWeights.v1.maximumUnusableGapPenalty` 在本计划中继续保持 0。

### 3.8 当前时间、截止和安全余量

- 当日最早候选从 `ceilToGranularity(max(nowUtc, availableFromUtc))` 开始。
- 已经开始、已完成或已进入专注状态的块冻结。
- 用户截止时间始终是硬截止。
- 安全余量只形成软性目标截止，不改变用户原值。没有显式任务风险设置时，本批次默认安全余量为 0，禁止静默提前一天。
- 后续若加入任务风险等级，必须通过独立字段和迁移启用，不得根据标题或领域猜测。

### 3.9 任务依赖与地点切换

- 当前模型没有任务依赖字段。本计划不得伪造依赖关系。
- 现有课程过渡分钟继续作为固定日程的后置占用。
- 普通任务地点切换和自定义准备时间暂不进入本次数据库模型。
- 新架构必须给以后加入 `notBeforeTaskId`、准备和通勤占用保留接口，但本批次不新增未被界面消费的持久字段。

### 3.10 应用、撤销和版本

- 提案保存 `inputHash`、`algorithmVersion`、`planningWindow`、一次性覆盖、调整要求和方案状态。
- 应用前重新装配同一输入并比对哈希。任何任务、课程、保护时间、规则、确认计划或当前调整意图变化都会使旧提案过期。
- `PlanRepository.applyProposal` 必须维持事务边界。任务进度、计划块、计划版本和撤销快照要么全部成功，要么全部不变。
- 算法 17 不主动重写算法 16 的历史确认计划。
- 撤销恢复原始块和原始算法版本，不用新算法重新推导“近似旧计划”。

## 4. 完整需求清单

| ID | 需求 | 类型 | 验收摘要 |
| --- | --- | --- | --- |
| ALG-01 | 所有时间区间使用 `[start, end)` | 硬不变量 | 相邻区间不冲突，重叠一分钟会冲突 |
| ALG-02 | 本地星期只由 IANA 时区换算得出 | 硬不变量 | 清晨、跨午夜和 DST 用例通过 |
| ALG-03 | 规划窗口内每一天使用独立规则 | 硬不变量 | 工作日开窗仍使用周末上限 |
| ALG-04 | 固定、保护、睡眠、课程过渡只扣一次 | 硬不变量 | 重叠占用按并集计算 |
| ALG-05 | 过去时间不进入候选 | 硬不变量 | 当日从向上取整后的当前时刻开始 |
| ALG-06 | 已完成、执行中和锁定块冻结 | 硬不变量 | 全量生成、改进和局部修复均不移动 |
| ALG-07 | 最早开始、截止和允许星期统一判定 | 硬不变量 | 三阶段使用同一事实源 |
| ALG-08 | 连续任务必须完整连续 | 硬不变量 | 不得用多段伪装成功 |
| ALG-09 | 片段上下限和唯一短尾保持版本 16 语义 | 硬不变量 | 100 分钟可排 30+30+30+10 |
| ALG-10 | 每日任务上限与每日总上限都按本地日判定 | 硬不变量 | `_improve` 后仍不超限 |
| ALG-11 | 视觉空白、合规容量、可落地容量分开 | 解释契约 | 预览同时显示三个口径 |
| ALG-12 | 日容量账本是跨日分配唯一来源 | 架构 | 分配器不自行重建空闲 |
| ALG-13 | 日负载率使用许可容量归一化 | 算法 | 不以绝对空闲分钟误判大小日 |
| ALG-14 | 普通任务也考虑跨日负载 | 算法 | 宽松截止下选择低负载日 |
| ALG-15 | 周末无固定奖励或惩罚 | 产品规则 | 只因容量和负载被选择 |
| ALG-16 | 截止风险优先于均衡 | 产品规则 | 临近截止时允许早排 |
| ALG-17 | `even` 同时平衡任务分钟和总负载 | 算法 | 忙日不为形式均匀继续加压 |
| ALG-18 | 参与日不足七天时不按日期取前 K 个 | 算法 | 150/30 不再固定落周一至周五 |
| ALG-19 | 完全同分按周稳定轮换 | 公平性 | 连续周期不会永久排除同一星期 |
| ALG-20 | 日期选择与 Map 插入顺序无关 | 确定性 | 反转输入结果逐值相同 |
| ALG-21 | 受限任务优先占用稀缺日期 | 算法 | 连续/少日期任务不被灵活任务饿死 |
| ALG-22 | 日期预算必须能动态退回和重分 | 算法 | 某日不可落地后改用其他日期 |
| ALG-23 | 最多三轮重分，最多一万状态 | 性能 | 达限返回搜索未决 |
| ALG-24 | 日内评分不能改变跨日预算 | 层级约束 | 高精力、连续性不能重新挤回工作日 |
| ALG-25 | 精力是软偏好 | 产品规则 | 没有高精力时段仍可用合法时间 |
| ALG-26 | 期望时段是软偏好 | 产品规则 | 时段外仍可安排并解释偏离 |
| ALG-27 | 同任务连续性不能覆盖上层目标 | 层级约束 | 不因连续奖励造成单日过载 |
| ALG-28 | 恢复余量是软目标 | 质量 | 能完成时尽量留出，紧急时可使用 |
| ALG-29 | 坏空档只在方案级比较 | 质量 | 候选权重保持 0，局部方案可比较 |
| ALG-30 | 自由时间与坏空档分开 | 质量 | 无待排任务时空白不受罚 |
| ALG-31 | 初次生成、普通重排、指定调整使用不同目标顺序 | 架构 | 三类路径各自测试 |
| ALG-32 | 普通重排设置改动门槛 | 稳定性 | 微小质量改善不移动已确认块 |
| ALG-33 | 延后先局部级联，失败才扩大范围 | 稳定性 | 不直接重排整周 |
| ALG-34 | 延后未完全兑现或制造新缺口时零写入 | 安全 | 部分模式不能绕过 |
| ALG-35 | 来源身份与提案块 ID 分离 | 数据一致性 | 移动显示为移动，不是删加 |
| ALG-36 | 失败原因来自最终计划的真实证据 | 解释契约 | 不使用循环最后一次拒绝 |
| ALG-37 | 容量不足必须有容量证据 | 解释契约 | 空 evidence 不显示该文案 |
| ALG-38 | 硬无解、软受限、搜索未决、结构异常分开 | 解释契约 | 四类状态文案与可应用性不同 |
| ALG-39 | 失败条目显示标题，不显示裸 UUID | 隐私/体验 | 标题缺失使用占位符 |
| ALG-40 | 提供排除分钟分解 | 解释契约 | 固定、保护、截止、星期、片段、上限分别计数 |
| ALG-41 | 部分计划必须明确授权 | 安全 | 默认完整模式拒绝缺口 |
| ALG-42 | 结构异常永远禁止应用 | 安全 | `allowPartial` 不可绕过 |
| ALG-43 | 预览过期零写入 | 并发安全 | 输入变化后返回 stale |
| ALG-44 | 应用必须原子化 | 数据一致性 | 注入中途失败后逐表不变 |
| ALG-45 | 同一输入重复生成逐值相同 | 确定性 | 100 次 JSON 相同 |
| ALG-46 | 算法版本只在全部门槛通过后提升 | 发布 | golden、全量测试、人工验收同批通过 |
| ALG-47 | 搜索有界且保留最佳合法部分方案 | 性能 | 大样本不无限运行 |
| ALG-48 | 旧计划不因升级静默重排 | 兼容 | 打开新版本不自动写计划 |

### 4.1 需求—任务—证据追踪表

下表中的测试是最低证据，不是可选建议。计划内“Create”文件必须先建立红灯；既有文件必须增加所列用例，不能只依赖原测试碰巧覆盖。

| ID | 实施任务 | 最低自动化证据 |
| --- | --- | --- |
| ALG-01 | Task 3、11 | `scheduler_invariants_property_test.dart`：`adjacent half-open intervals do not overlap` |
| ALG-02 | Task 2、11 | `schedule_engine_time_zone_test.dart`：上海跨午夜与纽约 DST 本地日归属 |
| ALG-03 | Task 2 | `planning_rule_resolver_test.dart`：窗口逐日规则完整且不回退首日 |
| ALG-04 | Task 2、3 | `availability_builder_test.dart`：固定、保护、睡眠重叠按并集只扣一次 |
| ALG-05 | Task 1、6 | `capacity_aware_week_planning_test.dart`：当天过去区间不产候选 |
| ALG-06 | Task 7、8 | `schedule_engine_test.dart`：完成、执行中、锁定块在改进后逐值不变 |
| ALG-07 | Task 3、6、9 | `task_capacity_analyzer_test.dart`：最早开始、截止、星期与引擎同判据 |
| ALG-08 | Task 6、7 | `plan_validator_test.dart`：连续任务不得由多块凑足 |
| ALG-09 | Task 6 | `dynamic_short_tail_test.dart` 与 `short_remainder_test.dart`：唯一合法短尾 |
| ALG-10 | Task 3、6、7 | `movable_daily_limit_test.dart`：初排与改进后均不超任务/总日上限 |
| ALG-11 | Task 3、9 | `task_capacity_analyzer_test.dart`、`plan_preview_test.dart`：三类容量分别呈现 |
| ALG-12 | Task 3 | `day_capacity_ledger_test.dart`：分配器和诊断器消费同一快照 |
| ALG-13 | Task 3、5 | `day_allocation_test.dart`：不同许可容量按负载率而非绝对分钟比较 |
| ALG-14 | Task 1、5、6 | `capacity_aware_week_planning_test.dart`：普通任务使用低负载日期 |
| ALG-15 | Task 5 | `day_allocation_test.dart`：交换工作日/周末负载后选择随负载改变 |
| ALG-16 | Task 1、5、6 | `capacity_aware_week_planning_test.dart`：低负载日期晚于截止时不得使用 |
| ALG-17 | Task 5 | `day_allocation_test.dart`：任务等量与全局负载冲突时全局负载略优先 |
| ALG-18 | Task 1、5 | `even_distribution_allocator_test.dart`：150/30 不固定选前五日 |
| ALG-19 | Task 5、11 | `day_allocation_test.dart`：同周期稳定、连续周期轮换 |
| ALG-20 | Task 5、11 | `scheduler_invariants_property_test.dart`：Map 与列表乱序逐值相同 |
| ALG-21 | Task 5 | `day_allocation_test.dart`：少日期连续任务先于全周灵活任务 |
| ALG-22 | Task 6 | `schedule_engine_test.dart`：预算落地失败后释放并改投其他日期 |
| ALG-23 | Task 5、6、11 | `scheduler_performance_budget_test.dart`：三轮/一万状态硬上界 |
| ALG-24 | Task 6、7 | `schedule_engine_test.dart`：日内高分候选不能越过跨日预算 |
| ALG-25 | Task 6、12 | `capacity_aware_week_planning_test.dart`：高精力窗满时使用其他合法时间 |
| ALG-26 | Task 6 | `candidate_scorer_test.dart`：期望时段外候选仍存在且只受软罚 |
| ALG-27 | Task 6、7 | `plan_quality_validator_test.dart`：连续奖励不得恶化日负载上层目标 |
| ALG-28 | Task 3、5、7 | `schedule_objective_test.dart`：紧急完成可覆盖恢复余量，非紧急优先保留 |
| ALG-29 | Task 4、7 | `local_repair_orphan_gap_test.dart`、`unusable_gap_scoring_test.dart` |
| ALG-30 | Task 4、7 | `plan_quality_validator_test.dart`：无待排任务时自由空白不记坏空档 |
| ALG-31 | Task 4、8 | `schedule_objective_test.dart`：三种 profile 的字段顺序互不混用 |
| ALG-32 | Task 8 | `engine_minimizes_changes_test.dart`：微小软收益不足以移动多个确认块 |
| ALG-33 | Task 8 | `defer_end_to_end_test.dart`：延后先局部级联再扩大范围 |
| ALG-34 | Task 8、10 | `defer_unschedulable_test.dart`、`plan_application_service_test.dart`：未兑现或新增缺口零写入 |
| ALG-35 | Task 8 | `block_provenance_matching_test.dart`、`plan_differ_provenance_test.dart` |
| ALG-36 | Task 9 | `infeasible_schedule_test.dart`：最终计划重新诊断且与遍历尾项无关 |
| ALG-37 | Task 9 | `preview_failure_lines_test.dart`：无容量数字时禁止显示容量不足 |
| ALG-38 | Task 9、10 | `infeasible_schedule_test.dart`：五种 `SearchOutcomeKind` 分支逐一覆盖 |
| ALG-39 | Task 9 | `plan_preview_test.dart`：标题缺失用中性占位且页面无裸 UUID |
| ALG-40 | Task 3、9 | `task_capacity_analyzer_test.dart`：各类排除分钟守恒且不重复扣除 |
| ALG-41 | Task 10 | `plan_application_service_test.dart`：只有 hardInfeasible 可经显式授权部分应用 |
| ALG-42 | Task 7、10 | `plan_application_service_test.dart`：invariantViolation 在所有模式零写入 |
| ALG-43 | Task 2、10 | `plan_application_service_test.dart`：逐日规则或占用变化导致 stale 零写入 |
| ALG-44 | Task 10 | `repository_round_trip_test.dart`：注入中途异常后各表逐值不变 |
| ALG-45 | Task 11 | `scheduler_invariants_property_test.dart`：固定种子同输入运行100次 JSON 相同 |
| ALG-46 | Task 12、13 | `algorithm_version_test.dart` 加人工验收记录：门槛前16、同批通过后17 |
| ALG-47 | Task 5、6、11 | `scheduler_performance_budget_test.dart`：达限返回最佳合法方案和 budgetExhausted |
| ALG-48 | Task 10、12 | `plan_generation_flow_test.dart`：仅启动升级版本不调用计划写入仓库 |

## 5. 文件职责

### 5.1 新建文件

| 文件 | 唯一职责 |
| --- | --- |
| `lib/scheduling/daily_scheduling_policy.dart` | 表达某一本地日期完整解析后的规则快照和软恢复余量，避免遗漏睡眠、保护时间、粒度或休息 |
| `lib/scheduling/day_capacity_ledger.dart` | 从唯一 `AvailabilityAnalysis` 和现有块生成逐日许可容量、已用量、剩余量与负载率 |
| `lib/scheduling/day_allocation.dart` | 为全部任务生成日期预算，执行受限优先、负载均衡、节奏与稳定轮换 |
| `lib/scheduling/schedule_objective.dart` | 定义三种方案比较配置及字典序比较，不接触界面文案 |
| `lib/scheduling/plan_quality_validator.dart` | 检查日预算兑现、异常缺口、过度拆分和方案质量底线 |
| `lib/scheduling/search_outcome.dart` | 表达 solved、solvedWithSoftRelaxation、hardInfeasible、budgetExhausted、invariantViolation |
| `test/scheduling/day_capacity_ledger_test.dart` | 容量并集、逐日规则、负载率、零容量边界 |
| `test/scheduling/day_allocation_test.dart` | 普通任务、均匀任务、K 日选择、轮换、截止与动态重分 |
| `test/scheduling/schedule_objective_test.dart` | 三种配置的逐层不可覆盖性 |
| `test/scheduling/plan_quality_validator_test.dart` | 结构异常与质量底线 |
| `test/application/capacity_aware_week_planning_test.dart` | 工作日繁忙、周末空闲的生产装配回归 |
| `test/application/planning_rule_resolver_test.dart` | 逐日解析、兼容入口、日期覆盖和区间边界 |
| `test/application/input_snapshot_builder_test.dart` | 逐日规则哈希、乱序稳定性和字段敏感性 |
| `test/scheduling/local_repair_plan_selection_test.dart` | 局部修复复用方案级目标的比较顺序 |
| `test/scheduling/scheduler_invariants_property_test.dart` | 多种子硬不变量和确定性属性测试 |
| `test/scheduling/scheduler_performance_budget_test.dart` | 状态数、重分轮次和代表性耗时预算 |
| `test/fixtures/scheduling/capacity_aware_week.json` | 固定输入与算法 17 黄金输出 |
| `docs/testing/capacity-aware-scheduler-acceptance.md` | Windows 人工验收记录模板 |

### 5.2 修改文件

| 文件 | 变更 |
| --- | --- |
| `lib/application/planning_rule_resolver.dart` | 保留现有兼容入口，新增供排程使用的逐日解析入口 |
| `lib/application/repository_schedule_problem_source.dart` | 装配每日策略、唯一容量输入和完整哈希 |
| `lib/scheduling/schedule_problem.dart` | 携带不可缺失的每日策略和目标配置 |
| `lib/scheduling/availability_builder.dart` | 按空闲段所属本地日期使用当日粒度，并且只消费装配好的占用事实 |
| `lib/scheduling/candidate_generator.dart` | 按候选所属本地日期使用当日粒度，不读取窗口首日规则 |
| `lib/scheduling/even_distribution_allocator.dart` | 复用新日期比较，不再按余量/日期选前 K 个；保留兼容纯函数 |
| `lib/scheduling/schedule_engine.dart` | 接入跨日预算、日内放置、动态重分与方案级改进 |
| `lib/scheduling/candidate_scorer.dart` | 限定为日内软偏好，不承担跨日负载 |
| `lib/scheduling/candidate_eligibility.dart` | 从每日策略读取当日上限；保持统一硬判定 |
| `lib/scheduling/local_repair.dart` | 使用 `ScheduleObjectiveProfile.explicitAdjustment` 比较局部方案 |
| `lib/scheduling/task_capacity_analyzer.dart` | 消费同一容量账本，不另算口径 |
| `lib/scheduling/task_placement_diagnostics.dart` | 增加搜索未决、逐日容量和排除分钟证据 |
| `lib/scheduling/schedule_proposal.dart` | 增加搜索结果、目标摘要和日容量摘要的内存字段 |
| `lib/scheduling/preview_failure_lines.dart` | 翻译四类失败状态和逐日证据 |
| `lib/application/input_snapshot_builder.dart` | 每日策略和相关设置进入确定性输入哈希 |
| `lib/application/plan_application_service.dart` | 搜索未决和结构异常禁止应用，保留现有检查顺序 |
| `lib/features/planning/plan_preview_page.dart` | 显示可解释容量，不在 UI 重算原因 |
| `test/scheduling/even_distribution_allocator_test.dart` | 补 150/30、繁忙工作日、轮换与总负载场景 |
| `test/application/recurring_even_distribution_test.dart` | 补跨日全局负载和优化后不回退 |
| `test/scheduling/schedule_engine_test.dart` | 补普通任务低负载日期、重分与方案级改进 |
| `test/scheduling/infeasible_schedule_test.dart` | 补硬无解、搜索未决和结构异常区分 |
| `test/application/plan_application_service_test.dart` | 补新状态零写入和 stale |
| `test/features/planning/plan_preview_test.dart` | 补文案、标题、证据与按钮层级 |

### 5.3 不修改文件

- `lib/data/database/app_database.g.dart`
- 课程管理、课表导入、保护时间编辑、通知、托盘和发布安装器文件
- 当前用户未提交的课程修复计划

### 5.4 必改构造调用点清单

新增必填字段会触发编译期迁移。以下清单来自文档冻结时对当前工作树的静态检索；它们属于对应 Task 的允许修改范围，即使没有在该 Task 的主文件表逐行重复。执行 Task 2、6、9 前必须重新运行同一检索；若出现新调用点，先把它补入本文清单再修改。禁止给新字段增加静默默认值来逃避迁移，也禁止无审阅全局替换。

**Task 2，`ScheduleProblem(` 调用点：**

```text
lib/application/planning_service.dart
lib/application/repository_schedule_problem_source.dart
test/app/today_route_test.dart
test/application/calendar_refresh_paths_test.dart
test/application/plan_application_service_test.dart
test/application/planning_service_test.dart
test/application/recurring_even_distribution_test.dart
test/application/recurring_planning_test.dart
test/application/scale_smoke_test.dart
test/application/schedule_reference_blocks_test.dart
test/application/schedule_view_invalidation_test.dart
test/application/short_remainder_matrix_test.dart
test/fixtures/core_workflow_repair_scenarios.dart
test/scheduling/algorithm_version_test.dart
test/scheduling/dynamic_short_tail_test.dart
test/scheduling/engine_block_adjustment_test.dart
test/scheduling/engine_minimizes_changes_test.dart
test/scheduling/granularity_contract_test.dart
test/scheduling/infeasible_schedule_test.dart
test/scheduling/minimize_changed_blocks_test.dart
test/scheduling/movable_daily_limit_test.dart
test/scheduling/plan_validator_test.dart
test/scheduling/preferred_time_window_test.dart
test/scheduling/proposal_disposition_test.dart
test/scheduling/schedule_engine_test.dart
test/scheduling/schedule_engine_time_zone_test.dart
test/scheduling/short_remainder_test.dart
test/scheduling/spec_invariants_regression_test.dart
test/scheduling/task_capacity_analyzer_test.dart
test/scheduling/task_placement_diagnostics_test.dart
test/scheduling/unscheduled_reason_test.dart
```

**Task 2，`AvailabilityInput(` 调用点：**

```text
lib/scheduling/schedule_engine.dart
test/application/visible_free_time_shortage_regression_test.dart
test/scheduling/availability_builder_test.dart
test/scheduling/sleep_occupancy_test.dart
test/scheduling/task_capacity_analyzer_test.dart
test/scheduling/task_placement_diagnostics_test.dart
```

**Task 6，`CandidateGenerator(` 调用点：**

```text
lib/scheduling/schedule_engine.dart
test/application/visible_free_time_shortage_regression_test.dart
test/scheduling/candidate_generator_test.dart
test/scheduling/granularity_contract_test.dart
test/scheduling/short_remainder_test.dart
```

**Task 9，`ScheduleProposal(` 调用点：**

```text
lib/scheduling/schedule_engine.dart
test/app/plan_preview_regression_test.dart
test/app/special_day_route_test.dart
test/app/visible_free_time_preview_test.dart
test/application/calendar_refresh_paths_test.dart
test/application/pending_skips_test.dart
test/application/plan_application_service_test.dart
test/application/plan_generation_flow_test.dart
test/application/plan_generation_safety_test.dart
test/application/recovery_planning_service_test.dart
test/application/replanning_coordinator_test.dart
test/application/schedule_view_invalidation_test.dart
test/application/short_remainder_matrix_test.dart
test/data/plan_block_history_test.dart
test/features/planning/plan_preview_apply_test.dart
test/features/planning/plan_preview_issue_policy_test.dart
test/features/planning/unscheduled_display_test.dart
test/scheduling/preview_failure_lines_test.dart
test/scheduling/proposal_disposition_test.dart
```

迁移规则：测试夹具必须显式构造覆盖窗口的 `dailyPolicies` 和周配额；生产调用点必须从真实解析器取得。`ScheduleProposal` 测试夹具必须显式写出 `searchOutcome`、`dayCapacity` 和 `objective`，不得根据 `unscheduled.isEmpty` 猜默认状态。

## 6. 核心接口

实现时名称和字段按本节执行；如现有类型迫使修改签名，先更新本文档并停在评审门槛，不得在代码中自行发明第二套概念。

```dart
final class DailySchedulingPolicy {
  const DailySchedulingPolicy({
    required this.localDate,
    required this.resolvedRules,
    required this.softReserveTargetMinutes,
  });

  final DateTime localDate;
  final PlanningRules resolvedRules;
  final int softReserveTargetMinutes;
}

typedef DailyPolicyLookup = DailySchedulingPolicy Function(
  DateTime localDate,
);
```

`localDate` 必须归一为 `DateTime(year, month, day)`。构造器拒绝负恢复余量。保存完整的不可变 `PlanningRules` 快照，而不是只抄当前碰巧用到的几个字段；这样睡眠、保护时间、精力、每日上限、休息、粒度、课程过渡和生活配额不会再次出现“首日字段”或“漏传字段”。

兼容规则必须冻结如下：

- 保留现有 `PlanningRuleResolver.resolveForWindow(DateTime, {override}) -> Future<PlanningRules>`，供尚未迁移的日历读取路径使用；本计划不得直接改变它的返回类型。
- 新增 `resolveByDateForWindow(startLocalDate, endLocalDate, {override}) -> Future<Map<DateTime, PlanningRules>>`，仅排程输入装配使用。范围两端均包含，键按本地日期升序、去时分秒，并返回不可修改 Map。
- `ScheduleProblem.rules` 在算法 17 仍保留，作为旧接口兼容快照和任务默认值来源；任何按日期变化的排程判断必须改读 `policyForLocalDate()`，不得再从 `problem.rules` 取窗口首日值。
- `ScheduleProblem` 构造时要求 `dailyPolicies` 非空、键全部归一且按日连续，不允许重复日；`RepositoryScheduleProblemSource` 使用 `TimeZoneDatabase` 证明它精确覆盖规划窗口涉及的日期，不能把这项时区校验伪装成不持有时区数据库的值对象校验。`policyForLocalDate()` 缺失时抛 `StateError`，不得回退首日。
- 装配层按每日规则分别展开睡眠和规则型保护时间，再与持久化保护日程、固定日程和课程过渡一起按区间并集合并。`AvailabilityBuilder` 不再从全局 `problem.rules` 私自展开第二份睡眠。
- 候选起点、空闲尾部、短尾和最终校验使用候选所属本地日的粒度；片段本身不得跨本地午夜。休息和每日可移动上限同样读取该日本地策略。
- 周生活配额按每个块所属本地周分别计算；同一周采用该周周一的已解析 `weeklyLifeQuotaMinutes`。为此逐日解析范围应向前补齐到首个本地周一，但 `dailyPolicies` 对外仍只暴露规划窗口日期；周配额另存为按本地周一起点键控的不可修改 Map。

`ScheduleProblem` 因此新增以下只读成员和访问器：

```dart
final Map<DateTime, DailySchedulingPolicy> dailyPolicies;
final Map<DateTime, int> weeklyLifeQuotaByWeekStart;

DailySchedulingPolicy policyForLocalDate(DateTime localDate);
int lifeQuotaForLocalWeek(DateTime localDate);
```

两个访问器都先把入参归一到本地日期；周访问器再回退到该日期所在周的周一。任何缺键都属于装配不变量破坏并抛 `StateError`，不得返回 `problem.rules` 或默认值。

```dart
final class DayCapacitySnapshot {
  const DayCapacitySnapshot({
    required this.localDate,
    required this.hardFreeMinutes,
    required this.calendarGapMinutes,
    required this.licensedCapacityMinutes,
    required this.usedMovableMinutes,
    required this.allocatedMinutes,
    required this.remainingMinutes,
    required this.utilizationPermille,
  });
}

final class DayCapacityLedger {
  DayCapacitySnapshot forDate(DateTime localDate);
  DayCapacityLedger allocate(DateTime localDate, int minutes);
  DayCapacityLedger release(DateTime localDate, int minutes);
}

DayCapacityLedger buildDayCapacityLedger({
  required ScheduleProblem problem,
  required AvailabilityAnalysis availability,
  required List<PlannedBlock> baselineBlocks,
});
```

账本使用不可变快照。`allocate` 和 `release` 返回新实例，越界时抛 `StateError`，不得静默夹紧。硬空闲、视觉空白和已用量三者必须来自同一份 `AvailabilityAnalysis`：分析对象同时暴露“只扣非任务硬占用”的 `hardFreeSlots` 与“再扣基线任务块”的 `slots`，账本不得自行从原始区间重新求一遍。

```dart
enum ScheduleObjectiveProfile {
  initialGeneration,
  backgroundReplan,
  explicitAdjustment,
}

final class ScheduleObjective {
  const ScheduleObjective({
    required this.hardViolationCount,
    required this.invariantViolationCount,
    required this.unfulfilledAdjustmentCount,
    required this.newShortageMinutesAgainstReference,
    required this.shortageMinutesByPriority,
    required this.maximumDailyUtilizationPermille,
    required this.totalOverTargetPermille,
    required this.pacingDeviationMinutes,
    required this.movedConfirmedBlockCount,
    required this.changedConfirmedBlockCount,
    required this.displacementMinutes,
    required this.recreatedBlockCount,
    required this.fragmentCount,
    required this.softPreferencePenalty,
    required this.orphanGapCount,
    required this.orphanGapMinutes,
    required this.stableSignature,
  });
}

int compareScheduleObjectives(
  ScheduleObjective a,
  ScheduleObjective b,
  ScheduleObjectiveProfile profile,
);
```

比较器返回负数表示 `a` 更优，零表示所有业务维度相同后由稳定签名决定。禁止求和。

```dart
final class DayAllocationInput {
  const DayAllocationInput({
    required this.tasks,
    required this.ledger,
    required this.alreadyPlannedByTask,
    required this.timeZoneId,
    required this.cycleStartByTask,
    required this.granularityMinutes,
    this.maxReallocationPasses = 3,
    this.maxAllocationStates = 10000,
  });
}

final class TaskDayBudget {
  const TaskDayBudget({
    required this.taskId,
    required this.minutesByLocalDate,
    required this.allocatedMinutes,
    required this.shortageMinutes,
  });
}

final class DayAllocationPlan {
  const DayAllocationPlan({
    required this.budgetsByTaskId,
    required this.finalLedger,
    required this.outcome,
    required this.visitedStateCount,
  });
}

DayAllocationPlan allocateTaskDays(DayAllocationInput input);
```

```dart
enum SearchOutcomeKind {
  solved,
  solvedWithSoftRelaxation,
  hardInfeasible,
  budgetExhausted,
  invariantViolation,
}
```

`hardInfeasible` 表示“已经证明完整方案在硬约束下不可行”，但提案仍可携带迄今最优的合法部分块；是否写入由用户的显式部分应用授权决定。`solvedWithSoftRelaxation` 表示全部必需分钟已合法放置，只是使用了偏好时段之外或软恢复余量中的时间。`budgetExhausted` 既不能声称无解，也不能部分应用。

`ScheduleProposal` 增加：

```dart
final SearchOutcomeKind searchOutcome;
final Map<DateTime, DayCapacitySnapshot> dayCapacity;
final ScheduleObjective objective;
```

这些字段只在内存提案和可选诊断导出中存在，本批次不要求数据库迁移。所有 `with*` 方法必须逐值保留。

## 7. 跨日分配伪代码

```text
ledger = buildDayCapacityLedger(problem, availability, baselineBlocks)
tasks = sortByScarcityThenDeadlineThenPriority(problem.tasks)
state = empty allocations + ledger
bestLegal = state

for task in tasks:
  chunks = buildAllocationChunks(task.remainingMinutes)
  for chunk in chunks:
    dates = eligibleLocalDates(task, state.ledger)
    ranked = sort dates by:
      1. hard feasibility
      2. deadline slack bucket
      3. scarce-capacity opportunity cost
      4. projected maximum daily utilization
      5. projected total over-target utilization
      6. task pacing deviation when policy == even
      7. soft reserve consumption
      8. existing placement reuse
      9. stable cycle rotation key
    expand deterministic states for ranked dates and explicit skip
    keep states that are not dominated under initial allocation objective
    trim to maxAllocationStates

intraday = place each task only within its day budgets
if a budget cannot be placed:
  release that budget
  ban the failed task/date/rejection-shape tuple for this pass
  repeat allocation for affected task and lower-ranked tasks
  stop after maxReallocationPasses

evaluate every legal proposal with ScheduleObjective
return the lexicographically best proposal and its SearchOutcomeKind
```

`explicit skip` 必须存在，否则容量不足时搜索只能崩溃或超排。它产生真实 shortage，并由方案目标保证先牺牲较低优先级任务。

## 8. 任务依赖与停止条件

```text
Task 1 基线红灯
  -> Task 2 逐日规则
  -> Task 3 容量账本
  -> Task 4 方案目标
  -> Task 5 跨日分配器
  -> Task 6 引擎日内接线与动态重分
  -> Task 7 方案级改进
  -> Task 8 普通重排与块级延后稳定性
  -> Task 9 诊断与预览
  -> Task 10 应用安全
  -> Task 11 性能、属性测试与确定性
  -> Task 12 全量回归和人工验收
  -> Task 13 算法版本、golden 与交接
```

出现以下任一情况必须停止当前任务，保留红灯和证据，不进入下一任务：

- 需要修改数据库结构或新增用户设置才能满足当前验收。
- 同一约束在两个模块中产生不同结果。
- 为通过测试必须降低固定日程、保护时间、睡眠或锁定块的约束等级。
- 搜索状态在代表性大样本中超过 10000 且没有明确裁剪规则。
- 需要删除或放宽版本 16 的短尾、延后、来源关联、最终诊断测试。
- 新算法产生合法但比版本 16 多缺至少一个粒度分钟的方案，且不能由更高优先级任务解释。
- `PlanApplicationService` 的既有检查顺序需要调整。
- 实现者发现本文两项规则互相冲突。

## 9. 实施任务

### Task 1: 建立版本 16 基线与真实失败红灯

**Files:**

- Create: `test/application/capacity_aware_week_planning_test.dart`
- Modify: `test/scheduling/even_distribution_allocator_test.dart`
- Modify: `test/scheduling/schedule_engine_test.dart`
- Reference only: `test/application/recurring_even_distribution_test.dart`
- Reference only: `test/application/visible_free_time_shortage_regression_test.dart`

**Interfaces:**

- Consumes: 当前 `DeterministicScheduleEngine.generate(ScheduleProblem)`、`allocateEvenDistribution(EvenDistributionInput)`。
- Produces: 后续任务必须转绿的固定失败场景，不生产业务接口。

- [ ] **Step 1: 记录基线命令与算法版本**

Run:

```powershell
git status --short
dart test test/scheduling/even_distribution_allocator_test.dart test/application/recurring_even_distribution_test.dart test/application/visible_free_time_shortage_regression_test.dart
```

Expected: 现有测试全部 PASS；记录 `algorithmVersion == '16'`；把开始前已经存在的工作区差异单独记为 baseline dirty set。当前已知的用户文件 `docs/superpowers/plans/2026-10-15-course-lineage-deletion-and-import-recovery-repair.md` 不得加入本计划任何提交、不得格式化、不得改名。

- [ ] **Step 2: 添加 150 分钟、最小片段 30、七天等容量的失败测试**

测试名：`150/30 不按日期选择周一至周五`。构造七天各 120 分钟容量，工作日已有负载 90，周末已有负载 0。断言周六和周日都参与，且不得只选择前五个日期。

- [ ] **Step 3: 添加普通任务工作日繁忙、周末空闲的端到端失败测试**

固定本地周一至周日窗口。工作日已有可移动任务占用达到许可容量的 75%，周末为 0；新任务截止下周一、允许全部星期、无期望时段。断言至少一个块落到周末，且工作日最大负载不继续恶化。

- [ ] **Step 4: 添加截止覆盖均衡的反向测试**

同一输入把截止改为周五12:00。断言任务不得为了周末低负载越过截止，缺口或工作日放置均可，但必须有结构化证据。

- [ ] **Step 5: 添加工作日开窗、周末不同每日上限的失败测试**

周一至周五上限 180，周末上限 360。断言周末账面容量按 360，而不是复制周一的 180。

- [ ] **Step 6: 运行新增测试并确认只因当前结构缺口失败**

Expected: 新增测试 FAIL；既有版本 16 测试保持 PASS。若既有测试失败，先修测试夹具，不改生产代码。

- [ ] **Step 7: 提交红灯**

```powershell
git add test/application/capacity_aware_week_planning_test.dart test/scheduling/even_distribution_allocator_test.dart test/scheduling/schedule_engine_test.dart
git commit -m "test: expose cross-day scheduling bias"
```

### Task 2: 逐日解析规划规则

**Files:**

- Create: `lib/scheduling/daily_scheduling_policy.dart`
- Modify: `lib/application/planning_rule_resolver.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/scheduling/schedule_problem.dart`
- Modify: `lib/scheduling/availability_builder.dart`
- Modify: `lib/application/input_snapshot_builder.dart`
- Create: `test/application/planning_rule_resolver_test.dart`
- Modify: `test/application/repository_schedule_problem_source_test.dart`
- Create: `test/application/input_snapshot_builder_test.dart`
- Modify: `test/scheduling/availability_builder_test.dart`

**Interfaces:**

- Consumes: `SettingsService.resolveForDate(DateTime)`、`TimeZoneDatabase`、现有 `ScheduleRuleOverride`。
- Produces: `Map<DateTime, DailySchedulingPolicy> ScheduleProblem.dailyPolicies`、`Map<DateTime, int> weeklyLifeQuotaByWeekStart`，供 Task 3、5、6 使用；保留旧 `resolveForWindow` 的源码兼容性。

- [ ] **Step 1: 为 `DailySchedulingPolicy` 写构造和日期归一化红灯**

覆盖负上限拒绝、负恢复余量拒绝、带时间日期归一、本地日期键不可重复。

- [ ] **Step 2: 新增逐日解析入口，不破坏旧 `resolveForWindow`**

签名：

```dart
Future<Map<DateTime, PlanningRules>> resolveByDateForWindow(
  DateTime startLocalDate,
  DateTime endLocalDate, {
  ScheduleRuleOverride? override,
});
```

结果按日期升序插入不可修改 Map。范围两端均包含；一次性覆盖只作用于命中日期。既有 `resolveForWindow(DateTime, {override})` 的签名、返回类型和日历调用测试保持不变。本任务不得把旧调用点靠强制类型转换接到新返回值。

- [ ] **Step 3: 装配每日策略和逐周生活配额**

`RepositoryScheduleProblemSource` 为窗口内每个本地日期构造 `DailySchedulingPolicy`。恢复余量按 §3.7 计算。保护时间和睡眠按当天 `PlanningRules` 展开，课程过渡按事件结束日的规则展开，禁止继续使用首日规则覆盖整周。对窗口涉及的每个本地周，再解析其周一规则并写入 `weeklyLifeQuotaByWeekStart`。

- [ ] **Step 4: 增加 `ScheduleProblem.dailyPolicies` 并使缺日立即失败**

值对象构造时验证非空、日期归一、日期连续且不重复；装配层通过 `TimeZoneDatabase` 枚举规划窗口的预期本地日期，断言 Map 键集合逐值相等且没有窗口外键。`policyForLocalDate()` 未找到日期时抛 `StateError`，不得回退首日。周配额 Map 必须覆盖窗口涉及的每一个本地周一。新增 DST 用例证明不能用 UTC 每24小时递增来枚举本地日期。

- [ ] **Step 5: 移除可用性层的第二份睡眠推导**

`AvailabilityInput` 增加必填 `dailyPolicies`；`AvailabilityBuilder` 只消费装配好的 `fixedIntervals`、`protectedIntervals`、锁定任务块和已计费可移动块，不再从全局 `rules.sleepRange` 展开睡眠。`AvailabilityAnalysis` 同一次扫线产出两组切片：`hardFreeSlots` 只扣固定/保护/睡眠/课程过渡，`slots` 再扣锁定或钉住的任务块；两组都按所属 `localDate` 的粒度对齐。新增回归：同一睡眠既来自逐日规则又与保护时间重叠时，总容量只扣一次；任务锁定块只缩小视觉空白但同时进入已用量；周末睡眠或粒度不同于工作日时，各日按自己的规则处理。

- [ ] **Step 6: 每日策略进入输入哈希**

哈希按日期排序序列化完整 `resolvedRules`、日期与恢复余量，并按周一起点排序序列化生活配额。反转 Map 插入顺序时哈希相同；改变周末上限、睡眠、保护时间、粒度、休息或生活配额时哈希必须变化。

- [ ] **Step 7: 运行定向测试**

```powershell
dart test test/application/planning_rule_resolver_test.dart test/application/repository_schedule_problem_source_test.dart test/application/input_snapshot_builder_test.dart test/scheduling/availability_builder_test.dart
```

Expected: PASS。

- [ ] **Step 8: 运行时间、日历兼容与规则回归**

```powershell
dart test test/core/time_zone_test.dart test/core/local_time_zone_test.dart test/scheduling/schedule_engine_time_zone_test.dart test/domain/schedule_rule_override_test.dart test/application/calendar_refresh_paths_test.dart
flutter analyze
```

Expected: 测试 PASS，静态检查退出码0；§5.4 的全部构造调用点已经显式迁移。

- [ ] **Step 9: 提交**

先用 `git diff --name-only` 与 §5.4 清单核对，再逐个暂存本 Task 实际改动的构造调用点。下面命令中的首个 `git add` 只列主文件；在 `git commit` 前必须使用带明确路径的 `git add -- <path...>` 补齐已核对的调用点。禁止 `git add .` 或 `git add -A`，避免带入 baseline dirty set。

```powershell
git add lib/scheduling/daily_scheduling_policy.dart lib/application/planning_rule_resolver.dart lib/application/repository_schedule_problem_source.dart lib/scheduling/schedule_problem.dart lib/scheduling/availability_builder.dart lib/application/input_snapshot_builder.dart test/application/planning_rule_resolver_test.dart test/application/repository_schedule_problem_source_test.dart test/application/input_snapshot_builder_test.dart test/scheduling/availability_builder_test.dart test/application/calendar_refresh_paths_test.dart
# 此处逐个 git add -- §5.4 中本 Task 已核对的调用点
git commit -m "refactor: resolve scheduling rules per local day"
```

### Task 3: 建立唯一的逐日容量账本

**Files:**

- Create: `lib/scheduling/day_capacity_ledger.dart`
- Create: `test/scheduling/day_capacity_ledger_test.dart`
- Modify: `lib/scheduling/task_capacity_analyzer.dart`
- Modify: `lib/scheduling/candidate_eligibility.dart`
- Modify: `test/scheduling/task_capacity_analyzer_test.dart`
- Modify: `test/scheduling/movable_daily_limit_test.dart`

**Interfaces:**

- Consumes: Task 2 的 `dailyPolicies`、现有 `AvailabilityAnalysis`、`PlannedBlock`。
- Produces: 不可变 `DayCapacityLedger` 和 `DayCapacitySnapshot`，供 Task 5、6、9 使用。

- [ ] **Step 1: 写容量并集、双层空闲和零容量红灯**

覆盖固定与保护重叠30分钟只扣一次、跨午夜分属两个本地日、容量0不除零、工作日和周末不同上限。另建“硬空闲240、锁定任务60、每日上限180”的夹具，断言 `hardFree=240`、`calendarGap=180`、`licensed=180`、`used=60`、`remaining=120`，不得得到60。

- [ ] **Step 2: 写 allocate/release 守恒红灯**

断言：分配后 `remaining` 精确减少；释放后逐值恢复；超额分配、超额释放、负分钟都抛 `StateError`；原账本不变。

- [ ] **Step 3: 实现 `buildDayCapacityLedger`**

`hardFreeMinutes` 只读取 `availability.hardFreeSlots`，`calendarGapMinutes` 只读取 `availability.slots`。`licensedCapacityMinutes = min(hardFreeMinutes, dailyLimit)`；`usedMovableMinutes` 统计基线中所有计入可移动上限的任务块，包括锁定和钉住块，但每个块只统计一次。`remainingMinutes = min(max(0, calendarGap - allocated), max(0, licensed - used - allocated))`。若基线已经使 `used > licensed`，返回结构异常证据，不得把负数夹成0后继续声称输入正常。

- [ ] **Step 4: 让容量分析器消费账本**

`analyzeTaskCapacity` 接收同一账本，删除内部重复计算每日总上限的路径。任务特定截止、星期和片段过滤仍由它负责。

- [ ] **Step 5: 让候选合法性读取候选日期策略**

每日总上限从 `problem.policyForLocalDate(candidate.localDate)` 读取。禁止继续读 `problem.rules.dailyMovableTaskLimitMinutes`。

- [ ] **Step 6: 运行定向测试**

```powershell
dart test test/scheduling/day_capacity_ledger_test.dart test/scheduling/task_capacity_analyzer_test.dart test/scheduling/movable_daily_limit_test.dart
```

Expected: PASS。

- [ ] **Step 7: 提交**

```powershell
git add lib/scheduling/day_capacity_ledger.dart lib/scheduling/task_capacity_analyzer.dart lib/scheduling/candidate_eligibility.dart test/scheduling/day_capacity_ledger_test.dart test/scheduling/task_capacity_analyzer_test.dart test/scheduling/movable_daily_limit_test.dart
git commit -m "feat: add one daily capacity ledger"
```

### Task 4: 实现方案级字典序目标

**Files:**

- Create: `lib/scheduling/schedule_objective.dart`
- Create: `test/scheduling/schedule_objective_test.dart`
- Modify: `lib/scheduling/local_repair.dart`
- Modify: `test/scheduling/local_repair_orphan_gap_test.dart`
- Create: `test/scheduling/local_repair_plan_selection_test.dart`

**Interfaces:**

- Consumes: `ScheduleProblem`、块集合、Task 3 的账本、现有来源关联和 gap classifier。
- Produces: `ScheduleObjective evaluateScheduleObjective(...)` 与 `compareScheduleObjectives(...)`。

- [ ] **Step 1: 为三种 profile 写逐级不可覆盖测试**

每个相邻字段至少一例。示例：方案 A 少1分钟紧急缺口但日负载更差，A 仍胜；重排中 A 少移动一个块但均衡稍差，A 仍胜；指定调整中未兑现目标的方案永远输。

- [ ] **Step 2: 写优先级缺口向量测试**

禁止使用单一加权和。`urgent/high/medium/low` 按顺序比较，同级再比较分钟。

- [ ] **Step 3: 写稳定签名测试**

所有业务字段相同后，只由按块起点、任务ID、块ID排序得到的稳定签名打破平局。Map 顺序不得影响签名。

- [ ] **Step 4: 实现目标求值和比较器**

方案目标只读取显式输入，不读系统时钟、不访问仓库、不写日志。

- [ ] **Step 5: 让局部修复复用 explicitAdjustment profile**

保留现有 `LocalRepairPlan.compare` 对外行为；内部字段映射到统一目标，现有“移动块数优先于坏空档”测试必须继续通过。

- [ ] **Step 6: 运行定向测试**

```powershell
dart test test/scheduling/schedule_objective_test.dart test/scheduling/local_repair_orphan_gap_test.dart test/scheduling/local_repair_plan_selection_test.dart
```

Expected: PASS。

- [ ] **Step 7: 提交**

```powershell
git add lib/scheduling/schedule_objective.dart lib/scheduling/local_repair.dart test/scheduling/schedule_objective_test.dart test/scheduling/local_repair_orphan_gap_test.dart test/scheduling/local_repair_plan_selection_test.dart
git commit -m "feat: compare whole schedules lexicographically"
```

### Task 5: 实现全局跨日预算分配器

**Files:**

- Create: `lib/scheduling/day_allocation.dart`
- Create: `test/scheduling/day_allocation_test.dart`
- Modify: `lib/scheduling/even_distribution_allocator.dart`
- Modify: `test/scheduling/even_distribution_allocator_test.dart`

**Interfaces:**

- Consumes: Task 3 的账本、Task 4 的目标比较、`SchedulableTask`。
- Produces: `DayAllocationPlan allocateTaskDays(DayAllocationInput input)`，供 Task 6 使用。

- [ ] **Step 1: 写任务排序红灯**

连续任务、合法日期更少、截止更早、压力更高、优先级更高、ID 更小依次优先。每一层用成对测试固定。

- [ ] **Step 2: 写普通任务低负载日期红灯**

同截止、同日内偏好的两个日期，放入后负载率35%的日期必须胜过92%的日期。

- [ ] **Step 3: 写均匀任务双重平衡红灯**

同一任务自身分钟完全均匀会让繁忙工作日达到100%，另一方案任务分钟略有差异但总负载最高仅70%；后者必须胜。

- [ ] **Step 4: 写 K 日选择和轮换红灯**

150分钟、最小片段30、七天等原始容量但工作日高负载，必须包含周末。七天所有业务字段完全相同时，两个相邻周期的排除日期不同，同一周期重复运行结果相同。

- [ ] **Step 5: 写容量不足和 skip 红灯**

总容量120、需求180，分配120且缺60；高优先级先完整，低优先级承担缺口。不得超额分配。

- [ ] **Step 6: 写状态预算红灯**

构造大量日期与任务，断言访问状态不超过10000；达到限制返回 `budgetExhausted`，不得声称硬无解。

- [ ] **Step 7: 实现分配器**

按 §7 伪代码实现确定性有界状态扩展。所有分钟变化必须经过不可变账本。不得在分配器里生成具体时刻。

- [ ] **Step 8: 兼容 `allocateEvenDistribution`**

保留现有公共函数与测试。内部日期子集选择改用总负载和轮换键；老调用点未提供基线总负载时使用0，不得破坏现有纯函数案例。

- [ ] **Step 9: 运行定向测试**

```powershell
dart test test/scheduling/day_allocation_test.dart test/scheduling/even_distribution_allocator_test.dart
```

Expected: PASS。

- [ ] **Step 10: 提交**

```powershell
git add lib/scheduling/day_allocation.dart lib/scheduling/even_distribution_allocator.dart test/scheduling/day_allocation_test.dart test/scheduling/even_distribution_allocator_test.dart
git commit -m "feat: allocate task minutes across days globally"
```

### Task 6: 把跨日预算接入日内放置并动态重分

**Files:**

- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `lib/scheduling/candidate_generator.dart`
- Modify: `lib/scheduling/candidate_eligibility.dart`
- Modify: `lib/scheduling/candidate_scorer.dart`
- Modify: `lib/scheduling/plan_validator.dart`
- Modify: `test/scheduling/schedule_engine_test.dart`
- Modify: `test/scheduling/candidate_generator_test.dart`
- Modify: `test/scheduling/plan_validator_test.dart`
- Modify: `test/application/capacity_aware_week_planning_test.dart`
- Modify: `test/application/recurring_even_distribution_test.dart`

**Interfaces:**

- Consumes: Task 5 的 `DayAllocationPlan`。
- Produces: 遵守日预算的初始块集合、放置失败反馈和重新分配后的合法部分方案。

- [ ] **Step 1: 写预算不可被日内评分覆盖的红灯**

把高精力、期望时段和同任务连续性全部放在繁忙工作日；周末负载更低且有预算。断言日内评分不能把周末预算搬回工作日。

- [ ] **Step 2: 写动态重分红灯**

日分配器先给周二30分钟，但日内因连续片段不足无法放置；周六存在合法45分钟空档。断言预算退回并在三轮内改到周六，不报容量不足。

- [ ] **Step 3: 写硬截止反向红灯**

周末低负载但晚于截止。断言不使用周末，并正确报告截止窗口或片段约束。

- [ ] **Step 4: 重构 `generate` 为显式阶段**

在 `schedule_engine.dart` 内建立私有阶段函数：

```dart
DayAllocationPlan _allocateDays(...);
_PlacementPassResult _placeWithinBudgets(...);
_PlacementPassResult _reallocateFailedBudgets(...);
```

每个函数只做一个阶段，不在循环里重建 `AvailabilityAnalysis`。

- [ ] **Step 5: 日内候选只消费当天剩余预算**

`CandidateBudgetPolicy` 的上限来自 `TaskDayBudget.minutesByLocalDate - 已落地分钟`。候选起点步长、短尾粒度、片段校验、休息间隔和每日总上限必须通过 `problem.policyForLocalDate(candidate.localDate).resolvedRules` 读取候选所属本地日规则。片段不得跨本地午夜。第二轮短尾放宽不得放开日期预算、任务日上限或总日上限。

`CandidateGenerator.generate` 增加必填 `DailyPolicyLookup policyForDate`；不得提供读取窗口首日规则的默认回退。对每个 `AvailabilitySlot` 先取该日粒度，再计算最早起点、候选时长和迭代步长。`PlanValidator`、`TaskPlacementDiagnostics` 和短尾共同函数必须使用同一日粒度。生活类任务的周目标改读 `problem.lifeQuotaForLocalWeek(blockLocalDate)`，不得继续读 `problem.rules.weeklyLifeQuotaMinutes`。

- [ ] **Step 6: 分离跨日与日内评分**

`CandidateScorer` 保留截止、精力、期望、连续性、类别切换、碎片和移动成本，但候选集合已经被日期预算限制。不得新增“周末奖励”权重。

- [ ] **Step 7: 实现最多三轮的失败反馈**

失败键至少包含 `taskId + localDate + primary rejection code + required chunk minutes`。同一轮不得再次选择完全相同的失败形状。

- [ ] **Step 8: 清除所有日期敏感字段的首日读取**

Run:

```powershell
$hits = rg -n 'problem\.rules\.(dailyMovableTaskLimitMinutes|energyWindows|breakMinutes|granularityMinutes|weeklyLifeQuotaMinutes|sleepRange|protectedTimes|courseTransitionMinutes)' lib/scheduling
if ($LASTEXITCODE -eq 0) { $hits; throw '仍存在日期敏感的首日规则读取' }
if ($LASTEXITCODE -gt 1) { throw 'rg 执行失败' }
```

Expected: 无输出。命中项必须改读 `policyForLocalDate`、`lifeQuotaForLocalWeek` 或装配好的区间；不得加忽略注释或正则例外。`defaultFocusMinutes`、任务创建时已经固化到 `SchedulableTask` 的片段上下限不属于候选日期判断。

- [ ] **Step 9: 运行定向测试**

```powershell
dart test test/scheduling/schedule_engine_test.dart test/application/capacity_aware_week_planning_test.dart test/application/recurring_even_distribution_test.dart
```

Expected: PASS。

- [ ] **Step 10: 运行版本 16 回归**

```powershell
dart test test/scheduling/candidate_generator_test.dart test/scheduling/candidate_scorer_test.dart test/scheduling/dynamic_short_tail_test.dart test/scheduling/short_remainder_test.dart test/scheduling/plan_validator_test.dart test/scheduling/movable_daily_limit_test.dart
flutter analyze
```

Expected: 测试 PASS，静态检查退出码0；§5.4 的候选生成器调用点无遗漏。

- [ ] **Step 11: 提交**

提交前按 Task 2 相同规则核对并逐个暂存 §5.4 的候选生成器调用点。

```powershell
git add lib/scheduling/schedule_engine.dart lib/scheduling/candidate_generator.dart lib/scheduling/candidate_eligibility.dart lib/scheduling/candidate_scorer.dart lib/scheduling/plan_validator.dart test/scheduling/schedule_engine_test.dart test/scheduling/candidate_generator_test.dart test/scheduling/plan_validator_test.dart test/application/capacity_aware_week_planning_test.dart test/application/recurring_even_distribution_test.dart
# 此处逐个 git add -- §5.4 中本 Task 已核对的调用点
git commit -m "refactor: separate day allocation from intraday placement"
```

### Task 7: 用方案级目标约束改进阶段

**Files:**

- Create: `lib/scheduling/plan_quality_validator.dart`
- Create: `test/scheduling/plan_quality_validator_test.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `test/scheduling/schedule_engine_test.dart`
- Modify: `test/application/recurring_even_distribution_test.dart`

**Interfaces:**

- Consumes: Task 4 的目标、Task 5 的日预算、Task 6 的初始方案。
- Produces: `_improve` 只能接受不恶化上层目标的完整方案。

- [ ] **Step 1: 写“局部高分但整案更差”的红灯**

候选精力分更高，但会把工作日负载从70%推到100%，周末仍为20%。断言拒绝该替换。

- [ ] **Step 2: 写均匀预算优化后保持红灯**

初始 `[30,30,30,30,30]`，优化候选能形成 `[60,30,30,30,0]`。断言优化后仍满足原预算和节奏偏差不增。

- [ ] **Step 3: 写计划质量结构异常红灯**

当诊断表明仍有合法候选却留下缺口，返回 invariant violation；当块集合超日预算、重复块ID或任务分钟超发时同样阻断。

- [ ] **Step 4: 实现 `PlanQualityValidator`**

至少检查：唯一块ID、任务分钟守恒、日预算、每日硬上限、仍有合法候选的异常缺口、搜索结果与缺口一致。

- [ ] **Step 5: 改造 `_improve`**

每次替换先构造完整 trial，计算 profile 对应的 `ScheduleObjective`。只有 trial 更优且 `PlanValidator`、`PlanQualityValidator` 都通过时才接受。

- [ ] **Step 6: 坏空档继续在方案级比较**

不得启用候选级 `maximumUnusableGapPenalty`。现有“任何负数都会破坏休息”的回归必须继续通过。

- [ ] **Step 7: 运行定向测试**

```powershell
dart test test/scheduling/plan_quality_validator_test.dart test/scheduling/schedule_engine_test.dart test/application/recurring_even_distribution_test.dart test/scheduling/unusable_gap_scoring_test.dart
```

Expected: PASS。

- [ ] **Step 8: 提交**

```powershell
git add lib/scheduling/plan_quality_validator.dart lib/scheduling/schedule_engine.dart test/scheduling/plan_quality_validator_test.dart test/scheduling/schedule_engine_test.dart test/application/recurring_even_distribution_test.dart
git commit -m "fix: gate local improvement by whole-plan quality"
```

### Task 8: 固化普通重排与块级延后的稳定性

**Files:**

- Modify: `lib/scheduling/local_repair.dart`
- Modify: `lib/application/repository_schedule_problem_source.dart`
- Modify: `lib/scheduling/schedule_engine.dart`
- Modify: `test/application/defer_end_to_end_test.dart`
- Modify: `test/application/defer_day_scope_test.dart`
- Modify: `test/application/defer_unschedulable_test.dart`
- Modify: `test/scheduling/engine_minimizes_changes_test.dart`

**Interfaces:**

- Consumes: Task 4 的 `backgroundReplan` 和 `explicitAdjustment` profile。
- Produces: 符合稳定性门槛的重排和局部延后结果。

- [ ] **Step 1: 写普通重排防抖红灯**

新方案只改善一个5分钟软偏好，但移动两个已确认块。断言保留旧位置。新方案减少紧急任务缺口时，允许移动。

- [ ] **Step 2: 写延后优先局部级联红灯**

目标块延后10分钟只需推动下一块10分钟。断言不移动当天更后面的无关块，也不移动其他日期。另建“删除下一块即可少一次位移”的诱导方案，断言删除、拆分或重建同样计入 changed block，且任何相对基线新增缺口都使方案不可应用。

- [ ] **Step 3: 写局部无解回退红灯**

固定日程堵住级联。断言原计划保留、目标延后未兑现、提案不可应用；不得留下目标块原位并声称成功。

- [ ] **Step 4: 把方案 profile 显式传入引擎**

普通生成无确认基线时使用 `initialGeneration`；存在确认计划且无 adjustment 时使用 `backgroundReplan`；有块级 adjustment 时使用 `explicitAdjustment`。

- [ ] **Step 5: 保持来源身份完整**

所有新建、移动、复用块按现有 `continuedFromId` 契约关联。不得复用持久化块ID作为新提案ID。

- [ ] **Step 6: 运行延后和稳定性回归**

```powershell
dart test test/application/defer_end_to_end_test.dart test/application/defer_day_scope_test.dart test/application/defer_unschedulable_test.dart test/scheduling/engine_minimizes_changes_test.dart test/scheduling/minimize_changed_blocks_test.dart test/scheduling/local_repair_cascade_test.dart
```

Expected: PASS。

- [ ] **Step 7: 提交**

```powershell
git add lib/scheduling/local_repair.dart lib/application/repository_schedule_problem_source.dart lib/scheduling/schedule_engine.dart test/application/defer_end_to_end_test.dart test/application/defer_day_scope_test.dart test/application/defer_unschedulable_test.dart test/scheduling/engine_minimizes_changes_test.dart
git commit -m "fix: preserve plans unless replanning has material benefit"
```

### Task 9: 形成完整失败分类与可解释容量

**Files:**

- Create: `lib/scheduling/search_outcome.dart`
- Modify: `lib/scheduling/task_placement_diagnostics.dart`
- Modify: `lib/scheduling/schedule_proposal.dart`
- Modify: `lib/scheduling/preview_failure_lines.dart`
- Modify: `lib/features/planning/plan_preview_page.dart`
- Modify: `test/scheduling/infeasible_schedule_test.dart`
- Modify: `test/scheduling/preview_failure_lines_test.dart`
- Modify: `test/features/planning/plan_preview_test.dart`

**Interfaces:**

- Consumes: Task 3 的容量摘要、Task 5 的搜索结果、最终块集合。
- Produces: 四类失败状态、逐任务排除证据和用户可读恢复建议。

- [ ] **Step 1: 写四类状态红灯**

分别构造 hardInfeasible、偏好外仍可排、budgetExhausted、invariantViolation。断言 code、是否允许部分应用、文案互不相同。

- [ ] **Step 2: 写排除分钟守恒红灯**

固定、保护、截止、星期、片段和每日上限按区间并集或明确漏斗计算，不能把同一分钟重复归入多个“总计”。明细可重叠，但汇总必须说明是漏斗还是多标签。

- [ ] **Step 3: 扩展 `TaskPlacementDiagnostics`**

增加逐日 `calendarGapMinutes`、`constraintEligibleMinutes`、`placeableMinutes`、`dailyLimitRemaining` 和搜索状态。所有值来自已有账本与候选拒绝记录。

- [ ] **Step 4: 扩展 `ScheduleProposal` 并修复全部 `with*`**

新增字段必须在 `withRuleOverride`、`withAdjustmentRequirement`、`withLinkedBlocks` 中逐值保留。测试对每个字段建立 round-trip 断言。

- [ ] **Step 5: 更新预览文案**

用户至少看到：任务标题、还缺分钟、日历空闲、合规容量、可落地容量、主原因、可选恢复动作。内部结构异常只显示中性错误与重新生成/导出诊断入口，不暴露堆栈或 UUID。

- [ ] **Step 6: 运行定向测试**

```powershell
dart test test/scheduling/infeasible_schedule_test.dart test/scheduling/preview_failure_lines_test.dart test/features/planning/plan_preview_test.dart test/scheduling/proposal_disposition_test.dart
flutter analyze
```

Expected: 测试 PASS，静态检查退出码0；§5.4 的提案构造调用点无遗漏。

- [ ] **Step 7: 提交**

提交前按 Task 2 相同规则核对并逐个暂存 §5.4 的提案构造调用点。

```powershell
git add lib/scheduling/search_outcome.dart lib/scheduling/task_placement_diagnostics.dart lib/scheduling/schedule_proposal.dart lib/scheduling/preview_failure_lines.dart lib/features/planning/plan_preview_page.dart test/scheduling/infeasible_schedule_test.dart test/scheduling/preview_failure_lines_test.dart test/features/planning/plan_preview_test.dart
# 此处逐个 git add -- §5.4 中本 Task 已核对的调用点
git commit -m "feat: explain scheduling capacity and search outcomes"
```

### Task 10: 加固过期预览、部分应用和事务边界

**Files:**

- Modify: `lib/application/input_snapshot_builder.dart`
- Modify: `lib/application/plan_application_service.dart`
- Modify: `lib/data/repositories/drift_plan_repository.dart`
- Modify: `test/application/plan_application_service_test.dart`
- Modify: `test/application/plan_generation_flow_test.dart`
- Modify: `test/data/repository_round_trip_test.dart`
- Modify: `test/application/plan_undo_service_test.dart`

**Interfaces:**

- Consumes: Task 9 的 `searchOutcome`、现有 `inputHash` 与 `PlanApplyMode`。
- Produces: 所有失败路径零写入，成功路径一次事务落地并可精确撤销。

- [ ] **Step 1: 写搜索未决和结构异常不可应用红灯**

`budgetExhausted` 与 `invariantViolation` 在 complete/partial 两种模式都返回 invalid，仓库调用次数为0。

- [ ] **Step 2: 写每日策略变化导致 stale 红灯**

预览生成后只修改周末每日上限或精力窗口。断言旧提案 stale 且零写入。

- [ ] **Step 3: 写升级后不静默重排红灯**

仅把已确认计划的算法版本设为16、当前引擎版本设为17并启动或刷新应用，不触发用户生成、明确重排或调整。断言没有创建新计划版本、没有删除或移动块、计划仓库写调用为0。

- [ ] **Step 4: 写事务注入失败红灯**

在删除旧块后、新块写入前注入异常。断言计划版本、旧块、新块、任务剩余量和撤销快照逐表不变。

- [ ] **Step 5: 保持现有应用检查顺序**

在 proposal conflicts 后、validator 前后不得随意插入放行。新状态检查放在 stale 之后、validator 和 partial 授权之前。

- [ ] **Step 6: 验证撤销恢复原版本**

应用算法17提案后撤销，恢复算法16计划快照和原块ID；不得重新调用算法17生成替代计划。

- [ ] **Step 7: 运行定向测试**

```powershell
dart test test/application/plan_application_service_test.dart test/application/plan_generation_flow_test.dart test/data/repository_round_trip_test.dart test/application/plan_undo_service_test.dart
```

Expected: PASS。

- [ ] **Step 8: 提交**

```powershell
git add lib/application/input_snapshot_builder.dart lib/application/plan_application_service.dart lib/data/repositories/drift_plan_repository.dart test/application/plan_application_service_test.dart test/application/plan_generation_flow_test.dart test/data/repository_round_trip_test.dart test/application/plan_undo_service_test.dart
git commit -m "fix: block stale and unresolved schedule proposals"
```

### Task 11: 确定性、属性测试和性能预算

**Files:**

- Create: `test/scheduling/scheduler_invariants_property_test.dart`
- Create: `test/scheduling/scheduler_performance_budget_test.dart`
- Modify: `test/scheduling/infeasible_schedule_test.dart`
- Modify: `test/scheduling/schedule_engine_time_zone_test.dart`

**Interfaces:**

- Consumes: 完整算法17候选实现。
- Produces: 不变量、确定性和搜索上界证据。

- [ ] **Step 1: 写固定种子的输入生成器**

生成任务、固定日程、保护时间、每日规则、截止和拆分方式。种子固定在测试源码中，失败时打印种子和最小化输入，不打印真实用户数据。

- [ ] **Step 2: 对每份随机输入检查不变量**

至少检查：无重叠、硬区间不占用、截止、星期、片段、每日两类上限、任务分钟不超发、块ID唯一、来源ID合法、提案状态与缺口一致。

- [ ] **Step 3: 写100次逐值确定性测试**

同一输入重复100次，规范化后的 proposal JSON、日预算、目标向量、诊断和稳定签名完全相同。

- [ ] **Step 4: 写Map和输入列表乱序测试**

打乱任务、固定日程、每日策略、确认块的输入顺序，输出仍相同。若业务明确以任务创建顺序为语义，必须把该顺序显式字段化，而不是依赖列表位置。

- [ ] **Step 5: 写时区矩阵**

覆盖 Asia/Shanghai 清晨与跨午夜、America/New_York 春秋 DST、月末、年末。逐日总分钟按本地日归属正确。

- [ ] **Step 6: 写代表性性能门槛**

固定夹具：7天、80个任务、70个固定/保护区间、150个确认块。断言访问状态不超过10000、重分轮次不超过3。墙钟时间只记录不设跨机器硬毫秒阈值；CI 用状态预算保证有界。

- [ ] **Step 7: 运行定向测试**

```powershell
dart test test/scheduling/scheduler_invariants_property_test.dart test/scheduling/scheduler_performance_budget_test.dart test/scheduling/infeasible_schedule_test.dart test/scheduling/schedule_engine_time_zone_test.dart
```

Expected: PASS。

- [ ] **Step 8: 提交**

```powershell
git add test/scheduling/scheduler_invariants_property_test.dart test/scheduling/scheduler_performance_budget_test.dart test/scheduling/infeasible_schedule_test.dart test/scheduling/schedule_engine_time_zone_test.dart
git commit -m "test: enforce scheduler invariants and search bounds"
```

### Task 12: 全量回归与 Windows 人工验收

**Files:**

- Create: `docs/testing/capacity-aware-scheduler-acceptance.md`
- Modify only if failures prove a scoped defect: files owned by Task 2 through Task 10

**Interfaces:**

- Consumes: 完整候选实现。
- Produces: 自动化和人工验收证据；不改变算法版本。

- [ ] **Step 1: 格式与静态检查**

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
```

Expected: 两条命令退出码0。

- [ ] **Step 2: 运行全部单元与组件测试**

```powershell
flutter test
```

Expected: 全部 PASS；不得用更新无关 golden 解决失败。

- [ ] **Step 3: 运行集成测试**

```powershell
flutter test integration_test
```

Expected: 全部 PASS。若环境不支持 Windows 集成测试，在验收文档写明命令、环境错误和未执行状态，不得写“通过”。

- [ ] **Step 4: 人工场景 A，工作日繁忙、周末空闲**

建立周一至周五课程和任务负载，周六周日保留大段空闲；创建截止在下周一的可拆分普通任务和均匀周期目标。预期：两者都会使用低负载周末，且不会仅因“周末”二字获得优先。

- [ ] **Step 5: 人工场景 B，截止覆盖均衡**

把相同任务截止改为周五中午。预期：不越过截止；若容量不足，显示截止前合规容量与缺口，不显示笼统错误。

- [ ] **Step 6: 人工场景 C，高精力只是偏好**

让高精力窗口全部被课程占用，其他时段空闲。预期：任务使用其他合法时段，解释“偏离精力偏好”，不报告容量不足。

- [ ] **Step 7: 人工场景 D，延后10分钟**

延后当天一个块10分钟。预期：先局部推动，预览逐项列出移动；若固定日程阻断，原计划保留且不能应用失败结果。

- [ ] **Step 8: 人工场景 E，预览过期**

生成预览后修改周末上限或新增保护时间。预期：确认时提示重新生成，数据库计划不变。

- [ ] **Step 9: 人工场景 F，搜索预算耗尽诊断**

使用测试入口或诊断构建把状态预算降到极小值。预期：显示“未能确认完整方案”，不显示“可用时间不足”，应用按钮禁用。

- [ ] **Step 10: 在验收文档逐项记录证据**

每项记录构建提交、算法版本、输入摘要、预期、实际、截图路径和通过/失败。截图不得进入包含真实个人数据的公开仓库。

- [ ] **Step 11: 提交验收文档**

```powershell
git add docs/testing/capacity-aware-scheduler-acceptance.md
git commit -m "docs: record capacity-aware scheduler acceptance"
```

### Task 13: 提升算法版本并冻结黄金结果

**Files:**

- Modify: `lib/scheduling/schedule_engine.dart`
- Create: `test/fixtures/scheduling/capacity_aware_week.json`
- Modify: `test/fixtures/scheduling/golden_week.json`
- Modify: `test/scheduling/schedule_engine_test.dart`
- Modify: `test/scheduling/algorithm_version_test.dart`
- Modify: `docs/testing/capacity-aware-scheduler-acceptance.md`

**Interfaces:**

- Consumes: Task 12 全绿证据。
- Produces: `algorithmVersion == '17'`、经逐项审阅的黄金输出和最终交接。

- [ ] **Step 1: 审阅黄金差异，不先覆盖文件**

生成新旧规范化 JSON diff。逐个块解释变化属于逐日规则、跨日负载、动态重分或方案目标。无法解释的变化视为缺陷，返回对应任务修复。

- [ ] **Step 2: 提升算法版本到17**

只修改 `DeterministicScheduleEngine.algorithmVersion`。同步更新测试预期，不修改产品版本号。

- [ ] **Step 3: 写入两份黄金夹具**

`golden_week.json` 保留原场景并记录经审阅的新结果；`capacity_aware_week.json` 固定工作日繁忙、周末空闲、150/30均匀任务、普通任务和一个真实容量缺口。

- [ ] **Step 4: 再跑完整验证**

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Expected: 全部退出码0。

- [ ] **Step 5: 检查工作区差异**

```powershell
git status --short
git diff --check
git diff --stat
```

Expected: 除 Task 1 记录的 baseline dirty set 外，只出现本计划列出的文件；baseline 文件的状态和内容哈希与开始前相同；`git diff --check` 无输出。不得为了得到“干净状态”删除、暂存或提交用户原有文件。

- [ ] **Step 6: 提交算法版本**

```powershell
git add lib/scheduling/schedule_engine.dart test/fixtures/scheduling/golden_week.json test/fixtures/scheduling/capacity_aware_week.json test/scheduling/schedule_engine_test.dart test/scheduling/algorithm_version_test.dart docs/testing/capacity-aware-scheduler-acceptance.md
git commit -m "feat: release scheduler algorithm 17"
```

- [ ] **Step 7: 填写交接摘要**

记录提交范围、测试命令、测试数量、人工验收、已知限制、算法版本和未改动的产品版本。未执行的验证必须明确写“未执行”。

## 10. 自动化验收矩阵

| 场景 | 关键输入 | 必须结果 | 所属任务 |
| --- | --- | --- | --- |
| 相邻区间 | 09:00至10:00、10:00至11:00 | 不冲突 | 3、11 |
| 重叠占用 | 固定与保护重叠30分钟 | 容量只扣一次 | 3 |
| 工作日/周末规则 | 周一开窗，周末上限更高 | 周末用自己的上限 | 2、3 |
| 150/30七天 | 工作日忙、周末空 | 周末参与，不固定前五日 | 1、5 |
| 完全同分 | 七天业务字段相同 | 同周期稳定、跨周期轮换 | 5、11 |
| 普通任务 | 截止宽松 | 低负载日优先 | 5、6 |
| 临近截止 | 周末晚于截止 | 不使用周末 | 1、6 |
| 均匀目标 | 任务等量与总负载冲突 | 总负载略优先 | 5 |
| 高精力任务 | 高精力窗口满，其他时段空 | 使用其他合法时段 | 6、12 |
| 日预算落地失败 | 周二预算无连续空档，周六可放 | 动态转到周六 | 6 |
| 优化回退 | 工作日候选软分高 | 不破坏跨日预算 | 7 |
| 普通重排 | 微小偏好改善、需移动2块 | 保留旧计划 | 8 |
| 明确延后 | 延后10分钟可局部推动 | 只移动必要块 | 8 |
| 延后无解 | 固定日程堵死 | 原计划保留，零写入 | 8、10 |
| 硬无解 | 总合法容量不足 | 精确缺口和证据 | 9 |
| 搜索未决 | 状态预算极小 | 非容量文案、不可应用 | 9、10 |
| 结构异常 | 仍有合法候选却有缺口 | invariant violation | 7、9、10 |
| 预览过期 | 生成后修改每日规则 | stale、零写入 | 10 |
| 应用中断 | 写入中途异常 | 全部回滚 | 10 |
| 决定性 | 同一输入100次 | JSON逐值相同 | 11 |
| 输入乱序 | Map和列表顺序改变 | 输出不变 | 11 |
| DST | 本地日期跨切换 | 分日和分钟正确 | 2、11 |
| 旧计划 | 升级后只打开应用 | 不自动重排 | 10、12 |

## 11. 禁止的捷径

- 不允许给周末加固定分数来掩盖跨日负载缺失。
- 不允许继续用最早开始时间作为所有同分日期的最终规则。
- 不允许把精力、期望时段或同任务连续性升级成未声明的硬约束。
- 不允许为了让计划看起来平均，把任务拆到低于最小片段或增加无意义片段。
- 不允许在 `CandidateScorer` 中加入一个足够大的负载权重代替字典序目标。
- 不允许重新启用候选级坏空档负权重；现有实测已证明任何负数都会破坏休息。
- 不允许按规划窗口首日的规则代表整个七天。
- 不允许让容量分析器、诊断器和引擎各自重算一份空闲时间。
- 不允许在预算无法落地时直接报告容量不足，必须先执行动态退回和重分。
- 不允许搜索超时伪装成无解。
- 不允许只保存最后一次候选拒绝作为任务主原因。
- 不允许把裸 UUID 当标题兜底。
- 不允许部分应用绕过结构异常、延后未兑现或 stale。
- 不允许把已确认计划全部塞进 lockedBlocks 来换取稳定性。
- 不允许通过删除 `continuedFromId`、本地修复或诊断测试简化实现。
- 不允许无审阅更新 `golden_week.json`。
- 不允许先提升算法版本再补测试。
- 不允许声称未执行的集成测试或 Windows 人工验收已经通过。

## 12. 完成定义

只有同时满足以下条件，算法修复才能标记为完成：

- [ ] ALG-01 至 ALG-48 均能指向自动化测试或明确人工验收证据。
- [ ] 工作日繁忙、周末空闲的普通任务和均匀周期目标都按真实负载使用周末。
- [ ] 截止迫近时均衡让位于完成度与截止风险。
- [ ] 150分钟、最小片段30分钟、七天窗口不再固定选择周一至周五。
- [ ] 完全同分时同一周期结果稳定，连续周期不会永久排除同一星期。
- [ ] 高精力和期望时段保持软偏好。
- [ ] 逐日睡眠、保护、精力和每日上限按本地日期解析。
- [ ] 动态重分可利用其他日期的合法容量。
- [ ] `_improve` 不再接受整案目标更差的单块高分替换。
- [ ] 普通重排不会为微小收益大范围移动既有块。
- [ ] 块级延后优先局部级联，无解时原计划不变。
- [ ] 硬无解、软受限、搜索未决和结构异常有不同状态和文案。
- [ ] 预览显示标题、真实缺口、三类容量和结构化排除原因。
- [ ] stale、结构异常、搜索未决和延后未兑现全部零写入。
- [ ] 事务失败后计划、任务进度、版本和撤销快照逐表不变。
- [ ] 同一输入100次输出逐值相同，输入容器乱序不改变结果。
- [ ] Asia/Shanghai、DST、月末、年末测试通过。
- [ ] `dart format --output=none --set-exit-if-changed lib test` 退出码0。
- [ ] `flutter analyze` 退出码0。
- [ ] `flutter test` 全部通过。
- [ ] 可执行的集成测试全部通过；不可执行项明确记录环境阻塞。
- [ ] 六个人工场景均有实际证据。
- [ ] 黄金差异逐项审阅后，算法版本从16提升到17。
- [ ] 产品版本号、课程模块、通知、托盘、安装器和用户未提交文档没有被顺手修改。

## 13. 实施状态表

| Task | 状态 | 提交 | 自动化证据 | 人工证据 | 阻塞 |
| --- | --- | --- | --- | --- | --- |
| 1 基线红灯 | 未开始 |  |  | 不适用 |  |
| 2 逐日规则 | 未开始 |  |  | 不适用 |  |
| 3 容量账本 | 未开始 |  |  | 不适用 |  |
| 4 方案目标 | 未开始 |  |  | 不适用 |  |
| 5 跨日分配 | 未开始 |  |  | 不适用 |  |
| 6 日内接线与重分 | 未开始 |  |  | 不适用 |  |
| 7 方案级改进 | 未开始 |  |  | 不适用 |  |
| 8 重排与延后稳定性 | 未开始 |  |  | 不适用 |  |
| 9 诊断与预览 | 未开始 |  |  | 不适用 |  |
| 10 应用安全 | 未开始 |  |  | 不适用 |  |
| 11 属性与性能 | 未开始 |  |  | 不适用 |  |
| 12 全量与人工验收 | 未开始 |  |  |  |  |
| 13 版本与黄金结果 | 未开始 |  |  |  |  |

## 14. 执行交接模板

```markdown
# Capacity-Aware Hierarchical Scheduler Repair Handoff

## Scope
- Implemented tasks:
- Explicitly untouched areas:
- Algorithm version before/after:

## Root-cause evidence
- Per-day rule evidence:
- Cross-day load evidence:
- Dynamic reallocation evidence:
- Whole-plan objective evidence:

## Verification
- dart format:
- flutter analyze:
- flutter test:
- integration tests:
- property seeds/runs:
- maximum visited states:
- Windows manual scenarios:

## Golden review
- Changed fixture rows:
- Reason for each change:
- Reviewer:

## Safety
- Stale zero-write evidence:
- Transaction rollback evidence:
- Adjustment failure preservation evidence:
- Real user data used: no

## Remaining limitations
- Mathematical global optimum is not claimed.
- Task dependencies and general travel time remain outside this release.
- Energy and preferred windows remain soft preferences only.

## Status
- Complete / incomplete / blocked:
- Remaining tasks:
- Blocking condition:
```

本文档创建时只冻结算法规则和实施顺序，不代表任何 Task 已完成。状态只能在对应代码、自动化测试和人工证据实际存在后更新。
