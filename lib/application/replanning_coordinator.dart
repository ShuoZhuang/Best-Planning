import 'dart:async';

import 'package:personal_planner/application/plan_generation_flow.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// "领域里发生了什么变化"的类别（§13.0 的 W9）。
///
/// **为什么要有这份词汇表**：重排的粒度不是"用户点了一个按钮"，而是"某个事实变了"。
/// 把变化的**类别**与"要不要重排"分开，才能表达"改备注不重排、改时间要重排"这类判断，
/// 而不是让每个调用点自己决定。
enum DomainChangeKind {
  taskCreated,

  /// 任务的**排程字段**变了：截止日期、优先级、剩余时长。这三类都会改变引擎的选择。
  taskSchedulingChanged,
  taskCompleted,
  taskSkipped,
  taskCancelled,

  /// **当前没有任何动作能产生这个值**（2026-10-03 核对）：需求 FR-REPLAN-01 提到"延期事项"，
  /// 而应用里"延期"的表现形式就是**改截止日期**，那已经由 [taskSchedulingChanged] 覆盖。
  /// 保留这个值是为了将来真正出现一个独立的"延期"动作时不必再来改枚举——但**现在它是不可达的**，
  /// 因此不要把它算进"已覆盖的触发来源"。若长期用不上，删掉比留着更诚实。
  taskDeferred,

  /// 只改了备注之类的**非排程字段**。单列一项是为了让它显式地**不触发**重排——
  /// 否则"改备注也重排"会让用户在写字时不断触发计划重算。
  ///
  /// **当前同样没有发出者**（2026-10-03 核对）：备注目前只能在**新建任务时**写入
  /// （`TaskDraft.notes`），没有"改备注"的动作。因此这个值现在的实际作用是**负例**——
  /// `affectsSchedule` 与协调器都靠它表达"这一类变化不该触发重排"。
  taskNotesChanged,
  fixedEventCreated,

  /// 固定日程被删除或改写。原枚举只有"创建"，而删除与改写同样改变可用时间。
  fixedEventChanged,

  /// 实际投入变了（专注结束会重算任务的剩余时长）。
  focusActualChanged,
}

final class DomainChange {
  const DomainChange(this.kind);
  final DomainChangeKind kind;

  bool get affectsSchedule => kind != DomainChangeKind.taskNotesChanged;
}

/// 一条"排程输入变了"的原因：**给人看的标签**与**给协调器用的类别**打包在一起。
///
/// **为什么不只传字符串**：`TaskService`／`CalendarService` 的回调原先只传一个中文标签，
/// 而协调器需要的是 `DomainChangeKind`。若在组合根里把标签映射回类别，就会出现一份
/// **字符串到枚举的隐形对照表**——改一个文案就静默地停止触发重排。打包在一起后，
/// 标签与类别由**知道发生了什么事**的那一层同时给出（例如 `changeStatus` 知道新状态是
/// 完成还是跳过），组合根只负责转发。
final class ScheduleInputChange {
  const ScheduleInputChange({required this.label, required this.kind});

  /// 直接显示给用户的原因文案（统计页的"重排原因"用它）。
  final String label;

  final DomainChangeKind kind;
}

/// "领域变化 → 自动重排"的协调器（FR-REPLAN-01/03/04/05）。
///
/// **此前它在生产里从未被构造**（§13.0 的 W9）：全库检索只有它自己的文件与测试构造它，
/// 于是"改了任务会自动重算计划"这件事**根本不成立**——唯一的排程入口是外壳顶栏的
/// "生成计划"按钮。本类补上的是那条机制，而不是又一个按钮。
///
/// **三条设计约束**：
/// - **去抖与合并**：连续变化（例如批量改十条任务的优先级）只应产生一次重算。用
///   `debounce` 把窗口内的变化合并，并用 `_generation` 让**过期的生成结果直接丢弃**，
///   否则先发起的慢生成会覆盖后发起的结果。
/// - **应用策略交给 `PlanGenerationFlow`**：FR-REPLAN-03"默认由用户确认后应用"与
///   FR-REPLAN-04"信任自动调整开启时直接应用"是同一条既有判断，这里复用而不是重写——
///   重写一份"要不要应用"的规则必然会与那条漂移。
/// - **失败不换计划**（FR-REPLAN-05）：不论自动应用失败还是过期，`apply` 本身只在成功时
///   才换版本，这里把结果**如实回报**给界面，而不是含糊地说"调整完成"。
final class ReplanningCoordinator {
  ReplanningCoordinator({
    required this.planning,
    this.flow,
    this.apply,
    this.onProposal,
    this.onOutcome,
    this.onError,
    this.debounce = const Duration(milliseconds: 500),
  });

