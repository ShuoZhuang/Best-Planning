// 任务清单的**筛选、排序与状态文案口径**，全部是纯函数。
//
// 为什么单独成文件：`待安排／已安排／已完成` 的分组依据来自两个不同的地方——
// **任务自身的持久化状态**（完成与否）与**当前确认计划里的有效时间块**（是否已安排）。
// 把这段判断写进 Widget 的 `build()` 会立刻分裂成两三份彼此略有不同的副本，
// 而"数量加和关系"、"筛选后排序"与"卡片上的时间区间"这类约束恰恰要求只有一份口径。
//
// 本文件不认识 Flutter，也不认识数据库：输入是任务列表加一份"当前计划里尚未结束的块"，
// 输出是分组结果与文案片段。这样它可以被纯单元测试钉住，而不必先搭起界面。
import 'package:personal_planner/domain/models/task.dart';

/// 任务页顶部可选的四个筛选项（需求 §1）。
enum TaskListFilter {
  all,
  unscheduled,
  scheduled,
  completed;

  /// 该筛选项计入"可见总数"的分组集合。
  ///
  /// `all` 是另外三类的并集（§2.5），因此它不是第四类，而是"三个分组都要"。
  Set<TaskListBucket> get buckets => switch (this) {
    TaskListFilter.all => const {
      TaskListBucket.unscheduled,
      TaskListBucket.scheduled,
      TaskListBucket.completed,
    },
    TaskListFilter.unscheduled => const {TaskListBucket.unscheduled},
    TaskListFilter.scheduled => const {TaskListBucket.scheduled},
    TaskListFilter.completed => const {TaskListBucket.completed},
  };
}

/// 一个任务在清单口径下所属的分组。
///
/// `excluded` 不是第四个筛选项，而是**落选**：跳过与取消的任务既不算完成，
/// 也不算待安排——它们的数据必须保留，但不出现在这四个筛选中（§2.4）。
enum TaskListBucket { unscheduled, scheduled, completed, excluded }

/// 清单的排序方式（FR-TASK-03 要求支持排序）。
///
/// `none` 表示**保持仓储给出的顺序**（即录入顺序）：排序是用户显式选择的结果，
/// 不该在用户没要求时改变他熟悉的顺序。
enum TaskSort { none, dueDate, priority, estimatedMinutes }

/// 当前确认计划里**尚未结束**的时间块，按任务归并后的视图。
///
/// **为什么不是 `Set<String>`**：清单卡片要写出"已安排 · 13:00–14:30"（§4），
/// 因此除了"这个任务有没有块"还需要"块在什么时候"。若为此再读一遍计划，就等于给
/// 同一个事实建了第二个来源——撤销、重排或换版本时两者必然有一个滞后。
///
/// 一个任务可能有多个片段（§2.2 明确把"拆分成多个片段"算作已安排），取**最早开始的
/// 那个未结束块**作为代表：用户此刻最该知道的是"接下来什么时候做它"。
final class TaskScheduleWindow {
  TaskScheduleWindow(this._windows);

  /// 从**当前确认计划**的块生成（§10）。
  ///
  /// 只保留 `endUtc.isAfter(nowUtc)` 的块：正在进行的块（结束时间在未来）算，
  /// 已经结束的块不算。以下数据**都不得**参与：历史计划、被替换或废弃的版本、
  /// 已经结束的块、任务表里旧的 `scheduled` 状态、日历里的固定日程与保护时间。
  /// 因此本构造函数刻意只收 `(taskId, startUtc, endUtc)`——调用方无法顺手把别的数据塞进来。
  factory TaskScheduleWindow.fromBlocks(
    Iterable<({String taskId, DateTime startUtc, DateTime endUtc})> blocks, {
    required DateTime nowUtc,
  }) {
    final byTask = <String, ({DateTime startUtc, DateTime endUtc})>{};
    for (final block in blocks) {
      if (!block.endUtc.isAfter(nowUtc)) continue;
      // 起止颠倒的块不参与：否则"取最早开始的块"会被一个非法区间劫持，
      // 卡片上就会出现一个起点在终点之后的时间区间。
      if (!block.endUtc.isAfter(block.startUtc)) continue;
      final current = byTask[block.taskId];
      if (current == null || block.startUtc.isBefore(current.startUtc)) {
        byTask[block.taskId] = (startUtc: block.startUtc, endUtc: block.endUtc);
      }
    }
    return TaskScheduleWindow(byTask);
  }

