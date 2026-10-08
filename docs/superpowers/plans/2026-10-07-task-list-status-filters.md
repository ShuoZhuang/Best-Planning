# 任务列表状态筛选改进方案

> 日期：2026-10-07  
> 类型：有边界的任务列表体验改造  
> 适用工作树：`G:\best-planing\.worktrees\native-implementation`  
> 实施目标：解决任务页无法完整查看任务、任务是否已安排不明确、缺少状态筛选的问题。

## 1. 改进目标

任务页增加以下四个筛选项：

```text
全部 8　待安排 2　已安排 4　已完成 2
```

用户应当能够：

- 查看所有有效任务。
- 找到尚未进入当前计划的任务。
- 查看已经分配具体执行时间的任务。
- 查看历史已完成任务。
- 在筛选结果中继续搜索、排序、完成或恢复任务。

本批次不修改今日页、日历页、排程算法、统计模块和固定日程管理。

## 2. 状态口径

### 2.1 已完成

满足：

```text
task.status == completed
```

即使任务仍残留计划时间块，也必须归入“已完成”。

### 2.2 已安排

同时满足：

```text
任务没有完成、跳过或取消
当前已确认计划中存在该任务的时间块
该时间块结束时间 > 当前时间
```

以下情况也属于“已安排”：

- 正在进行且仍有有效时间块的任务。
- 已经逾期，但系统为其安排了新的未来时间块。
- 拆分成多个片段，且至少一个片段尚未结束。

### 2.3 待安排

同时满足：

```text
任务没有完成、跳过或取消
当前已确认计划中没有尚未结束的时间块
```

包括：

- 刚创建但还没生成计划的任务。
- 原来的安排已经过去，但任务仍未完成。
- 逾期且没有新的补排时间。
- 处于进行状态，但已经没有有效时间块的异常任务。

### 2.4 排除项

以下任务暂时不出现在这四个筛选中：

```text
skipped
cancelled
```

不得删除这些任务的数据。后续可以单独增加“归档任务”入口。

### 2.5 全部

“全部”是以下三类的并集：

```text
待安排 + 已安排 + 已完成
```

必须满足：

```text
全部数量 = 待安排数量 + 已安排数量 + 已完成数量
```

## 3. 界面要求

筛选栏放在搜索框下方、任务列表上方。

推荐使用 Flutter `SegmentedButton` 或具有相同语义和键盘操作能力的组件：

```text
[ 全部 8 ] [ 待安排 2 ] [ 已安排 4 ] [ 已完成 2 ]
```

具体要求：

- 默认选择“全部”。
- 当前选项有明确的填充色和选中状态。
- 数量随任务及当前计划数据更新。
- 窄窗口下允许横向滚动，不能压缩到文字重叠。
- 支持键盘焦点和方向键切换。
- 筛选项仅表达选中状态，不使用四种高饱和颜色。
- 任务卡片继续按照领域颜色显示，不根据筛选状态更换颜色。

## 4. 任务卡片信息

每张卡片都要明确显示任务状态。

示例：

```text
算法作业
待安排 · 预计 50 分钟
```

```text
大物预习课
已安排 · 13:00–14:30
```

```text
竞赛报名
已完成 · 实际投入 25 分钟
```

逾期任务显示：

```text
已逾期 · 待安排 · 截止于 10月6日 23:59
```

约束：

- 卡片颜色仍然来自领域。
- “已逾期”是提醒信息，不是新的筛选类别。
- 项目名称不是状态，不能替代“待安排、已安排、已完成”。

## 5. 搜索、筛选与排序

数据处理顺序必须固定为：

```text
读取全部任务
→ 排除跳过和取消
→ 计算待安排、已安排、已完成
→ 应用当前筛选
→ 执行文字搜索
→ 执行排序
→ 渲染列表
```

筛选项数量必须在文字搜索之前计算。例如，搜索后只显示一个任务，筛选栏仍可显示：

```text
全部 8　待安排 2　已安排 4　已完成 2
```

现有排序功能保留，但只对当前筛选结果排序。

## 6. 多选模式

