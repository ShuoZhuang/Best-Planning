import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_generation_flow.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  test('调度相关变化触发而纯备注修改不触发', () {
    fakeAsync((async) {
      final creator = _ImmediateCreator();
      final coordinator = ReplanningCoordinator(planning: creator);
      addTearDown(coordinator.dispose);
      const triggers = [
        DomainChangeKind.taskCreated,
        DomainChangeKind.taskSchedulingChanged,
        DomainChangeKind.taskCompleted,
        DomainChangeKind.taskSkipped,
        DomainChangeKind.taskDeferred,
        DomainChangeKind.fixedEventCreated,
        DomainChangeKind.focusActualChanged,
      ];
      for (final kind in triggers) {
        coordinator.onDomainChange(DomainChange(kind));
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
      }
      coordinator.onDomainChange(
        const DomainChange(DomainChangeKind.taskNotesChanged),
      );
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(creator.calls, triggers.length);
    });
  });

  test('短时间连续变化合并为一次请求', () {
    fakeAsync((async) {
      final creator = _ImmediateCreator();
      final coordinator = ReplanningCoordinator(planning: creator);
      addTearDown(coordinator.dispose);

      coordinator.onDomainChange(
        const DomainChange(DomainChangeKind.taskCreated),
      );
      async.elapse(const Duration(milliseconds: 200));
      coordinator.onDomainChange(
        const DomainChange(DomainChangeKind.taskSchedulingChanged),
      );
      async.elapse(const Duration(milliseconds: 499));
      expect(creator.calls, 0);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(creator.calls, 1);
    });
  });

  test('新输入使运行中的旧提案结果失效', () {
    fakeAsync((async) {
      final creator = _DeferredCreator();
      final accepted = <String>[];
      final coordinator = ReplanningCoordinator(
        planning: creator,
        onProposal: (proposal) => accepted.add(proposal.proposalId),
      );
      addTearDown(coordinator.dispose);

      coordinator.onDomainChange(
        const DomainChange(DomainChangeKind.taskCreated),
      );
      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      coordinator.onDomainChange(
        const DomainChange(DomainChangeKind.fixedEventCreated),
      );
      creator.completeNext('old');
      async.flushMicrotasks();
      expect(accepted, isEmpty);

      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      creator.completeNext('new');
      async.flushMicrotasks();
      expect(accepted, ['new']);
    });
  });
  test('新增的两个类别同样触发重排', () {
    // `taskCancelled` 与 `fixedEventChanged` 是本轮补上的：原枚举只有"完成/跳过"与
    // "固定日程创建"，而取消任务、删除或改写固定日程**同样**改变可用时间。
    fakeAsync((async) {
      final creator = _ImmediateCreator();
      final coordinator = ReplanningCoordinator(planning: creator);
      addTearDown(coordinator.dispose);

      for (final kind in [
        DomainChangeKind.taskCancelled,
        DomainChangeKind.fixedEventChanged,
      ]) {
        coordinator.onDomainChange(DomainChange(kind));
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();
      }

      expect(creator.calls, 2);
    });
  });

  group('应用策略（FR-REPLAN-03/04/05）', () {
    test('未开启"信任自动调整"时只生成、绝不调用应用', () {
      fakeAsync((async) {
        final creator = _ImmediateCreator();
        final applied = <String>[];
        final outcomes = <ReplanOutcome>[];
        final proposals = <String>[];
        final coordinator = ReplanningCoordinator(
          planning: creator,
          flow: PlanGenerationFlow(isTrusted: () => false),
          apply: (proposal) async {
            applied.add(proposal.proposalId);
            return ApplyPlanResult.stale();
          },
          onProposal: (proposal) => proposals.add(proposal.proposalId),
          onOutcome: outcomes.add,
        );
        addTearDown(coordinator.dispose);

        coordinator.onDomainChange(
          const DomainChange(DomainChangeKind.taskCreated),
        );
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        expect(creator.calls, 1);
        expect(applied, isEmpty, reason: 'FR-REPLAN-03：默认必须由用户确认，不能替用户应用');
        expect(outcomes.single.applied, isFalse);
        expect(outcomes.single.awaitsConfirmation, isTrue);
        expect(outcomes.single.message, isNotEmpty);
        expect(proposals, hasLength(1));
      });
    });

    test('开启"信任自动调整"时直接应用（FR-REPLAN-04）', () {
      fakeAsync((async) {
        final creator = _ImmediateCreator();
        final applied = <String>[];
        final outcomes = <ReplanOutcome>[];
        final coordinator = ReplanningCoordinator(
          planning: creator,
          flow: PlanGenerationFlow(isTrusted: () => true),
          apply: (proposal) async {
            applied.add(proposal.proposalId);
            return ApplyPlanResult.applied(_confirmedPlan());
          },
          onOutcome: outcomes.add,
        );
        addTearDown(coordinator.dispose);

        coordinator.onDomainChange(
          const DomainChange(DomainChangeKind.taskSchedulingChanged),
        );
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        expect(applied, ['p-1']);
        expect(outcomes.single.applied, isTrue);
        expect(outcomes.single.awaitsConfirmation, isFalse);
      });
    });

    test('自动应用失败或过期时如实说明"原有计划保留"（FR-REPLAN-05）', () {
      fakeAsync((async) {
        final statuses = [
          ApplyPlanResult.stale(),
          ApplyPlanResult.invalid(const []),
        ];
        var index = 0;
        final outcomes = <ReplanOutcome>[];
        final coordinator = ReplanningCoordinator(
          planning: _ImmediateCreator(),
          flow: PlanGenerationFlow(isTrusted: () => true),
          apply: (proposal) async => statuses[index++],
          onOutcome: outcomes.add,
        );
        addTearDown(coordinator.dispose);

        for (var i = 0; i < 2; i++) {
          coordinator.onDomainChange(
            const DomainChange(DomainChangeKind.taskCreated),
          );
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
        }

        expect(outcomes, hasLength(2));
        for (final outcome in outcomes) {
          expect(outcome.applied, isFalse);
          expect(
            outcome.message,
            contains('原有计划保留'),
            reason: 'FR-REPLAN-05 要求失败时保留原计划，提示必须如实这样说',
          );
        }
      });
    });

    test('自动应用成功时同样上报提案（否则冲突通知会拿到过期提案）', () {
      fakeAsync((async) {
        final proposals = <String>[];
        final coordinator = ReplanningCoordinator(
          planning: _ImmediateCreator(),
          flow: PlanGenerationFlow(isTrusted: () => true),
          apply: (proposal) async => ApplyPlanResult.applied(_confirmedPlan()),
          // 组合根用这个回调持有"最近一次提案"，它是"冲突待处理"通知的来源（R8 ③）。
          onProposal: (proposal) => proposals.add(proposal.proposalId),
        );
        addTearDown(coordinator.dispose);

        coordinator.onDomainChange(
          const DomainChange(DomainChangeKind.taskCreated),
        );
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        expect(proposals, hasLength(1));
      });
    });

    test('未配置应用策略时只重算并回报"等待确认"', () {
      fakeAsync((async) {
        final outcomes = <ReplanOutcome>[];
        final coordinator = ReplanningCoordinator(
          planning: _ImmediateCreator(),
          onOutcome: outcomes.add,
        );
        addTearDown(coordinator.dispose);

        coordinator.onDomainChange(
          const DomainChange(DomainChangeKind.taskCreated),
        );
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        expect(outcomes.single.applied, isFalse);
        expect(outcomes.single.message, isNotEmpty);
      });
    });

    test('抛出异常时走 onError，且不回报任何结果', () {
      fakeAsync((async) {
        final errors = <Object>[];
        final outcomes = <ReplanOutcome>[];
        final coordinator = ReplanningCoordinator(
          planning: _FailingCreator(),
          flow: PlanGenerationFlow(isTrusted: () => true),
          apply: (proposal) async => ApplyPlanResult.applied(_confirmedPlan()),
          onOutcome: outcomes.add,
          onError: errors.add,
        );
        addTearDown(coordinator.dispose);

        coordinator.onDomainChange(
          const DomainChange(DomainChangeKind.taskCreated),
        );
        async.elapse(const Duration(milliseconds: 500));
        async.flushMicrotasks();

        expect(errors, hasLength(1));
        expect(outcomes, isEmpty);
      });
    });
  });
}

