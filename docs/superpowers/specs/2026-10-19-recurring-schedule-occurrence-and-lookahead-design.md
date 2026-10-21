# 周期目标：单次执行、跨周预排与历史一致性设计

> 日期：2026-10-19
> 状态：已确认设计，等待按实施计划执行
> 适用基线：1.11.0 执行事实架构
> 目标版本：1.11.0（尚未发布；本设计的周期能力与 schema 扩展并入同一版本，不新增 1.12）
> 实施计划：`docs/superpowers/plans/2026-10-19-recurring-schedule-occurrence-and-lookahead.md`

## 1. 目的

本设计一次性解决周期目标在“模板、周实例、计划块、执行实例、进度、结算、历史、统计、通知”之间身份混用的问题，包括但不限于：

- 完成一次周期安排，却把同周其他安排全部标为完成；
- 手动补记后重新排程，已经结束但未完成的周期安排从日历消失；
- 下周周期目标只能等到下周开始后才生成，无法提前看到；
- 下周只进入滚动窗口几天时，整周目标被错误挤进这几天；
- 周期实例混入普通任务列表、普通任务完成率、普通截止提醒；
- 模板的“仅本周／从下周／整个系列”修改范围实际上互相串扰；
- 计划版本替换、执行拆分、撤销、升级、删除、备份与导出后产生不一致。

本设计不是一个页面补丁。它把周期目标从“借用普通任务状态的特殊任务”改成“以周实例为结算单位、以计划片段为单次执行单位、以执行证据为进度来源”的完整领域能力。

## 2. 已确认的产品决策

### 2.1 周界与可见性

1. 周期固定按计划时区的本地周一 00:00 至下周一 00:00 结算，采用半开区间 `[start, end)`。
2. 当前执行计划至少覆盖未来 7 个本地日历日。
3. 系统同时维护下一完整周（周一至周日）的预排；因此用户最迟在本周内就能看到下周完整安排，不必等下周开始。
4. “信任自动调整”关闭时，下周预排以“待确认预排”显示：
   - 持久化，重启不丢失；
   - 不改变已确认计划；
   - 不发送正式开始提醒；
   - 使用文字、图标和边框共同区分，不能只靠颜色；
   - 用户可整份确认或要求重算。
5. “信任自动调整”开启时，只有完整可行且通过全部校验的预排才可自动转为正式计划；部分计划、搜索预算耗尽、输入过期和结构冲突均不得自动应用。
6. 用户长期不确认预排时，预排继续显示但不伪装成正式安排；进入执行日期前仍未确认时显示非模态待办标记，不弹强制窗口、不发正式提醒。

### 2.2 完成语义

1. 普通任务的“完成”仍表示完成整个任务。
2. 周期日历块的“完成本次”只完成该可见计划片段，不完成同周其他片段，也不直接完成周期目标。
3. 周期目标的“本周达标”由有效进度推导；“结束本周”是独立结算动作。
4. 达到目标后不再新增排程，但真实的额外投入仍可保留为超额进度。
5. 单次完成确认可以补足该片段尚未由真实活动覆盖的计划量，但不得伪造成真实专注时长。
6. 同一片段已有真实活动 40 分钟、计划 50 分钟时，点击“完成本次”最多产生 10 分钟确认进度；不得得到 90 分钟，也不得把真实投入显示成 50 分钟。

### 2.3 模板与周实例

1. 模板描述系列默认值；周实例保存该周的完整快照。
2. “仅本周”只修改当前开放周实例快照。
3. “从下周开始”修改模板及所有未开始的未来周实例，不影响当前周和历史周。
4. “整个系列”修改模板、当前开放周和所有未开始未来周；已结算历史不改写。
5. 开始日或结束日落在周中时，该周只允许在实际有效区间内排程，目标不静默按比例缩减。界面必须明确提示这是一个不足七天的周期。
6. 暂停到某日表示在该日结束前不安排；恢复后的同周仍可继续安排。若用户要跳过整周，使用“跳过本周”，不把“暂停到周三”解释成整周暂停。
7. 计划时区是工作区级权威时区。周期模板必须与工作区计划时区一致；显示时区可不同，但不能改变历史周界。