- “待安排”和“已安排”可以正常进入多选。
- “全部”可以进入多选，但已完成任务不可勾选。
- “已完成”筛选中隐藏“多选”按钮。
- 切换筛选项时必须退出多选模式并清空已选择任务。
- 不得保留当前列表中不可见的选中任务。

## 7. 空状态

不得继续让所有情况统一显示“暂无匹配任务”。

| 场景 | 主文案 | 可选辅助信息或操作 |
| --- | --- | --- |
| 全部为空 | 还没有任务 | 使用现有“新建任务”入口 |
| 待安排为空 | 没有待安排任务 | 当前所有进行中的任务都已经进入计划 |
| 已安排为空 | 没有已安排任务 | 提供“生成计划”按钮 |
| 已完成为空 | 还没有已完成任务 | 无 |
| 搜索无结果 | 没有找到“搜索内容” | 清除搜索条件 |

## 8. 数据层改造

### 8.1 扩展任务仓库

修改：

```text
lib/domain/repositories/task_repository.dart
```

增加：

```dart
Stream<List<PlannerTask>> watchAllTasks();
```

保留原有：

```dart
Stream<List<PlannerTask>> watchOpenTasks();
```

不得改变原方法语义，以免影响其他页面。

### 8.2 DAO 增加全量查询

修改：

```text
lib/data/database/daos/task_dao.dart
```

增加：

```dart
Stream<List<TaskRow>> watchAll();
```

要求：

- DAO 查询不排除 `completed`、`skipped`、`cancelled`。
- 查询排序保持稳定。
- 不修改数据库结构。
- 不创建数据库迁移。

### 8.3 实现仓库与服务接口

修改：

```text
lib/data/repositories/drift_task_repository.dart
lib/application/task_service.dart
```

在 `TaskService` 中暴露：

```dart
Stream<List<PlannerTask>> watchAllTasks();
```

所有实现 `TaskRepository` 的内存仓库和测试替身都必须同步实现该方法，禁止使用 `UnimplementedError` 占位。

## 9. 独立封装筛选逻辑

新建：

```text
lib/features/tasks/task_list_filter.dart
```

建议结构：

```dart
enum TaskListFilter {
  all,
  unscheduled,
  scheduled,
  completed,
}

enum TaskListBucket {
  unscheduled,
  scheduled,
  completed,
  excluded,
}
```

至少提供以下纯函数：

```dart
TaskListBucket classifyTaskForList(
  PlannerTask task, {
  required Set<String> scheduledTaskIds,
});
```

```dart
List<PlannerTask> filterTaskList(
  List<PlannerTask> tasks, {
  required TaskListFilter filter,
  required Set<String> scheduledTaskIds,
  required String query,
  required TaskSort sort,
});
```

不得把分类判断分别散落在多个 Widget 的 `build()` 方法中。

## 10. 读取已安排任务

任务是否已安排，以当前确认计划为唯一依据。

通过 `PlanRepository.current()` 读取计划，只收集满足以下条件的时间块：

```dart
block.endUtc.isAfter(nowUtc)
```

生成：

```dart
Set<String> scheduledTaskIds
```

以下数据不得用于判断“已安排”：

- 历史计划。
- 被替换或废弃的计划版本。
- 已经结束的时间块。
- 任务数据库里旧的 `scheduled` 状态。
- 日历中与任务无关的固定日程和保护时间。

在 `lib/app/router.dart` 中，将现有的 `PlanRepository` 传给 `TaskListPage`，不新建第二套计划服务。

## 11. 任务页改造

修改：

```text
lib/features/tasks/task_list_page.dart
```

为 `TaskListPage` 增加：

```dart
final PlanRepository? plans;
```

页面加载流程：

1. 读取当前确认计划。
2. 生成 `scheduledTaskIds`。
3. 监听 `watchAllTasks()`。
4. 计算三个任务分组及数量。
5. 渲染筛选栏和任务列表。

如果没有 `PlanRepository`：

- 页面仍须正常显示。
- 所有未完成任务临时归入“待安排”。
- 不得崩溃或无限显示加载动画。

如果 `plans` 或 `nowUtc` 发生变化，必须重新计算计划时间块。