ConfirmedPlan _confirmedPlan() => ConfirmedPlan(
  id: 'plan-1',
  inputHash: 'hash',
  algorithmVersion: '9',
  blocks: const [],
);

final class _FailingCreator implements ProposalCreator {
  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
  }) async => throw StateError('engine exploded');
}

final class _ImmediateCreator implements ProposalCreator {
  int calls = 0;
  @override
  Future<ScheduleProposal> createProposal({
    ScheduleRuleOverride? override,
  }) async => _proposal('p-${++calls}');
}

final class _DeferredCreator implements ProposalCreator {
  final List<Completer<ScheduleProposal>> pending = [];
  @override
  Future<ScheduleProposal> createProposal({ScheduleRuleOverride? override}) {
    final completer = Completer<ScheduleProposal>();
    pending.add(completer);
    return completer.future;
  }

  void completeNext(String id) => pending.removeAt(0).complete(_proposal(id));
}

ScheduleProposal _proposal(String id) => ScheduleProposal(
  proposalId: id,
  inputHash: 'hash-$id',
  algorithmVersion: '1',
  blocks: const [],
  unscheduled: const [],
  conflicts: const [],
  explanations: const [],
  metrics: const ProposalMetrics(
    isFullyFeasible: true,
    scheduledMinutes: 0,
    unscheduledMinutes: 0,
  ),
);
