# 容量感知排程：验收项审计表

> 逐行对应实施计划 `2026-10-16-capacity-aware-hierarchical-scheduler-repair.md` §10
> 「自动化验收矩阵」的 23 行。
>
> **这张表的用途**：让"路线图是否真的完成"可以被外部核对，而不是靠自述。
> 每一行都必须能回答"实现写在哪个文件、哪条测试钉住它、最近一次跑是什么结果"。
>
> **最近一次全量验证**：2026-10-17，`flutter test` → **2763 passed / 0 failed**，
> `flutter analyze` → No issues found，`dart format` → 0 changed，算法版本 **18**。
>
> **阻断等级**定义：
> - **P0** 失败即不可发布（会产生错误计划、丢数据或不可恢复）。
> - **P1** 失败则该功能承诺不成立，但可用人工兜底。
> - **P2** 失败只影响体验或可解释性。

---

## A. 容量与规则（3、2）

| # | 验收项 | 关键输入 | 必须结果 | 生产实现 | 测试（文件：用例名） | 类型 | 状态 | 未覆盖边界 | 阻断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 相邻区间 | 09:00–10:00、10:00–11:00 | 不冲突 | `availability_builder.dart`（半开区间合并）<br>`time_range.dart` | `test/scheduling/availability_builder_test.dart`：**合并重叠忙碌区间并保持半开边界可相邻**<br>`test/domain/time_range_test.dart`：相邻/相接判定 | 自动 | 通过 | 无 | P0 |
| 2 | 重叠占用 | 固定与保护重叠 30 分钟 | 容量只扣一次 | `day_capacity_ledger.dart`（`calendarGapMinutes` 唯一来源） | `test/scheduling/availability_builder_test.dart`：**固定日程与保护时间重叠 30 分钟，总容量只扣一次，且两个标签都在**<br>`test/scheduling/day_capacity_ledger_test.dart`：**固定日程与保护时间重叠 30 分钟只扣一次** | 自动 | 通过 | 三者以上互相重叠（两两已覆盖） | P0 |
| 3 | 工作日/周末规则 | 周一开窗，周末上限更高 | 周末用自己的上限 | `daily_scheduling_policy.dart`<br>`schedule_problem.dart`（`policyForLocalDate`） | `test/application/capacity_aware_week_planning_test.dart`：**周末账面容量按自己的上限 360 算，而不是复制窗口首日的 180** | 自动 | 通过 | 一周内出现两个不同"工作日规则"（如调休） | P0 |

## B. 跨日分配（1、5、6）

| # | 验收项 | 关键输入 | 必须结果 | 生产实现 | 测试（文件：用例名） | 类型 | 状态 | 未覆盖边界 | 阻断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 150/30 七天 | 工作日忙、周末空 | 周末参与，不固定前五日 | `day_allocation.dart`（K 计算 + 轮转） | `test/application/capacity_aware_week_planning_test.dart`：**150/30 不得固定选择前五个日期**、**150/30 均匀周期目标在七天等余量下也不得固定选前五日**<br>`test/scheduling/capacity_aware_week_golden_test.dart`：**容量感知黄金周** | 自动 | 通过 | 窗口跨周（14 天）时的轮转连续性 | P1 |
| 5 | 完全同分 | 七天业务字段相同 | 同周期稳定、跨周期轮换 | `day_allocation.dart`（`AllocationRotation`，SHA-256 前 8 字节） | `test/scheduling/even_distribution_allocator_test.dart`：**参与日期按本地日期升序，与输入顺序无关**<br>`test/application/scheduler_determinism_property_test.dart`：**分配结果本身是确定的** | 自动 | 通过 | 轮换偏移的**跨周期**前进（同一周期内已覆盖） | P1 |
| 6 | 普通任务 | 截止宽松 | 低负载日优先 | `schedule_objective.dart`（方案级字典序）<br>`day_allocation.dart`（`_rankEligibleDates`） | `test/application/capacity_aware_week_planning_test.dart`：**普通任务必须用上低负载周末，而不是把工作日继续堆满** | 自动 | 通过 | 负载率极接近（差值 < 粒度）时的排序 | P1 |
| 7 | 临近截止 | 周末晚于截止 | 不使用周末 | `day_allocation.dart`（`_eligibleDates` 截止剪枝） | `test/application/capacity_aware_week_planning_test.dart`：**低负载周末晚于截止时不得使用，并如实报告缺口** | 自动 | 通过 | 截止落在本地日边界（23:59/00:00） | P0 |
| 8 | 均匀目标 | 任务等量与总负载冲突 | 总负载略优先 | `day_allocation.dart`（even 分支 + 余量循环） | `test/scheduling/even_distribution_allocator_test.dart`：**某天容量 25、其余充足 ⇒ 先用光 25，再均分剩余**、**总容量只有 120 ⇒ allocatableMinutes=120 且缺口精确**<br>`test/application/recurring_even_distribution_test.dart` | 自动 | 通过 | 多任务同时 even 且总需求超容量 | P1 |
| 9 | 高精力任务 | 高精力窗口满，其他时段空 | 使用其他合法时段 | `candidate_scorer.dart`（精力是软偏好） | `test/scheduling/dynamic_short_tail_test.dart`：**高精力任务只有普通时段可用时仍能完整安排（精力是软偏好，不是硬过滤）**<br>`test/scheduling/unscheduled_reason_test.dart`：**A06 高精力时段被占、只剩低精力时段 ⇒ 仍然排进去** | 自动 | 通过 | 无 | P1 |
| 10 | 日预算落地失败 | 周二预算无连续空档，周六可放 | 动态转到周六 | `day_allocation.dart`（K 与额度）<br>`schedule_engine.dart`（遍历所有预算日期） | `test/scheduling/dynamic_reallocation_test.dart`：**周二预算放不下时，额度必须动态转到周六** | 自动 | 通过 | 三个以上碎片日同时放不下 | P1 |