## 12. 自动化测试

### 12.1 纯逻辑测试

新建：

```text
test/features/tasks/task_list_filter_test.dart
```

至少覆盖：

1. 普通未完成任务且无计划块，归入待安排。
2. 普通未完成任务且有未来计划块，归入已安排。
3. 只有过去计划块，归入待安排。
4. 已完成任务即使有未来计划块，仍归入已完成。
5. 跳过任务归入 excluded。
6. 取消任务归入 excluded。
7. 逾期任务有未来补排，归入已安排。
8. 逾期任务无未来补排，归入待安排。
9. 进行中任务有有效时间块，归入已安排。
10. 全部数量等于三个可见分组数量之和。

### 12.2 Widget 测试

至少覆盖：

- 默认选择“全部”。
- 四个筛选数量正确。
- 点击筛选后只显示对应任务。
- 搜索和筛选可以组合使用。
- 搜索不会改变筛选栏的原始数量。
- 排序只作用于当前筛选结果。
- 各筛选空状态文案正确。
- 切换筛选会退出多选。
- 已完成页面不显示多选按钮。
- 取消完成后，任务立即从“已完成”中消失。
- `skipped`、`cancelled` 不出现在“全部”。
- 没有计划仓库时页面仍可使用。

### 12.3 回归测试

现有批量操作、任务详情、任务编辑和路由测试必须继续通过。

## 13. 严格验收标准

只有同时满足以下条件才能判定完成：

- 任务页不再因为只读取开放任务而错误显示为空。
- “全部、待安排、已安排、已完成”均可正常切换。
- 筛选数量准确，并满足加和关系。
- 当前计划中的未来任务正确归入“已安排”。
- 已经过期的计划块不会让任务继续显示为“已安排”。
- 已完成任务可以查看并恢复。
- 取消和跳过的数据没有被删除。
- 今日页、日历页和排程算法行为没有变化。
- 没有新增数据库迁移。
- 没有把固定日程或保护时间混入任务列表。
- 所有自动化测试通过。
- Windows Release 构建成功。
- 按 `版本号规则.md` 更新版本号、构建台账和用户说明。
- 生成对应版本的 Windows 安装包，并实际安装启动一次。

## 14. 验证命令

在工作树中执行：

```powershell
Set-Location 'G:\best-planing\.worktrees\native-implementation'

& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/features/tasks/task_list_filter_test.dart

& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test test/features/tasks/task_list_batch_test.dart

& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' test

& 'G:\best-planing\.tooling\flutter-bundle\flutter\bin\flutter.bat' analyze
```

任意一项失败，都不能标记任务完成。不得通过删除断言、跳过测试或放宽正确性条件来掩盖问题。

## 15. 实施顺序

1. 先补充筛选纯逻辑测试，并确认测试失败。
2. 实现 `task_list_filter.dart`，使纯逻辑测试通过。
3. 增加 DAO、Repository 和 Service 的全量任务监听。
4. 同步更新全部内存仓库和测试替身。
5. 为任务页注入 `PlanRepository`。
6. 实现筛选栏、数量、状态标签和空状态。
7. 完成多选模式限制与完成任务恢复行为。
8. 补齐 Widget 测试和路由测试。
9. 运行完整测试与静态分析。
10. 按版本规则更新发布资料。
11. 构建 Windows Release 和安装包。
12. 在全新安装或升级安装环境中完成一次人工验收。

## 16. 禁止偏离项

执行过程中不得：

- 顺带重写任务页面整体视觉设计。
- 修改任务排程算法。
- 修改今日页或日历页的领域颜色规则。
- 将固定日程、课程或保护时间写入任务表。
- 为了筛选功能新增数据库状态字段。
- 把“是否已安排”永久写回任务状态。
- 删除取消或跳过的历史任务。
- 在测试未通过时生成正式安装包并宣称完成。

## 17. 核心设计结论

任务自身的持久化状态负责判断“已完成”；当前确认计划中的有效时间块负责判断“已安排”；其余有效任务归入“待安排”。状态只在展示时组合计算，不新增重复的数据事实来源。