## 3. 术语与身份

| 名称 | 含义 | 稳定身份 |
|---|---|---|
| 周期模板 | 长期系列规则 | `templateId` |
| 周实例 | 某模板在某本地周的结算对象 | `cycleId`，并对 `(templateId, periodStartLocalDate)` 唯一 |
| 内部排程载体 | 为兼容通用排程器而生成的隐藏任务 | `transportTaskId`，不得暴露为普通任务 |
| 计划版本 | 一次已确认计划 | `planVersionId` |
| 计划块 | 某计划版本中的可见时间块 | `(planVersionId, blockId)` |
| 执行实例 | 1.11.0 中一次执行承诺的谱系 | `occurrenceId` |
| 执行片段 | 当前可见且可独立完成的一段承诺 | `fragmentId` |
| 活动段 | 真实计时形成的精确区间 | `segmentId` |
| 进度证据 | 对周期有效进度的可审计来源 | `evidenceId` 或 execution credit 主键 |
| 待确认预排 | 未进入正式计划的持久化提案 | `previewId` |

禁止再用 `taskId` 同时代表以上多个身份。`taskId` 只用于通用排程输入兼容和普通任务关联。

## 4. 不变量

### 4.1 身份不变量

1. 一个周实例只有一个 `cycleId` 和一个内部排程载体。
2. 一个已确认计划块恰好链接一个执行片段。
3. 一个执行片段属于一个执行实例；一个执行实例可以因重排拥有多个片段，但片段完成状态相互独立。
4. UI、命令、通知载荷必须携带 `(planVersionId, blockId, fragmentId)` 或等价强身份，禁止通过 `taskId` 查“第一条”执行实例。
5. `continuedFromId` 只可用于有明确一对一来源的移动。拆分或合并不得按任务 ID 猜测身份。

### 4.2 进度不变量

1. 真实投入只来自 1.11.0 的有效活动段和 `ExecutionCreditAllocation(targetKind=recurringCycle)`。
2. 手动补记也必须产生真实活动段，并经同一 allocation 管道入账。
3. “完成本次”产生声明式完成证据，不产生 `time_entries` 或伪造活动段。
4. 周期有效进度等于：有效真实分配量 + 有效声明式补足量；同一片段的两者合计不得超过该片段承诺量。
5. 活动段跨周时按真实周界切分；每一微秒最多分配一次。
6. 内部以微秒守恒，只有展示层四舍五入为分钟。
7. 撤销通过反向证据或修订完成，不删除原始审计事实。

### 4.3 状态不变量

1. 周实例正常状态迁移为 `open -> met | missed | skipped`。
2. 当前周达到目标后可以推导为已达标并停止新增排程；真实追加活动仍可记录。
3. 已结算周期不能被普通手动补记直接改写；历史修正必须走显式更正命令并保留理由。
4. `skip`、`settle`、`correct`、`completeFragment` 都必须幂等。
5. 内部排程载体状态不得作为周期真相；它只能是可重建投影。

### 4.4 计划不变量

1. 已开始、已完成或在计划版本有效期内已经结束的块属于历史事实，不因重排消失。
2. 尚未开始且被新计划替换的块可以撤回。
3. 补充下周预排不得移动、删除或重建已确认的当前块。
4. 待确认预排不得占用正式通知、正式执行入口和普通计划统计。
5. 确认预排前必须重新计算输入哈希、算法版本、基础计划版本、时间边界和全部硬约束。

## 5. 数据模型

### 5.1 `recurring_task_cycles` 扩展

为现有表增加并迁移以下字段：