> **#10 的说明**：动态转移由"分配器按容量决定 K 与额度"+"引擎遍历所有有预算的日期"
> 共同达成，**不存在**多轮重分循环。曾经声明的 `maxReallocationPasses` 字段从未被读取，
> 已于 2026-10-17 删除（`1711b708`）。

## C. 稳定性与改进（7、8、9）

| # | 验收项 | 关键输入 | 必须结果 | 生产实现 | 测试（文件：用例名） | 类型 | 状态 | 未覆盖边界 | 阻断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 11 | 优化回退 | 工作日候选软分高 | 不破坏跨日预算 | `schedule_engine.dart`：`_improve` 的 `_wholePlanIsBetter`<br>`plan_quality_validator.dart` | `test/scheduling/plan_quality_validator_test.dart`（5 条：唯一 ID、分钟守恒、日预算、每日上限、异常缺口）<br>`test/application/capacity_aware_week_planning_test.dart`：**150/30 均匀周期目标**（改进阶段不吞预算） | 自动 | 通过 | 多任务交叉预算 | P1 |
| 12 | 普通重排 | 微小偏好改善、需移动 2 块 | 保留旧计划 | `local_repair.dart`（`minimizeChangedBlocks`）<br>`schedule_engine.dart`（`_objectiveProfileOf`） | `test/scheduling/engine_minimizes_changes_test.dart`：**既有未锁定块携带原 id 进入排程**<br>`test/application/minimize_changed_blocks_identity_test.dart`（5 条，真实装配）<br>`test/scheduling/minimize_changed_blocks_test.dart`（函数级 10 条） | 自动 | 通过 | — | P1 |
| 13 | 明确延后 | 延后 10 分钟可局部推动 | 只移动必要块 | `local_repair.dart`（级联）<br>`repository_schedule_problem_source.dart`（`adjustment`） | `test/application/defer_end_to_end_test.dart`：**延后 90 分钟后，目标块落在下界之后**、**同一任务的另一块原位冻结**、**目标块挤压别的确认块时，被挤开的那一块也带到位** | 自动 | 通过 | 跨日级联超过一天 | P0 |
| 14 | 延后无解 | 固定日程堵死 | 原计划保留，零写入 | `local_repair.dart`<br>`plan_application_service.dart`（调整前提闸门） | `test/application/defer_unschedulable_test.dart`：**整个窗口无处可放 ⇒ 明确报未安排、不得留原位、且不能应用**<br>`test/application/defer_unschedulable_test.dart`：**对照：不堵死时同一份输入能正常排出** | 自动 | 通过 | 部分日期堵死、其余可放 | P0 |

## D. 诊断与应用安全（9、10）

