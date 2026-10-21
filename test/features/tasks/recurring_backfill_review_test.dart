import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_backfill_review_page.dart';

void main() {
  testWidgets('回填复核页列出歧义块与原因', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftExecutionRepository(
      database,
      clock: const SystemClock(),
      idGenerator: UuidIdGenerator(),
    );
    final runtime = await repository.ensureRuntimeState();
    final now = DateTime.utc(2026, 10, 19, 5);
    await repository.insertOutbox(
      ExecutionOutboxEntry(
        effectId: 'effect-1',
        dataEpoch: runtime.dataEpoch,
        sourceTransaction: 'executionPlanLinkerBackfill',
        targetRevision: 1,
        effectType: 'recurringBackfillAmbiguous',
        payload: const {
          'planVersionId': 'plan-1',
          'blockId': 'block-1',
          'occurrenceId': 'occurrence-1',
          'reason': 'missingTiming',
        },
        attempts: 0,
        createdAtUtc: now,
        nextAttemptAtUtc: now,
        processedAtUtc: null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: RecurringBackfillReviewPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('block-1'), findsOneWidget);
    expect(find.textContaining('missingTiming'), findsOneWidget);
  });
}
