import 'dart:collection';

import 'package:personal_planner/core/time_zone.dart';

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
/// 两种来源共用同一个意图：周视图拖放只记目标本地日期，并保留原钟点；
/// 今日页「延后本次」记精确 UTC 时刻。两者都是块级别的一次性移动。
final class RequestedMove {
  const RequestedMove({
    required this.blockId,
    required this.localDate,
    required this.lock,
  }) : targetStartUtc = null;

  /// 把计划块移到一个精确时刻。
  ///
  /// 今日页的「延后本次」用这条路径：它表达的是当前块的一次性位移，
  /// 不修改任务的截止时间或最早开始时间。[targetStartUtc] 必须是 UTC，与
  /// `PlannedBlock.range` 使用同一时间口径。
  RequestedMove.atInstant({
    required this.blockId,
    required DateTime targetStartUtc,
    required this.lock,
  }) : assert(targetStartUtc.isUtc),
       localDate = null,
       targetStartUtc = targetStartUtc;

  /// 被拖动的**已确认计划块**的 id（`schedule_blocks.id`），不是任务 id。
  final String blockId;

  /// 目标**本地日期**（只用到年月日）。刻意不是 UTC 时刻——"哪一天"是用户看到的概念。
  final DateTime? localDate;

  /// 精确目标时刻；与 [localDate] 二选一。
  final DateTime? targetStartUtc;

  /// 落地后是否锁定（FR-CAL-05 的"手动移动后可选择锁定"）。
  ///
  /// 两个分支的差别是**真实的、可观察的**：锁定后该块进入 `lockedBlocks`，后续自动调整
  /// 一律不得移动它；不锁定时该块在**本次**生成中仍被钉在目标位置（否则这次拖动会当场被
  /// 引擎搬回去，用户看到的就是"拖了没用"），但**落地为未锁定**，因此后续重排可以再移动它。
  final bool lock;
}

/// 手动移动计划块的**落点**：记住目标日期或精确时刻，以及是否锁定。
///
/// **端口为什么在 application 而不是 features**：实现方是 [PendingMoveDrafts]（应用层的
/// 内存态意图），而消费方是 `RepositoryScheduleProblemSource`（装配排程输入）。若把端口留在
/// `features/`，应用层就得反过来 import 界面层。因此端口按**原始输入**声明，
/// 不认识 `ScheduleViewItem`——由界面侧把视图条目翻译成它。
///
/// 此前这个端口只有声明、**全库没有任何实现**，而 `planner_app.dart` 注入的是
/// `DisabledWeekMoveController`，于是 `PlanningServiceWeekMoveController` 那条路径永远走不到
/// ——FR-CAL-05 的拖动在真实用户路径上等于不存在。
abstract interface class MoveDraftSink {
  void setRequestedMove(RequestedMove move);
}

/// 延后的单位（1.8.0，设计规范 §11.1）。
///
/// **分钟与小时按"经过时长"算，天按"本地日历日"算**——这是规范 §11.2 的分界线，
/// 也是"延后 1 天遇 DST 保持本地钟点"能成立的前提。
enum DeferUnit { minutes, hours, days }

/// 一次**块级延后请求**（规范 §11.3）。
///
/// **与 `RequestedMove` 的分工**：那个表达"把这一块放到某一天／某个精确时刻"，是拖动的
/// 语义；这个表达"把这一块往后推 N 分钟／小时／天"，是延后的语义。延后此前被实现成
/// **精确锁定点**（`RequestedMove.atInstant` ＋ `RepositoryScheduleProblemSource` 里的
/// `locked: true`），于是目标点一旦被固定日程、保护时间或另一个锁定块占用，方案直接失败
/// （规范 §2.5）。
final class DeferPlanBlockRequest {
  const DeferPlanBlockRequest({
    required this.blockId,
    required this.amount,
    required this.unit,
    required this.sourceStartUtc,
    required this.timeZoneId,
  }) : assert(amount > 0, '延后只允许正数；提前是独立操作（规范 §11.2）');

  /// 被延后的**已确认计划块** id。
  final String blockId;

  /// 延后量，恒为正。
  final int amount;
  final DeferUnit unit;

  /// 这次延后的参照起点：块的**原始开始时刻**。
  ///
  /// **必须是原始时刻而不是"现在"**：用户点的是"把这一块往后推 30 分钟"，
  /// 参照系是这一块自己，不是他点按钮的那一刻。
  final DateTime sourceStartUtc;

  /// 事项自己的 IANA 时区。**只有 `days` 用得上**（本地日历日计算），
  /// 但三个单位都带上它，避免调用方按单位分支去决定传不传。
  final String timeZoneId;
}

