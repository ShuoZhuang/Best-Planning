import 'dart:async';

import 'package:personal_planner/application/replanning_coordinator.dart'
    show ScheduleInputChange;

/// 一次"日历展示数据已经失效"属于哪一类变化（计划 §2.6）。
///
/// **为什么要有类别而不是一个无参 `notify()`**：`RepositoryScheduleViewSource` 目前对每一类
/// 都执行同一次完整重载，但"谁改了什么"是排查"界面没刷"时唯一可用的线索——把类别丢掉，
/// 日志里只剩一句"刷新了一次"，而看不出是哪条写入路径漏了通知。
/// 它同时是装配检查的锚点：每个写入点发哪一类由 §2.6 逐条固定，不接受实现者临场选择。
enum ScheduleViewChangeKind {
  /// 固定日程／保护时间／课程被写入（`calendar_events` 变了）。
  calendar,

  /// 已确认计划被应用或撤销（`schedule_blocks` 变了）。
  plan,

  /// 任务本身变了。**生产路径上不由写入方发送**：任务展示刷新由
  /// `TaskRepository.watchAllTasks()` 驱动（见 §2.6 的装配规则），这里保留该值是为了
  /// 让类别集合与计划一致，避免将来补发时再造一个枚举。
  task,

  /// 规划规则（作息、保护时间规则、按日例外）被保存。
  planningRules,

  /// 日程配色被保存。
  colors,

  /// 领域（日历分类的名称与颜色）被写入。
  workspace,
}

/// 日历展示数据的失效信号端口（计划 §2.6）。
///
/// **它只发信号，不携带数据**：所有展示数据仍由 `RepositoryScheduleViewSource` 从仓储
/// 重新读取。把"变了"与"变成了什么"分开，才不会出现"某条写入路径自己拼一份列表推给页面"
/// 这种第二份真相。
abstract interface class ScheduleViewInvalidation {
  /// 单调递增的失效修订号流（broadcast）。
  ///
  /// 订阅者拿到的是**修订号**而不是变化类别：它只需要知道"比上次新"，因此重复的类别、
  /// 合并掉的多次变化都不会让它少刷一次。
  Stream<int> get revisions;

  /// 报告一次成功写入导致的失效。
  ///
  /// **只在事务／写入成功之后调用**：失败、取消与 stale 都必须零信号（§2.6 最后一段）。
  void notify(ScheduleViewChangeKind kind);
}

/// 应用内**唯一**的失效总线（app-scoped）。
///
/// 组合根创建它，同时交给 `RepositoryScheduleViewSource` 与各写入服务；应用销毁时由
/// 组合根释放一次（[dispose] 幂等）。**不允许每个页面各建一套**：那样"某条写入路径忘了
/// 通知"会表现为"只有一个页面没刷新"，而多套总线正好把这个缺陷藏起来。
final class ScheduleViewInvalidationBus implements ScheduleViewInvalidation {
  ScheduleViewInvalidationBus();

  /// **broadcast**：今日页、近期日历与日视图各自持有一个订阅，`watch()` 也是每页一份。
  /// 单订阅控制器会让第二个页面直接抛"Stream has already been listened to"。
  final StreamController<int> _controller = StreamController<int>.broadcast();

  /// **从 0 开始，第一次 `notify` 得到 1**（计划 §2.6：revision 从 1 开始单调递增）。
  /// 因此 `revisions` 上不会出现 0，订阅者也不必把 0 当成"尚未加载"。
  int _revision = 0;

  bool _disposed = false;

  @override
  Stream<int> get revisions => _controller.stream;

  @override
  void notify(ScheduleViewChangeKind kind) {
    // **dispose 之后的 notify 安全忽略**（§2.6）：应用关闭时那几条在途写入仍可能回来，
    // 而此时 controller 已经关闭——直接 `add` 会抛 `StateError`，成为一条无人处理的
    // 未捕获异常。丢掉一个已经没有订阅者的修订号没有任何代价。
    if (_disposed) return;
    _revision += 1;
    // broadcast 控制器在**没有监听者**时 `add` 不抛错（事件被直接丢弃）。这正是要的语义：
    // 启动阶段"补齐默认领域"之类的写入发生在任何页面订阅之前，不该因此报错。
    _controller.add(_revision);
  }

  /// 释放总线。**幂等**：重复调用不会抛错（应用关闭路径上可能被调用不止一次）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}

/// 组合根把**同一个**总线接到各写入服务时用的那一组回调（计划 §2.6）。
///
/// **为什么要把它们收在一处**：§2.6 给每个写入点规定了"发哪一类、在什么时机发"，
/// 而六处各自内联一个 lambda 时，"哪一处忘了装"只能靠人去数。收进一个类之后，
/// 组合根只写 `invalidation.colors` 这样的名字，测试也能对着**同一份代码**
/// 断言"六个写入点全部有接线，而且都发在这一条总线上"——而不是另写一份形状相似的
/// 测试夹具来证明测试夹具是对的。
///
/// 两条时序规则在这里成文（§2.6 的装配规则）：
/// - [calendarAfter]：**先**完成既有的重排记录，**再**发 `calendar`；重排记录抛错时
///   仍然发——那时数据已经落库（`CalendarService` 会返回 `savedWithWarning`），
///   页面必须读回真实结果。
/// - [planAfter]：**先**完成既有的提醒同步，**再**发 `plan`；同步失败时仍然发——
///   计划已经提交，"假装它没写入"是更坏的结果。
final class ScheduleViewInvalidationWiring {
  ScheduleViewInvalidationWiring(this.bus);

  final ScheduleViewInvalidation bus;

  /// `CalendarService.onScheduleInputChanged` 的生产形状。
  ///
  /// [report] 就是组合根里那份"记一条统计原因并触发重排"的实现——它必须**恰好调用一次**，
  /// 因此这里不做任何缓存或去重。
  void Function(ScheduleInputChange change) calendarAfter(
    void Function(ScheduleInputChange change) report,
  ) => (change) {
    try {
      report(change);
    } finally {
      bus.notify(ScheduleViewChangeKind.calendar);
    }
  };

  /// 经过 `CalendarService` **之外**的成功日历写入：课程的事务性保存／删除。
  void Function() get calendar =>
      () => bus.notify(ScheduleViewChangeKind.calendar);

  /// 规划规则（作息、保护时间规则、按日例外）保存成功。
  void Function() get planningRules =>
      () => bus.notify(ScheduleViewChangeKind.planningRules);

  /// 日程配色保存成功。
  void Function() get colors =>
      () => bus.notify(ScheduleViewChangeKind.colors);

  /// 领域的名称／颜色（＝日历分类的名称／颜色）写入成功。
  void Function() get workspace =>
      () => bus.notify(ScheduleViewChangeKind.workspace);

  /// `PlanApplicationService.onPlanChanged` 与 `PlanUndoService.onPlanChanged`
  /// 的生产形状。[sync] 是既有的"提醒重新同步"实现，两处共用同一个回调。
  Future<void> Function() planAfter(Future<void> Function() sync) => () async {
    try {
      await sync();
    } finally {
      bus.notify(ScheduleViewChangeKind.plan);
    }
  };
}