  /// 没有计划仓库时用它：所有任务都没有时间块，于是未完成的一律归入"待安排"（§11）。
  factory TaskScheduleWindow.empty() => TaskScheduleWindow(const {});

  final Map<String, ({DateTime startUtc, DateTime endUtc})> _windows;

  Set<String> get taskIds => _windows.keys.toSet();

  ({DateTime startUtc, DateTime endUtc})? windowFor(String taskId) =>
      _windows[taskId];
}

/// 判断一个任务在清单里属于哪一组。
///
/// 口径（§2.1–§2.4）：
/// 1. **已完成优先**：`status == completed` 就是已完成，**即使还残留未来时间块**
///    ——否则"勾完了但块没清掉"的任务会在筛选里同时像两种状态；
/// 2. 跳过与取消落选（`excluded`），数据保留但不出现在筛选中；
/// 3. 其余任务看**当前确认计划**里是否有**尚未结束**的时间块：有则已安排，
///    没有则待安排。已经过去的时间块不算——"安排过了"不等于"还安排着"；
/// 4. 逾期、进行中等派生状态**不参与**这里的判断：逾期只是提醒信息（§4），
///    进行中但没有任何有效时间块的任务反而是待安排（§2.3）。
TaskListBucket classifyTaskForList(
  PlannerTask task, {
  required TaskScheduleWindow schedule,
}) {
  if (task.status == TaskStatus.completed) return TaskListBucket.completed;
  if (task.status.isClosed) return TaskListBucket.excluded;
  return schedule.windowFor(task.id) != null
      ? TaskListBucket.scheduled
      : TaskListBucket.unscheduled;
}

/// 按四个筛选项统计数量（§3 的筛选栏数字）。
///
/// 分布固定含四条，顺序与 [TaskListFilter.values] 一致，因此界面可以直接按序遍历。
Map<TaskListFilter, int> countTaskListBuckets(
  List<PlannerTask> tasks, {
  required TaskScheduleWindow schedule,
}) {
  final counts = {for (final filter in TaskListFilter.values) filter: 0};
  for (final task in tasks) {
    final bucket = classifyTaskForList(task, schedule: schedule);
    if (bucket == TaskListBucket.excluded) continue;
    // 落选的任务不进任何一栏；其余任务各进恰好一类，
    // 因此"全部 = 待安排 + 已安排 + 已完成"这条加和关系天然成立（§2.5）。
    counts[TaskListFilter.all] = counts[TaskListFilter.all]! + 1;
    counts[_filterOf(bucket)] = counts[_filterOf(bucket)]! + 1;
  }
  return counts;
}

/// 任务列表的**完整处理流水线**，顺序固定为（§5）：
///
/// ```text
/// 读取全部任务 → 排除跳过和取消 → 计算三个分组 → 应用当前筛选
/// → 执行文字搜索 → 执行排序 → 渲染列表
/// ```
///
/// 排序只作用于**当前筛选结果**，搜索也不会改变筛选栏的数量——数量由
/// [countTaskListBuckets] 在搜索之前单独算出。
List<PlannerTask> filterTaskList(
  List<PlannerTask> tasks, {
  required TaskListFilter filter,
  required TaskScheduleWindow schedule,
  required String query,
  required TaskSort sort,
}) {
  final buckets = filter.buckets;
  final visible = <PlannerTask>[
    for (final task in tasks)
      if (buckets.contains(classifyTaskForList(task, schedule: schedule))) task,
  ];

  final needle = query.trim().toLowerCase();
  final matched = needle.isEmpty
      ? visible
      : [
          for (final task in visible)
            if (task.title.toLowerCase().contains(needle)) task,
        ];

  // 只有用户真的选了排序才调用 `sort`：Dart 的 `List.sort` **不保证稳定**，
  // 用"全部返回 0"的比较器去"保持原顺序"是不可靠的，因此默认顺序干脆不排。
  if (sort == TaskSort.none) return matched;
  final sorted = List.of(matched);
  sorted.sort((a, b) => compareTasksForList(a, b, sort: sort));
  return sorted;
}