- `cycle_id TEXT NOT NULL UNIQUE`：稳定周实例身份；旧数据按 `templateId + periodStartLocalDate` 确定性回填。
- `period_start_utc INTEGER NOT NULL`
- `period_end_utc INTEGER NOT NULL`
- `effective_start_utc INTEGER NOT NULL`
- `effective_end_utc INTEGER NOT NULL`
- `time_zone_id TEXT NOT NULL`
- `template_revision INTEGER NOT NULL`
- `title_snapshot TEXT NOT NULL`
- `notes_snapshot TEXT NOT NULL`
- `area_id_snapshot TEXT NULL`
- `project_id_snapshot TEXT NULL`
- `priority_snapshot TEXT NOT NULL`
- `energy_level_snapshot TEXT NOT NULL`
- `split_mode_snapshot TEXT NOT NULL`
- `min_chunk_minutes_snapshot INTEGER NOT NULL`
- `max_chunk_minutes_snapshot INTEGER NOT NULL`
- `preferred_start_minute_snapshot INTEGER NULL`
- `preferred_end_minute_snapshot INTEGER NULL`
- `pace_snapshot TEXT NOT NULL`
- `allowed_weekdays_mask_snapshot INTEGER NOT NULL`
- `revision INTEGER NOT NULL DEFAULT 1`
- `settled_at_utc INTEGER NULL`

约束：

- `period_end_utc > period_start_utc`；
- 有效区间必须位于周期区间内且 `effective_end_utc > effective_start_utc`；
- 时间偏好两端同时为空或同时非空；
- `revision >= 1`；
- 旧周期按当时内部任务和模板能恢复的字段回填；无法恢复的字段使用迁移时模板值并写迁移诊断，不伪称为原始历史值。

存储精确 UTC 周界是为了防止：模板时区改变、设备旅行、时区数据库更新后重新解释历史。

### 5.2 执行片段

新增 `execution_fragments`：

- `fragment_id TEXT PRIMARY KEY`
- `occurrence_id TEXT NOT NULL REFERENCES execution_occurrences(id)`
- `cycle_id TEXT NULL REFERENCES recurring_task_cycles(cycle_id)`
- `root_fragment_id TEXT NOT NULL`
- `source_fragment_id TEXT NULL`
- `allocated_micros INTEGER NOT NULL`
- `completed_micros INTEGER NOT NULL DEFAULT 0`
- `state TEXT NOT NULL`：`planned | started | completed | withdrawn | superseded`
- `created_at_utc INTEGER NOT NULL`
- `completed_at_utc INTEGER NULL`
- `revision INTEGER NOT NULL`

`execution_block_links` 增加 `fragment_id`，并保证同一 `(dataEpoch, planVersionId, blockId)` 只有一个片段。

关联规则：

1. 新块创建新 occurrence 和新 fragment。
2. 明确的一对一移动保留 occurrence 和 fragment。
3. 一对多拆分保留 occurrence，但为每个新块创建独立 fragment；各 fragment 分配量之和等于被替换片段的未完成量。
4. 多对一合并必须携带显式父片段集合；当前提案模型不能表达时，禁止合并并回报结构冲突，不能按任务 ID 猜测。
5. 已开始或已完成片段冻结，不参与拆分、合并和撤回。

### 5.3 声明式完成证据

新增 `recurring_completion_evidence`：

- `evidence_id TEXT PRIMARY KEY`
- `data_epoch TEXT NOT NULL`
- `operation_id TEXT NOT NULL`
- `cycle_id TEXT NOT NULL`
- `fragment_id TEXT NOT NULL`
- `amount_micros INTEGER NOT NULL`
- `kind TEXT NOT NULL`：`blockCompletion | reversal | correction`
- `reverses_evidence_id TEXT NULL`
- `recorded_at_utc INTEGER NOT NULL`
- `effective_at_utc INTEGER NOT NULL`
- `sequence INTEGER NOT NULL`
- `reason TEXT NULL`
- `revision INTEGER NOT NULL`

约束：

