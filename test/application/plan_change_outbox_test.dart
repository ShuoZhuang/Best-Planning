// 1.11.0（计划 Task 10 Step 6）：提交后副作用走 outbox，可重试且不回滚计划。
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/plan_change_outbox_dispatcher.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;

  setUp(() async {
    harness = await ExecutionTestHarness.create(seedTask: false);
  });

  tearDown(() => harness.close());

  Future<void> seed(String id, {int nextAttemptOffsetSeconds = 0}) async {
    final now = harness.clock.nowUtc().microsecondsSinceEpoch;
    await harness.database.customInsert(
      'INSERT INTO plan_change_outbox '
      '(id, dedupe_key, kind, payload_json, attempts, next_attempt_at_utc, '
      'created_at_utc) VALUES (?, ?, ?, ?, 0, ?, ?)',
      variables: [
        Variable.withString(id),
        Variable.withString('planChanged:$id'),
        Variable.withString('planChanged'),
        Variable.withString('{"planVersionId":"$id"}'),
        Variable.withInt(now + nextAttemptOffsetSeconds * 1000000),
        Variable.withInt(now),
      ],
    );
  }

  Future<int> attempts(String id) async {
    final row = await harness.database
        .customSelect(
          'SELECT attempts, completed_at_utc FROM plan_change_outbox WHERE id = ?',
          variables: [Variable.withString(id)],
        )
        .getSingle();
    return row.read<int>('attempts');
  }

  Future<bool> completed(String id) async {
    final row = await harness.database
        .customSelect(
          'SELECT completed_at_utc FROM plan_change_outbox WHERE id = ?',
          variables: [Variable.withString(id)],
        )
        .getSingle();
    return row.readNullable<int>('completed_at_utc') != null;
  }

  test('副作用成功后标记完成，不再重复消费', () async {
    await seed('plan-1');
    var calls = 0;
    final dispatcher = PlanChangeOutboxDispatcher(
      database: harness.database,
      clock: harness.clock,
      onPlanChanged: (_) async => calls++,
    );

    expect(await dispatcher.dispatch(), 1);
    expect(await dispatcher.dispatch(), 0);

    expect(calls, 1);
    expect(await completed('plan-1'), isTrue);
    expect(await dispatcher.pendingCount(), 0);
  });

  test('副作用失败只累加重试状态，不删除记录', () async {
    await seed('plan-1');
    final dispatcher = PlanChangeOutboxDispatcher(
      database: harness.database,
      clock: harness.clock,
      onPlanChanged: (_) async => throw StateError('notification down'),
    );

    expect(await dispatcher.dispatch(), 0);
    expect(await attempts('plan-1'), 1);
    expect(await completed('plan-1'), isFalse);
    expect(await dispatcher.pendingCount(), 1);

    // 仍在退避窗口内：再次 dispatch 不会调用副作用。
    expect(await dispatcher.dispatch(), 0);
    expect(await attempts('plan-1'), 1);
  });

  test('退避到期后再次尝试，成功即完成', () async {
    await seed('plan-1');
    var fail = true;
    final dispatcher = PlanChangeOutboxDispatcher(
      database: harness.database,
      clock: harness.clock,
      onPlanChanged: (_) async {
        if (fail) throw StateError('notification down');
      },
    );
    await dispatcher.dispatch();
    fail = false;
    harness.clock.advance(const Duration(minutes: 10));

    expect(await dispatcher.dispatch(), 1);
    expect(await completed('plan-1'), isTrue);
  });

  test('达到最大尝试次数后不再自动重试', () async {
    await seed('plan-1');
    final dispatcher = PlanChangeOutboxDispatcher(
      database: harness.database,
      clock: harness.clock,
      onPlanChanged: (_) async => throw StateError('always down'),
      maxAttempts: 2,
    );
    for (var i = 0; i < 3; i++) {
      await dispatcher.dispatch();
      harness.clock.advance(const Duration(minutes: 20));
    }

    expect(await attempts('plan-1'), 2);
    expect(await completed('plan-1'), isFalse);
    expect(await dispatcher.pendingCount(), 1);
  });
}
