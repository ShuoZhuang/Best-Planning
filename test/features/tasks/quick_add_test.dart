import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/features/tasks/quick_add_form.dart';

void main() {
  testWidgets('快速录入可仅用键盘提交', (tester) async {
    final repository = _MemoryTaskRepository();
    final service = TaskService(
      repository: repository,
      clock: _Clock(),
      idGenerator: _Ids(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuickAddForm(service: service)),
      ),
    );

    await tester.enterText(find.byKey(const Key('quick-add-title')), '完成作业');
    await tester.enterText(find.byKey(const Key('quick-add-duration')), '45');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(find.text('已加入收集箱'), findsOneWidget);
  });
}

final class _MemoryTaskRepository implements TaskRepository {
  final List<PlannerTask> saved = [];
  @override
  Future<PlannerTask?> getById(String id) async => null;
  @override
  Future<void> save(PlannerTask task) async => saved.add(task);
  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(saved);
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 1);
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'task-1';
}