- `(data_epoch, operation_id)` 唯一；
- 正向证据 `amount_micros > 0`；
- 反向证据必须引用既有有效证据且不能重复撤销；
- 一个片段的有效声明量不能超过 `allocated_micros - 已分配真实活动量`。

### 5.4 待确认预排

新增 `pending_plan_previews` 与 `pending_plan_preview_blocks`：

`pending_plan_previews` 至少包含：

- `preview_id`
- `kind = recurringLookahead`
- `base_plan_version_id`
- `input_hash`
- `algorithm_version`
- `window_start_utc` / `window_end_utc`
- `time_zone_id`
- `status = active | superseded | accepted | rejected | stale`
- `created_at_utc` / `expires_at_utc`
- `summary_json` / `diagnostics_json`
- `revision`

块表保存标题投影、任务／周期／片段来源、时间范围和解释码。预排表属于数据库备份和 JSON 导出范围。

同一工作区同一预排类型最多一个 `active` 版本。新预排以事务方式把旧版本置为 `superseded`。

## 6. 周实例生成与生命周期

### 6.1 相交规则

周实例是否存在，按周期 `[periodStart, periodEnd)` 与模板有效区间是否相交判断，不再只比较周一日期。

- `effectiveStart = max(periodStart, startsOn)`；
- `effectiveEnd = min(periodEnd, dayAfter(endsOn))`；
- 暂停只提高当前有效起点，不删除已经存在的周实例；
- 若有效区间为空，不产生排程输入；
- 若允许星期与有效区间没有交集，返回 `noEligibleWeekday` 配置诊断，不冒充“可用时间不足”。

部分周的目标默认仍为用户设置的完整目标，不静默折算。界面在保存时展示“本周只有 N 个有效日，仍按 X 分钟计算”。

### 6.2 生成顺序

一次维护事务按以下顺序执行：

1. 取得单飞锁，防止启动、恢复、日期切换和排程读取并发维护。
2. 结算已经结束的开放周期。
3. 为当前周和下一完整周创建或同步实例。
4. 更新已确定的 carry-in。
5. 重建内部排程载体投影。
6. 提交事务。
7. 事务后只发出一条聚合变更事件。

仓储的 `createIfAbsent` 必须返回明确的 `created` 布尔值；禁止通过比较确定性 task ID 猜测，也禁止捕获所有异常并一律当作唯一键竞争。

`RecurringCycleRun.changed` 必须包含：创建、结算、结转改变、快照改变、载体投影改变和状态更正，而不是只统计创建与结算。

### 6.3 滚动维护触发点

维护发生在：

- 应用启动完成后；
- 从后台恢复后；
- 本地日期跨日后；
- 计划时区显式改变后；
- 模板创建、编辑、暂停、恢复、归档、删除后；
- 备份恢复后的首次新进程启动；
- 有效进度改变后。

所有触发合并、去抖、单飞。读取 `ScheduleProblem` 不能在内部创建周期后递归触发另一轮相同排程。

## 7. 排程算法

### 7.1 两个窗口

1. **执行窗口**：从现在起至少覆盖未来 7 个本地日历日，用于正式可执行计划。
2. **预排窗口**：下一完整周的周一至周日，用于提前可见。

两个窗口都以本地午夜计算，禁止使用 `nowUtc + Duration(days: 7)` 代替七个本地日历日。

预排生成时：

- 当前已确认块作为硬冻结输入；
- 已存在且仍有效的待确认块作为最小改动参照，不作为已确认事实；
- 不得移动执行窗口内的已确认块；
- 重叠部分按 cycle/fragment 分配量去重，不得把同一剩余量在正式计划和预排中各排一次。

### 7.2 周期推进目标

不能把周实例的全部剩余分钟直接交给一个只覆盖部分周期的窗口。对每个周实例计算：

