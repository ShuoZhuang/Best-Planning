import 'dart:collection';

/// 用户点「**跳过本次**」所产生的意图（2026-10-07 用户定义）。
///
/// **语义（用户原话的要点）**：只放弃**当前这一个时间块**，任务本身**仍然是未完成待办**、
/// 剩余时长不变（已专注的部分由既有的专注重算扣减，不在这里重算），并**继续参与重排**——
/// 由引擎在截止时间前自己找下一个合理空档。新时间可能是今天稍后、明天或其他日期，
/// **不是"顺延到明天"**。
///
/// **三个动作必须分开，不得互相代替**：
/// - `跳过本次`（本类）：只放弃当前块，任务继续存在并参与重排；
/// - `延后到明天`：用户**明确要求**明天再做，改的是 `availableFromUtc`（另一个动作，未实现）；
/// - `取消任务`：整个任务不再需要完成，改的是 `TaskStatus.cancelled`（另一个动作，未实现）。
/// 因此本类**只记块 id**，不碰截止时间、也不碰任务状态。
///
/// **粒度是"块"而不是"任务"**：用户点的是时间线上的某一个块。同一任务今天有两段时，
/// 跳过一段不应把两段都丢掉——这与 `RequestedMove` 同一取舍。
///
/// **为什么不落库**：与 [PendingMoveDrafts] 同一套理由——意图只在"点跳过 → 生成 → 确认"
/// 这一次里有效。落地时计划块的 id 会被重写成 `<提案 id>:<块 id>`
/// （见 `drift_plan_repository.dart` 的 `applyProposal`），旧 id 再也匹配不上任何已确认块，
/// 这条意图**自动失效**。为此开一张表要付一次 schema 迁移，而收益只是"重启后还记得一次
/// 没确认的跳过"。若用户取消预览，意图留在内存里，下次生成仍会跳过该块——这是合理的，
/// 因为用户并没有撤回"跳过"这个决定。
final class RequestedSkip {
  const RequestedSkip({required this.blockId});

  /// 被跳过的**已确认计划块** id（`schedule_blocks.id`），不是任务 id。
  final String blockId;
}

/// 「跳过本次」的落点：把"这一块这次不排"记下来。
///
/// **端口为什么在 application 而不是 features**：实现方是 [PendingSkipDrafts]（应用层内存态），
/// 消费方是 `RepositoryScheduleProblemSource`（装配排程输入）。端口留在 `features/` 会让
/// 应用层反过来 import 界面层。因此端口按**原始输入**（块 id）声明，不认识 `ScheduleViewItem`。
abstract interface class SkipDraftSink {
  void setRequestedSkip(RequestedSkip skip);
}

/// 内存态的"待处理跳过"集合。行为与 [PendingMoveDrafts] 对齐（同一个块重复跳过时后一次覆盖）。
final class PendingSkipDrafts implements SkipDraftSink {
  final Map<String, RequestedSkip> _byBlock = {};

  @override
  void setRequestedSkip(RequestedSkip skip) => _byBlock[skip.blockId] = skip;

  RequestedSkip? forBlock(String blockId) => _byBlock[blockId];

  List<RequestedSkip> get all => UnmodifiableListView(_byBlock.values.toList());

  int get length => _byBlock.length;

  void clear() => _byBlock.clear();
}
