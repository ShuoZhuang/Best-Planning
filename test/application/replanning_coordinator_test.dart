import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
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