- `R`：周期剩余有效进度；
- `C_visible`：有效区间内、当前计划窗口覆盖部分的合法容量；
- `C_after`：窗口之后至周期结束前的合法容量；
- `r = C_visible / (C_visible + C_after)`，无容量时单独诊断；
- `requiredNow = max(0, R - C_after)`，确保不把无法留到后面的量推迟；
- `curve(r)`：节奏曲线。

曲线：

- `even`：`curve(r) = r`；
- `early`：`curve(r) = 1 - (1-r)^2`；
- `deadlineWeighted`：`curve(r) = r^2`；
- `selectedWeekdays`：先过滤允许星期，再按剩余合法容量使用 `even` 曲线。

窗口承诺量：

`targetNow = clamp(max(requiredNow, ceil(R * curve(r))), 0, R)`

最后按粒度和最短片段调整；若调整会超过 `R`，只允许合法的短尾段。容量计算必须看到整个周期剩余区间的固定日程、保护时间、睡眠、每日上限、允许星期和有效起止日，不能把窗口外容量硬编码为 0。

这条规则同时修复：

- 下周整周目标被挤进周一到周三；
- “临近截止”实际上仍按最早候选排；
- “均匀分布”只按天数、不按真实容量；
- 周末很空却仍优先挤工作日；
- 未来周期没有 `availableFromUtc` 而被排到本周。

### 7.3 候选边界

任何周期任务都必须满足：

- `availableFromUtc >= cycle.effectiveStartUtc`；
- `dueAtUtc <= cycle.effectiveEndUtc`；
- 候选本地星期在实例快照的允许集合内；
- `early` 的日历日偏移用本地日历算术，不用固定 48 小时；
- 期望时段是软偏好，除非用户显式选择硬限制；
- 高精力仍是软偏好，不能把其他时间全部视为不可用。

### 7.4 稳定性

目标函数顺序保持既有算法 20 的优先级，并补充：

1. 硬约束与用户明确锁定；
2. 已开始／已完成片段冻结；
3. 已确认块最小改动；
4. 防止截止失败和周期不可完成；
5. 周期节奏曲线偏差；
6. 每日负荷与周内分布；
7. 碎片、坏空档、类别切换、期望时段与能量软偏好；
8. 确定性 tie-break。

预排每天滚动更新时，未发生输入变化的块必须保持 fragment 身份和时间；不能每天刷新成一套新 UUID。

## 8. 执行、完成、撤销与进度

### 8.1 完成本次

命令参数：

- `operationId`
- `planVersionId`
- `blockId`
- `fragmentId`
- `expectedFragmentRevision`
- `occurredAtUtc`

事务内：

1. 校验块链接、片段、周实例和当前数据代次。
2. 拒绝待确认预排块、已撤回块、其他计划版本中的过期块。
3. 读取该片段已经取得的真实周期 credit。
4. 计算声明式补足量，不超过未覆盖承诺量。
5. 写完成证据、执行事件和幂等结果。
6. 更新 fragment 完成量和状态。
7. 重算周期有效进度与内部载体投影。
8. 写 outbox：计划失效、通知对账、统计缓存失效。

重复提交相同 `operationId + requestHash` 返回原结果；同 ID 不同请求返回冲突。

### 8.2 手动补记

旧 `RecurringTaskService.recordManualMinutes` 不再直接写 `time_entries`。它只能调用 1.11 执行命令：

- 用户必须选择或确认实际发生日期与时间；
- 默认值可为“现在结束”，但不能用现在的时间去冒充某个历史周期；
- 记录跨周时自动切分 credit；
- 已结算历史需要进入“更正历史”流程；
- 保存活动段、allocation、周期进度和 outbox 必须同一业务事务提交。

### 8.3 撤销与更正

- 撤销“完成本次”只反转对应 completion evidence；
- 不恢复整个任务状态；
- 不影响兄弟 fragment；
- 已由真实活动覆盖的量不能通过撤销声明证据扣掉；
- 历史更正保存原值、修订值、原因、操作者时间和引用链；
- 更正使当前周低于目标时允许重新开放排程；过去周保持结算记录并显示“已更正”，由专用命令重算结果。

