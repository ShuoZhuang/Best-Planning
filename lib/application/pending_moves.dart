import 'dart:collection';

/// 用户**手动拖动**一个已确认计划块所产生的"这次要把它放到哪一天"的意图（FR-CAL-05）。
///
/// **为什么需要它**：周视图的拖动此前在生产里是死的——`planner_app.dart` 注入的是
/// `DisabledWeekMoveController`，而 `MoveDraftSink` **全库没有任何实现**。因此
/// `PlanningServiceWeekMoveController` 那条路径永远走不到，"拖动可移动任务块"在真实
/// 用户路径上等于不存在。这个类是那条路径缺的第一环：**把拖动落成一个可读的意图**，
/// 由 `RepositoryScheduleProblemSource` 在装配排程输入时消费。
///
/// **粒度是"块"而不是"任务"**：拖动交回的是被拖的那个块，因此同一个任务的两个片段可以
/// 分别放到不同天。这与 `ScheduleProblem` 的任务级模型并不冲突——意图按块记录，装配时
/// 按块钉住。
///
/// **只记本地日期，不记具体时刻**：周视图的拖放目标是一整列（一天），不是某个钟点。
/// 具体时刻由装配层按"保留原来的本地钟点"决定（见 `RepositoryScheduleProblemSource`），
/// 这样"把周三 14:00 的那块拖到周五"落成"周五 14:00"，与用户看到的位移一致。
final class RequestedMove {
  const RequestedMove({
    required this.blockId,
    required this.localDate,
    required this.lock,
  });

  /// 被拖动的**已确认计划块**的 id（`schedule_blocks.id`），不是任务 id。
  final String blockId;

  /// 目标**本地日期**（只用到年月日）。刻意不是 UTC 时刻——"哪一天"是用户看到的概念。
  final DateTime localDate;

  /// 落地后是否锁定（FR-CAL-05 的"手动移动后可选择锁定"）。
  ///
  /// 两个分支的差别是**真实的、可观察的**：锁定后该块进入 `lockedBlocks`，后续自动调整
  /// 一律不得移动它；不锁定时该块在**本次**生成中仍被钉在目标位置（否则这次拖动会当场被
  /// 引擎搬回去，用户看到的就是"拖了没用"），但**落地为未锁定**，因此后续重排可以再移动它。
  final bool lock;
}

/// 周视图拖动的**落点**：把"把某一块移到某一天、是否锁定"记下来。
///
/// **端口为什么在 application 而不是 features**：实现方是 [PendingMoveDrafts]（应用层的
/// 内存态意图），而消费方是 `RepositoryScheduleProblemSource`（装配排程输入）。若把端口留在
/// `features/`，应用层就得反过来 import 界面层。因此端口按**原始输入**（块 id、本地日期、
/// 是否锁定）声明，不认识 `ScheduleViewItem`——由界面侧的控制器把视图条目翻译成它。
///
/// 此前这个端口只有声明、**全库没有任何实现**，而 `planner_app.dart` 注入的是
/// `DisabledWeekMoveController`，于是 `PlanningServiceWeekMoveController` 那条路径永远走不到
/// ——FR-CAL-05 的拖动在真实用户路径上等于不存在。
abstract interface class MoveDraftSink {
  void setRequestedMove(RequestedMove move);
}

/// 内存态的"待处理手动移动"集合。
///
/// **为什么不落库**：拖动之后**立刻**就会生成提案、进入预览，意图只在这一次"拖动 → 生成 →
/// 确认"里有效；为此开一张表要付一次 schema 迁移，而收益只是"重启后还记得一次没确认的
/// 拖动"。放在内存里与既有 `MemoryAutoAdjustStore` 同一取舍。
///
/// **不需要显式清理**：落地时计划块的 id 会被重写成 `<提案 id>:<块 id>`
/// （`drift_plan_repository.dart` 的 `applyProposal`），因此旧 id 再也匹配不上任何已确认
/// 块，这条意图**自动失效**。这一点由用例钉住（见
/// `test/application/pending_moves_test.dart`），否则"拖动一次就被永久钉住"会是个静默缺陷。
final class PendingMoveDrafts implements MoveDraftSink {
  final Map<String, RequestedMove> _byBlock = {};

  /// 记录一次拖动。同一个块被反复拖动时**后一次覆盖前一次**（用户的最后一次意图才算数）。
  @override
  void setRequestedMove(RequestedMove move) =>
      _byBlock[move.blockId] = move;

  /// 取出某个块待处理的移动；没有则返回 `null`。
  RequestedMove? forBlock(String blockId) => _byBlock[blockId];

  /// 当前全部待处理移动（只读视图）。
  List<RequestedMove> get all => UnmodifiableListView(_byBlock.values.toList());

  int get length => _byBlock.length;

  void clear() => _byBlock.clear();
}
