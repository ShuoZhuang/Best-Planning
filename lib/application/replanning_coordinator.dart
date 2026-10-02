import 'dart:async';

import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

enum DomainChangeKind {
  taskCreated,
  taskSchedulingChanged,
  taskCompleted,
  taskSkipped,
  taskDeferred,
  taskNotesChanged,
  fixedEventCreated,
  focusActualChanged,
}

final class DomainChange {
  const DomainChange(this.kind);
  final DomainChangeKind kind;

  bool get affectsSchedule => kind != DomainChangeKind.taskNotesChanged;
}

final class ReplanningCoordinator {
  ReplanningCoordinator({
    required this.planning,
    this.onProposal,
    this.onError,
    this.debounce = const Duration(milliseconds: 500),
  });

  final ProposalCreator planning;
  final ValueChanged<ScheduleProposal>? onProposal;
  final ValueChanged<Object>? onError;
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
      if (!_disposed && generation == _generation) onProposal?.call(proposal);
    } catch (error) {
      if (!_disposed && generation == _generation) onError?.call(error);
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
  }
}

typedef ValueChanged<T> = void Function(T value);