/// 把一次延后请求换算成**下界** `notBeforeUtc`（规范 §11.2）。
///
/// - `minutes` / `hours`：从原开始时刻加**经过时长**；
/// - `days`：在事项时区里加**本地日历日**并保留本地钟点，再换回 UTC。
///   **不能简单加 24 小时**：夏令时切换日那一天的本地长度不是 24 小时，
///   加 24 小时会让本地钟点漂一小时（"延后 1 天"变成"延后 1 天零 1 小时"）。
///
/// 返回的是**下界**，不是必须占用的点：目标被占用时排程器去找它之后最近的合法时段
/// （规范 §11.2 最后两条）。
DateTime deferNotBeforeUtc({
  required DateTime sourceStartUtc,
  required int amount,
  required DeferUnit unit,
  required String timeZoneId,
  required TimeZoneDatabase zones,
}) {
  if (amount <= 0) {
    throw ArgumentError.value(amount, 'amount', '延后只允许正数');
  }
  if (!sourceStartUtc.isUtc) {
    throw ArgumentError.value(sourceStartUtc, 'sourceStartUtc', 'Must be UTC.');
  }
  switch (unit) {
    case DeferUnit.minutes:
      return sourceStartUtc.add(Duration(minutes: amount));
    case DeferUnit.hours:
      return sourceStartUtc.add(Duration(hours: amount));
    case DeferUnit.days:
      final local = zones.toLocal(sourceStartUtc, timeZoneId);
      return zones.localDateTimeToUtc(
        DateTime(local.year, local.month, local.day + amount),
        local.hour * 60 + local.minute,
        timeZoneId,
      );
  }
}

/// 一次**调整请求**：把块级意图绑成"这一个 proposal 专属"的一次性输入
/// （规范 §11.3 与全局不变量第 4 条）。
///
/// **它为什么必须是一个显式的对象**：全局 `PendingMoveDrafts` 的语义是"等着下一次生成来
/// 消费"，于是生成失败或用户取消之后那条意图**还留在内存里**，下一次普通"生成计划"会把
/// 一次已经作废的调整又应用一遍——规范第 4 条明确禁止这件事。
///
/// 这个对象由 [PendingMoveDrafts.beginAdjustment] 建立、由生成路径在 `finally` 里销毁
/// （[PendingMoveDrafts.endAdjustment]），因此它**不可能跨过两次生成**。
final class PlanAdjustmentRequest {
  PlanAdjustmentRequest({
    required this.blockId,
    required this.amount,
    required this.unit,
    required this.sourceStartUtc,
    required this.timeZoneId,
  }) : blocks = [
         DeferPlanBlockRequest(
           blockId: blockId,
           amount: amount,
           unit: unit,
           sourceStartUtc: sourceStartUtc,
           timeZoneId: timeZoneId,
         ),
       ];

  /// 这次调整绑定的块。目前只有延后一种，因此只有一项；结构上留成列表，是因为规范 §11.4
  /// 的级联可能带上"被连带移动的块"。
  final List<DeferPlanBlockRequest> blocks;

  final String blockId;
  final int amount;
  final DeferUnit unit;
  final DateTime sourceStartUtc;
  final String timeZoneId;

  /// 这个块的延后**下界**。目标被占用时排程器找它之后的最近合法时段。
  DateTime notBeforeUtc(TimeZoneDatabase zones) => deferNotBeforeUtc(
    sourceStartUtc: sourceStartUtc,
    amount: amount,
    unit: unit,
    timeZoneId: timeZoneId,
    zones: zones,
  );
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
/// `test/application/requested_move_test.dart`），否则"移动一次就被永久钉住"会是个静默缺陷。
final class PendingMoveDrafts implements MoveDraftSink {
  final Map<String, RequestedMove> _byBlock = {};

  /// 记录一次拖动。同一个块被反复拖动时**后一次覆盖前一次**（用户的最后一次意图才算数）。
  @override
  void setRequestedMove(RequestedMove move) => _byBlock[move.blockId] = move;

  /// 取出某个块待处理的移动；没有则返回 `null`。
  RequestedMove? forBlock(String blockId) => _byBlock[blockId];

  /// 当前的调整请求（延后专用）。没有进行中的调整时为 `null`。
  PlanAdjustmentRequest? get adjustment => _adjustment;

  /// 取出某个块的调整下界。**只有延后请求存在时才有值**。
  ///
  /// 排程输入装配层用它把"精确锁定点"换成"下界"：请求里的目标时间从
  /// `notBeforeUtc` 变成"这一块最早可以开始的位置"，目标被占用时引擎可以往后找。
  DateTime? notBeforeForBlock(String blockId, TimeZoneDatabase zones) {
    final request = _adjustment;
    if (request == null || request.blockId != blockId) return null;
    return request.notBeforeUtc(zones);
  }

  /// 开始一次调整，并**清掉同一块上可能残留的普通移动意图**。
  ///
  /// 两种意图作用在同一个块上时，后发起的那一个才算数——沿用同一个块被反复拖动时
  /// "后一次覆盖前一次"的约定。
  void beginAdjustment(PlanAdjustmentRequest request) {
    _adjustment = request;
    _byBlock.remove(request.blockId);
  }

  /// 结束当前调整（生成路径在 `finally` 里调用）。
  ///
  /// **四种结束路径共用它**：生成失败、用户取消预览、应用成功、应用失败。
  /// 把它们收成一个方法，是为了让"请求不能跨过两次生成"这条不变量只有一个执行点
  /// （规范 §11.3 最后一段）。
  void endAdjustment() => _adjustment = null;

  PlanAdjustmentRequest? _adjustment;

  /// 当前全部待处理移动（只读视图）。
  List<RequestedMove> get all => UnmodifiableListView(_byBlock.values.toList());

  int get length => _byBlock.length;

  void clear() => _byBlock.clear();
}