## 9. 模板操作语义

### 9.1 编辑范围

周实例必须完整保存排程快照。排程输入只读实例快照，不再混读“当前模板 + 旧周期”。

- `thisCycle`：写当前 cycle snapshot；
- `fromNextWeek`：写模板，并同步所有未开始未来 cycle snapshot；
- `entireSeries`：写模板、当前开放 cycle 和未开始未来 cycle；
- 历史 cycle 不改。

标题、领域、项目、优先级、精力、拆分、最短／最长片段、期望时段、节奏、允许星期和目标分钟全部遵守同一范围，不能只有目标分钟生效。

### 9.2 暂停、归档、跳过、删除

- 暂停：保留 cycle 与进度；暂停截止前不排，已开始／已完成片段保留，未开始未来块撤回并重排。
- 跳过本周：当前 cycle 进入 `skipped`，撤回其未开始块，不结转缺口。
- 停止以后生成：默认“本周继续、下周起归档”；若用户选择“立即停止”，明确撤回当前未开始块。
- 恢复生成：从下一合法有效日恢复，不改写历史。
- 删除：用户界面隐藏模板、周期、进度和历史；计划历史不能被破坏性改写。需要保留引用的执行／计划事实转为匿名墓碑，移除标题、备注、领域等个人内容。
- “永久清除所有数据”仍执行真正的全库清除，与单个目标删除区分。

## 10. 历史日历与计划版本

历史投影按块判断：

1. 若 occurrence/fragment 已开始或已完成，保留。
2. 否则，若块结束时间不晚于下一计划版本生效时间，保留为当时有效历史。
3. 尚未开始且在新版本生效后才会发生的旧块不保留。
4. 去重主键优先使用 fragment；旧数据退化为 `(planVersionId, blockId)`，绝不使用 `taskId`。
5. 不采用“每天挑一个版本”或“把全部版本做并集”。

删除周期目标不得直接删除历史 `schedule_blocks`，否则会改变已经确认过的计划。匿名墓碑在普通 UI 和统计中不可见，但维持引用完整性。

## 11. UI 与交互

### 11.1 普通任务页

- 普通列表、数量、筛选、搜索和批量操作排除内部周期载体。
- 周期目标使用独立区域，展示本周完成量、目标、剩余量、下一次安排和状态。
- 周期目标没有普通任务复选框。
- 内部 task 深链接重定向到 `/tasks/recurring/:templateId`。

### 11.2 今日与日历

- 正式周期块显示“完成本次”；只更新当前 fragment。
- 待确认预排显示“待确认”，不能开始、完成或接收提醒。
- 已完成片段显示独立勾选；兄弟片段不变化。
- 已结束未完成块继续显示为“已结束·未记录”，不因重排消失。
- 下周卡片显示“下周”或日期范围，禁止统一写“本周已完成”。
- 待确认状态必须有文本和语义标签；键盘可达，屏幕阅读器能读出“待确认预排，尚未生效”。

### 11.3 周期详情

- 分开展示：有效进度、真实投入、声明完成、超额投入。
- “记录进度”进入统一手动记录流程，历史日期必须显式确认。
- “结束本周”仅在达标时直接可用；未达标强制结束需要二次确认、原因和审计记录。
- 历史周默认只读；更正使用单独入口。

### 11.4 预排入口

- 左侧导航底部或日历标题区显示非模态更新标记；不得弹启动窗口。
- 点击进入预排差异页，显示新增、移动、撤回、未安排原因和对当前计划影响。
- 确认按钮提交整份预排；输入已变化时显示“预排已过期，已重新计算”，不静默应用旧结果。

## 12. 通知