  final ProposalCreator planning;

  /// 应用策略。为 `null` 时**只生成、不应用**——即"重算好了等人确认"。
  final PlanGenerationFlow? flow;

  /// 真正落库的应用动作。与 [flow] 必须**同时**提供或同时省略。
  final Future<ApplyPlanResult> Function(ScheduleProposal proposal)? apply;

  /// 每次**成功生成**提案后调用（无论是否自动应用）。
  ///
  /// 组合根用它持有"最近一次提案"——"冲突待处理"通知的来源（R8 ③）。它在自动应用路径上
  /// **也必须调用**，否则自动应用一次之后冲突通知会拿到过期的提案。
  final void Function(ScheduleProposal proposal)? onProposal;

  /// 一次"生成 →（可能）应用"走完之后的如实回报。
  final void Function(ReplanOutcome outcome)? onOutcome;

  final void Function(Object error)? onError;
  final Duration debounce;

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  void onDomainChange(DomainChange change) {
    if (_disposed || !change.affectsSchedule) return;
    final generation = ++_generation;
    _timer?.cancel();
    _timer = Timer(debounce, () => _create(generation));
  }

  Future<void> _create(int generation) async {
    try {
      final proposal = await planning.createProposal();
      if (!_isCurrent(generation)) return;
      onProposal?.call(proposal);

      final flow = this.flow;
      final apply = this.apply;
      if (flow == null || apply == null) {
        onOutcome?.call(ReplanOutcome.pending(proposal.proposalId));
        return;
      }
      final result = await flow.run(proposal: proposal, apply: apply);
      if (!_isCurrent(generation)) return;
      onOutcome?.call(
        ReplanOutcome(
          proposalId: result.proposalId,
          applied: result.applied,
          // 流程用**空文案**表示"去预览页确认"——那是顶栏按钮那条路径的约定，它自己会导航。
          // 自动重排没有任何人替用户导航，因此空文案在这里必须换成一句**说明**，
          // 否则用户改完任务什么都看不到，只会以为改动没有生效。
          message: result.message.isEmpty
              ? ReplanOutcome.pending(proposal.proposalId).message
              : result.message,
        ),
      );
    } catch (error) {
      if (_isCurrent(generation)) onError?.call(error);
    }
  }

  /// 只有**最新**那一次生成才允许上报结果：否则先发起的慢生成会覆盖后发起的结果。
  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
  }
}

/// 一次自动重排的结果。界面据此决定"提示用户去预览"还是"报告已自动应用"。
final class ReplanOutcome {
  const ReplanOutcome({
    required this.proposalId,
    required this.applied,
    required this.message,
  });

  /// 未配置应用策略（只重算、不应用）时的结果：**等用户确认**，符合 FR-REPLAN-03。
  const ReplanOutcome.pending(this.proposalId)
    : applied = false,
      message = '计划已按最近的改动重算，等待你确认';

  final String proposalId;
  final bool applied;

  /// 用户可见文案。为空表示走的是默认路径（去预览页确认）。
  final String message;

  /// 是否应当提示用户"有一份新计划等着确认"。
  bool get awaitsConfirmation => !applied;
}

typedef ValueChanged<T> = void Function(T value);