| # | 验收项 | 关键输入 | 必须结果 | 生产实现 | 测试（文件：用例名） | 类型 | 状态 | 未覆盖边界 | 阻断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 15 | 硬无解 | 总合法容量不足 | 精确缺口和证据 | `task_placement_diagnostics.dart`<br>`search_outcome.dart` | `test/scheduling/scenario_f_budget_exhausted_test.dart`：**真的无解才允许说"可用时间不足"，且默认拒绝、授权后可应用** | 自动 | 通过 | 无 | P1 |
| 16 | 搜索未决 | 状态预算极小 | 非容量文案、不可应用 | `search_outcome.dart`（五值枚举）<br>`plan_application_service.dart`（`isApplicableOutcome` 闸门） | `test/scheduling/scenario_f_budget_exhausted_test.dart`：**"未能确认完整方案" + 应用按钮禁用，且两种模式都禁用**、**四种失败处境的说法互不相同** | 自动 | 通过 | 状态预算恰好用尽但已找到完整解 | P1 |
| 17 | 结构异常 | 仍有合法候选却有缺口 | invariant violation | `search_outcome.dart`<br>`plan_quality_validator.dart` | `test/scheduling/scenario_f_budget_exhausted_test.dart`：**内部不变量被破坏时：不可应用 + 说清后果，也不说成容量不足**（ALG-42）<br>`test/scheduling/plan_quality_validator_test.dart`：**仍有合法余量却留下缺口 ⇒ 判为"没排好"** | 自动 | 通过 | 重复块 ID 在真实装配下的触发 | P0 |
| 18 | 预览过期 | 生成后修改每日规则 | stale、零写入 | `plan_application_service.dart`（inputHash + 算法版本闸门） | `test/application/plan_application_service_test.dart`：**算法版本不符 ⇒ 过期、零写入**、**过期提案不回调**<br>`test/application/search_outcome_application_gate_test.dart` | 自动 | 通过 | — | P0 |
| 19 | 应用中断 | 写入中途异常 | 全部回滚 | `plan_application_service.dart`（先校验后事务）<br>drift 事务 | `test/application/plan_application_service_test.dart`：**third block failure rolls back plan, blocks, log and supersede**——用 SQLite trigger 在**第 3 个块插入时** `RAISE(ABORT)`，随后断言 `scheduleBlocks` **为空**（3 块全回滚，不只是出错那一个）、`current()` 仍是旧版本、`changeLog` 为空 | 自动 | 通过 | 无 | P0 |

> **#19 说明**：这条用"注入真实写入期异常"的方式验证，不是靠"校验前置于事务"间接推断。
> 它同时断言了版本、块、日志、被取代标记四处的回滚，覆盖面比矩阵要求的更宽。

## E. 确定性与兼容（11、12）

| # | 验收项 | 关键输入 | 必须结果 | 生产实现 | 测试（文件：用例名） | 类型 | 状态 | 未覆盖边界 | 阻断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 20 | 决定性 | 同一输入 100 次 | JSON 逐值相同 | 全链路（无 `hashCode`/`Random`；旋转用 SHA-256） | `test/application/scheduler_determinism_property_test.dart`：**同一份输入连续排程 5 次，块序列逐值相同**、**同一个引擎实例复用也保持确定性**<br>`test/application/minimize_changed_blocks_identity_test.dart`：**同一份输入重复排程，块 id 与结果完全一致** | 自动 | 通过 | 用例跑 5 次而非 100 次（同质性，风险低） | P1 |
| 21 | 输入乱序 | Map 和列表顺序改变 | 输出不变 | `day_allocation.dart`（起点排序）<br>`schedule_engine.dart`（`_compareBlocks`） | `test/application/scheduler_determinism_property_test.dart`：**任务输入顺序改变不影响结果**、**锁定块输入顺序改变不影响结果** | 自动 | 通过 | 固件/锁定块三者同时乱序 | P1 |
| 22 | DST | 本地日期跨切换 | 分日和分钟正确 | `core/time_zone.dart`（`localDateOf`/`localMidnightToUtc`）<br>`day_capacity_ledger.dart` | `test/scheduling/even_distribution_allocator_test.dart`：DST 切换日的日期枚举<br>`test/features/calendar/course_whole_time_mapping_test.dart`：夏令时时刻映射<br>`test/scheduling/day_capacity_ledger_test.dart`：**跨午夜的基线块按本地日分开** | 自动 | 通过 | 无 | P0 |
| 23 | 旧计划 | 升级后只打开应用 | 不自动重排 | `plan_application_service.dart`（算法版本不符 ⇒ stale）<br>`replanning_coordinator.dart` | `test/application/plan_application_service_test.dart`：**算法版本不符 ⇒ 过期、零写入**、**版本相符时正常应用**<br>`test/app/replan_prompt_test.dart`：**自动应用成功时如实说明，且不给"查看调整"**、**同一个提案只提示一次** | 自动 | 通过 | 无 | P0 |