1. 内部周期载体不产生普通任务截止提醒。
2. 正式周期块通知携带 plan/block/fragment 身份，打开准确执行入口。
3. 待确认预排不创建系统通知。
4. 预排确认后通过 outbox 对账创建提醒；撤回、移动、完成后取消旧提醒。
5. 跨周结算必须先完成，再允许新周提醒被调度，避免按旧 carry-in 提醒。
6. 同一事件只能有一条有效提醒意图；重复同步幂等。

## 13. 统计、搜索、导出与备份

### 13.1 统计

- 内部周期载体排除普通任务完成率、逾期率和准时率。
- 周期统计独立展示达标率、有效进度、真实投入、声明完成和超额量。
- 历史计划时间使用计划版本有效期投影，不只读取当前 confirmed 版本。
- 待确认预排不进入正式计划时长和执行率。
- `goalCount`、跳过周和错过周的分母规则必须在统计模型与文案中统一。

### 13.2 导出

当前 `DriftExportDataSource` 未导出周期模板、周期实例和执行事实，本设计要求补齐：

- recurring templates/cycles；
- execution occurrences/fragments/events/activity segments/credits；
- completion evidence；
- pending previews（标注未确认）；
- 更正与撤销链。

导出读取必须使用一致性快照。CSV 为复合主键记录生成稳定 `record_id`，不能留空；JSON 提升 schemaVersion 并记录单位和时区。

### 13.3 备份恢复

- SQLite 备份天然包含新表；恢复后在新进程启动时运行迁移、execution backfill、周期维护和通知对账。
- 恢复前后的 `dataEpoch`、幂等操作和待确认预排不得交叉重放。
- 旧备份恢复后重建当前／未来未开始块的 occurrence/fragment；过去块保持 legacy 历史，不伪造完成证据。

## 14. 事务、并发与失败恢复

必须提供应用层业务事务网关，覆盖：

- 创建／同步 cycle 与内部载体；
- 模板范围编辑；
- 完成／撤销 fragment；
- 手动记录与周期 credit；
- 周结算与 carry-in；
- 应用／确认预排；
- 删除／匿名化周期目标。

每个命令包含 operation ID、请求摘要和期望 revision。并发冲突返回可重试结果，不以最后写入者静默覆盖。

以下失败均必须零部分写入：

- activity 已写但 credit 未写；
- completion evidence 已写但 fragment 未更新；
- plan 已应用但 block link 未创建；
- cycle 已创建但 transport task 不存在；
- preview 已标 accepted 但正式 plan 未提交。

统计失效、偏好证据和通知同步使用事务内 outbox，允许重试，不反向回滚已经提交的业务事实。

## 15. 迁移与版本兼容

1. 数据库 schema 从 11 提升到 12。
2. 迁移前沿用现有预升级一致性快照。
3. v10 → v11 迁移分阶段：建新表／加 nullable 列、回填、校验、建立唯一索引、再收紧非空约束。
4. 所有回填可重复执行且结果确定。
5. 迁移后运行以下审计：
   - 每个 cycle 有唯一 cycleId 和合法周界；
   - 每个当前／未来正式块有 block link 和 fragment；
   - credit 总量不超过 activity segment；
   - completion 补足不超过 fragment 承诺量；
   - 没有普通 UI 可见的内部周期载体。
6. 因旧二进制不能打开更高 schema，升级后不能直接二进制回退并继续写同一数据库。回退必须恢复预升级快照；更新界面和发布说明必须明确这一点。
7. 迁移失败时保持原数据库不变，写诊断并启动恢复入口，不得打开半迁移库。

## 16. 对既有文档的覆盖关系

本设计只覆盖以下旧结论，不推翻其他算法 20 规则：

1. `2026-10-13-visible-free-time-false-shortage-repair.md` 中“未来周期实例不进入当前提案”改为：**与执行窗口或下一完整周预排窗口相交的周期必须进入对应计划；窗口外周期仍排除**。
2. `2026-10-17-algorithm-20-complete-planning-design.md` 中同类“仅当前周周期”限制按上一条收窄。
3. 1.11.0 执行设计中的 occurrence、activity segment、credit、operation ledger、outbox 和 dataEpoch 继续作为权威基础。本设计只增加 fragment 级独立完成和 recurringCycle 生产接线，不另造第二套执行系统。