/// 清单排序的比较器。抽成公开函数是为了让"排序只作用于当前筛选结果"这条约束
/// 能用纯逻辑测试钉住，而不必依赖 Widget 的坐标断言。
int compareTasksForList(
  PlannerTask a,
  PlannerTask b, {
  required TaskSort sort,
}) => switch (sort) {
  TaskSort.none => 0,
  // 没有截止时间的排最后：它们不是"最早到期"，但也不该因为缺少字段而挤到最前。
  TaskSort.dueDate => _dueKey(a).compareTo(_dueKey(b)),
  // 高优先级在前：枚举顺序是 low→urgent，因此取反。
  TaskSort.priority => b.priority.index.compareTo(a.priority.index),
  TaskSort.estimatedMinutes => a.estimatedMinutes.compareTo(b.estimatedMinutes),
};

/// 卡片副标题里的**状态片段**（§4）：`待安排`／`已安排`／`已完成`。
///
/// 项目名称不是状态，不能替代这三个词；"已逾期"只是提醒，因此不在这个函数里。
String taskStatusLabelForList(
  PlannerTask task, {
  required TaskScheduleWindow schedule,
}) => switch (classifyTaskForList(task, schedule: schedule)) {
  TaskListBucket.unscheduled => '待安排',
  TaskListBucket.scheduled => '已安排',
  TaskListBucket.completed => '已完成',
  // 落选项不在四个筛选里，也没有"落选"这种说法；沿用其持久化状态名，
  // 以免将来单独开"归档任务"入口时又出现第二套口径。
  TaskListBucket.excluded => task.status.name,
};

/// 卡片副标题里的**详情片段**：时长、时间区间或实际投入。
///
/// 1. 已安排且**有块**：给出时间区间（`13:00–14:30`），这是用户最需要的信息；
/// 2. 已完成：给出实际投入（预计时长 − 剩余时长，钳到不小于 0）；
/// 3. 其余（含"已安排但块的信息缺失"这种只可能出现在调用方手拼数据里的情况）：
///    退回预计时长，绝不显示一个空的区间。
String taskDetailLabelForList(
  PlannerTask task, {
  required TaskScheduleWindow schedule,
  required String Function(DateTime startUtc, DateTime endUtc) formatRange,
}) {
  final window = schedule.windowFor(task.id);
  if (window != null && task.status != TaskStatus.completed) {
    return formatRange(window.startUtc, window.endUtc);
  }
  if (task.status == TaskStatus.completed) {
    final spent = task.estimatedMinutes - task.remainingMinutes;
    return '实际投入 ${spent < 0 ? 0 : spent} 分钟';
  }
  return '预计 ${task.estimatedMinutes} 分钟';
}

/// 卡片副标题的**完整文案**，例如：
///
/// ```text
/// 待安排 · 预计 50 分钟
/// 已安排 · 13:00–14:30
/// 已完成 · 实际投入 25 分钟
/// 已逾期 · 待安排 · 截止于 10月6日 23:59
/// ```
String taskListSubtitle(
  PlannerTask task, {
  required TaskScheduleWindow schedule,
  required DateTime nowUtc,
  required String Function(DateTime startUtc, DateTime endUtc) formatRange,
  required String Function(DateTime dueAtUtc) formatDue,
}) {
  final parts = <String>[];
  // 逾期是提醒信息而不是筛选类别（§4）：它排在最前，后面仍然是真实的分组。
  if (task.statusAt(nowUtc: nowUtc) == TaskStatus.overdue) {
    parts.add('已逾期');
  }
  parts.add(taskStatusLabelForList(task, schedule: schedule));
  parts.add(
    taskDetailLabelForList(task, schedule: schedule, formatRange: formatRange),
  );
  final due = task.dueAtUtc;
  if (due != null && task.statusAt(nowUtc: nowUtc) == TaskStatus.overdue) {
    parts.add('截止于 ${formatDue(due)}');
  }
  return parts.join(' · ');
}

DateTime _dueKey(PlannerTask task) => task.dueAtUtc ?? DateTime.utc(9999);

TaskListFilter _filterOf(TaskListBucket bucket) => switch (bucket) {
  TaskListBucket.unscheduled => TaskListFilter.unscheduled,
  TaskListBucket.scheduled => TaskListFilter.scheduled,
  TaskListBucket.completed => TaskListFilter.completed,
  // 调用方已排除落选项；给出兜底仅为了让 switch 穷尽，不改变任何可达行为。
  TaskListBucket.excluded => TaskListFilter.all,
};