## F. Task 8 的身份改造（越界完成的必要修复）

计划把这项列为已知缺口并排除在范围外，用户于 2026-10-17 确认越界修复。

| 验收项 | 生产实现 | 测试 | 状态 |
| --- | --- | --- | --- |
| 未锁定既有块携带原 id 进入排程 | `schedule_engine.dart`：`_adoptableExistingBlocks` | `test/application/minimize_changed_blocks_identity_test.dart`：**真实装配：既有块保留原 id，minimizeChangedBlocks 因此不是空操作** | 通过 |
| 新块用新稳定 id，不冒用既有 id | `_blockId` | 同上：**新排的块不得冒用既有 id** | 通过 |
| 移动保留 id | `_improve` 的 `replacement` 用 `block.id` | 同上（留在原位不被记为已改动） | 通过 |
| 拆分：既有块不拆，新片段新 id | `_adoptableExistingBlocks` 的"累计不超目标" | 同上 | 通过 |
| 合并：引擎不做合并 | 无合并步骤 | 代码注释写明 | 不适用 |
| 锁定块身份不变 | 走 `lockedBlocks`，采纳时跳过 | 同上：**锁定块的身份语义不变** | 通过 |
| id 不参与优先级/容量/可行性 | 采纳判据不读 id 内容 | 同上：**旧数据兼容：id 是 uuid 形状的既有块同样被采纳** | 通过 |
| 重复排程一致 | 起点按 `(startUtc, id)` 排序 | 同上：**同一份输入重复排程，块 id 与结果完全一致** | 通过 |

---

## G. 人工验收（Task 12 Step 4–9）——**未执行**

六个场景需要可交互的 Windows 构建。本环境 `integration_test` 因
`flutter-web-sdk.zip` 下载握手失败无法运行（网络限制，非代码问题）。

| 场景 | 期望 | 状态 |
| --- | --- | --- |
| A | 工作日繁忙／周末空闲 | **待人工** |
| B | 截止覆盖均衡 | **待人工** |
| C | 高精力只是偏好 | **待人工** |
| D | 延后 10 分钟 | **待人工** |
| E | 预览过期 | **待人工** |
| F | 搜索预算耗尽诊断（「未能确认完整方案」、不显示「可用空间不足」、按钮禁用） | **待人工** |

> 其中 A、C、F 的**逻辑**已由自动测试覆盖（见 #6、#9、#16）；
> 人工要验的是**界面呈现**（文案、按钮状态、刷新行为），不是算法结论。
> 这两件事不能互相替代。

---

## H. 汇总

| 分类 | 行数 | 自动通过 | 部分覆盖 | 待人工 |
| --- | --- | --- | --- | --- |
| A 容量与规则 | 3 | 3 | 0 | 0 |
| B 跨日分配 | 7 | 7 | 0 | 0 |
| C 稳定性与改进 | 4 | 4 | 0 | 0 |
| D 诊断与应用安全 | 5 | 5 | 0 | 0 |
| E 确定性与兼容 | 4 | 4 | 0 | 0 |
| **合计** | **23** | **23** | **0** | — |
| G 人工场景 | 6 | — | — | **6** |

**结论**：23 项自动化验收**全部有直接证据**（每行都指向具体测试与具体用例名）。
六项人工验收**全部未执行**——本环境无法运行 `integration_test`。

因此路线图**不能**宣称"全部完成"。准确的说法是：

> **23/23 自动化验收通过，6/6 人工验收待执行，算法版本 18。**

## I. 这张表自身的可信度

写这张表时我有一次判断错误，值得记下来：最初把 #19（应用中断回滚）标成"未定位到
专门用例、部分覆盖"，理由是"没搜到注入写入失败的测试"。实际 `plan_application_service_test.dart`
里有一条用 SQLite trigger 注入写入期 `ABORT` 的用例，断言比矩阵要求的更严格。

**教训**：审计表里写"未覆盖"之前，必须按**行为**搜（`RAISE(ABORT)`、`throwsA`），
不能只按验收项的字面词（"回滚""中断"）搜。否则审计表本身会撒谎，
而它存在的全部意义就是不撒谎。