## 17. 验收矩阵

### 17.1 核心场景

1. 同周三个周期块，完成中间一个，只该块打勾，周进度只增加其未覆盖量。
2. 其中一个块已有部分真实计时，完成本次不重复计算。
3. 撤销中间块，只撤销该块声明证据。
4. 手动补记后重排，所有已经结束的旧块仍在历史中。
5. 周五可以看到下周一至周日完整待确认预排。
6. 关闭信任开关时重启，预排仍在且无系统提醒。
7. 开启信任开关时，完整合法预排自动应用；部分／过期／预算耗尽均不应用。
8. 当前计划已确认的块在补下周预排时一个都不移动。
9. 周日 23:50 至周一 00:20 的活动按真实周界拆分。
10. 高精力偏好不阻止在其他合法时段安排。

### 17.2 范围与生命周期

11. “仅本周”修改节奏／星期／精力／片段长度只影响本周。
12. “从下周”不改变当前周，但更新所有未开始未来周。
13. 暂停到周三后，周四可继续排；“跳过本周”则整周不排。
14. 周中开始／结束时不越过有效日期，也不静默缩减目标。
15. 归档默认保留当前周；立即停止需要显式选择。
16. 删除目标后普通 UI、搜索、统计不再出现，计划历史引用仍一致且个人文本已匿名化。

### 17.3 时间与稳定性

17. 上海、纽约 DST 开始／结束周的周期边界正确。
18. 七个本地日历日不因 DST 变成六天或八天。
19. 模板／工作区显示时区变化不重新解释已结算历史。
20. 系统时间前跳、后调和重复启动不重复生成、结算或入账。
21. 同一输入重复生成预排，块身份与时间稳定。
22. 未来只进入窗口三天时，不把整周均匀目标全部挤入三天；若后半周容量不足，`requiredNow` 会提前安排并给出解释。
23. deadlineWeighted 的累计目标晚于 even，early 早于 even；容量不足时三者都保证可完成性优先。

### 17.4 并发与恢复

24. 双击完成、重试、重启重放都只入账一次。
25. 手动记录与周结算并发时结果等价于某个完整串行顺序，不出现半写。
26. 模板编辑与预排确认发生 revision 冲突时旧预排变 stale，不覆盖新设置。
27. v11 真库迁移后所有当前／未来块完成补链，历史不伪造。
28. 备份恢复后不会重放恢复前 dataEpoch 的操作。

### 17.5 投影与合规

29. 普通任务数量、批量完成、普通逾期通知和普通 KPI 不包含内部周期载体。
30. 导出包含全部周期与执行事实，CSV 复合身份不为空，JSON 能还原证据链。
31. 待确认状态不只依赖颜色，键盘、屏幕阅读器和缩放布局可操作。
32. 删除和匿名化不破坏外键、计划版本或 execution 守恒审计。

## 18. 不在本轮范围

- 多人协作和云同步；
- 允许一个工作区同时使用多个计划时区；
- 月度／季度目标；
- 用机器学习自动改变周目标；
- 未经用户确认把待确认预排当成正式执行事实；
- 重写通用排程器为第二套“周期专用排程器”。

## 19. 完成定义

只有同时满足以下条件，才能称为完成：

1. 数据迁移、领域命令、排程、执行、UI、通知、统计、导出全部接线；
2. 本文验收矩阵逐项映射到自动化测试名和人工证据；
3. 全量静态分析、单元、仓储、迁移、Widget、路由、集成测试通过；
4. 使用从 1.11.0 升级的真实数据库副本完成一次迁移演练；
5. 没有把 PARTIAL、接口存在、单测存在或页面存在误报成生产完成；
6. 没有修改或丢失用户既有已确认计划和历史执行事实。
