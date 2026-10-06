// FR-TASK-05：手动修正剩余时长必须**保留修正记录供统计分析**。
//
// 服务层的语义已由 `test/application/task_remaining_correction_test.dart` 用内存端口
// 验证；这里验证的是此前缺失的那一环——记录真的落进了数据库。在补上 drift 实现之前，
// `TaskCorrectionLog` 在生产装配里没有实现，因此修正照常生效但历史从未被写下，统计
// 永远读不到修正。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_task_correction_log.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 2);

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => _now;
}

void main() {
  late AppDatabase database;
  late TaskService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = TaskService(
      repository: DriftTaskRepository(database.taskDao),
      clock: const _FixedClock(),
      idGenerator: UuidIdGenerator(),
      correctionLog: DriftTaskCorrectionLog(database),
    );
  });

  tearDown(() => database.close());

  Future<void> seedTask({
    int estimatedMinutes = 120,
    int remainingMinutes = 90,
  }) => database
      .into(database.tasks)
      .insert(
        TasksCompanion.insert(
          id: 'task-1',
          title: '写方案',
          priority: 'medium',
          estimatedMinutes: estimatedMinutes,
          remainingMinutes: remainingMinutes,
          energyLevel: 'medium',
          splitMode: 'splittable',
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          status: 'inbox',
          createdAtUtc: 1,
          updatedAtUtc: 1,
        ),
      );

  Future<List<TaskCorrection>> corrections() =>
      database.select(database.taskCorrections).get();

  test('修正剩余时长写入记录并保留前后值', () async {
    await seedTask();

    final result = await service.correctRemainingMinutes('task-1', 150);
    expect(result.isSuccess, isTrue);

    final row = await (database.select(
      database.tasks,
    )..where((table) => table.id.equals('task-1'))).getSingle();
    expect(row.remainingMinutes, 150);
    // 预计时长是原始估算，被改写会污染 §8 的预估偏差口径。
    expect(row.estimatedMinutes, 120);
    expect(row.updatedAtUtc, _now.microsecondsSinceEpoch);

    final recorded = await corrections();
    expect(recorded, hasLength(1));
    expect(recorded.single.taskId, 'task-1');
    expect(recorded.single.previousMinutes, 90);
    expect(recorded.single.correctedMinutes, 150);
    // 记录时刻与任务行的修改时刻来自同一个 now，不应各自读一次时钟。
    expect(recorded.single.correctedAtUtc, _now.microsecondsSinceEpoch);
  });

  test('多次修正累积历史而不是覆盖', () async {
    await seedTask();

    await service.correctRemainingMinutes('task-1', 150);
    await service.correctRemainingMinutes('task-1', 120);

    final recorded = await corrections();
    expect(recorded, hasLength(2));
    // 统计要看的是"每次修正多少、往哪个方向"，因此每个中间值都要留住。
    expect(
      recorded.map(
        (item) => '${item.previousMinutes}->${item.correctedMinutes}',
      ),
      containsAll(['90->150', '150->120']),
    );
  });

  test('被拒绝的修正不留下记录', () async {
    await seedTask();

    // **只有负值会在写库之前被拒绝**（0 自本轮起合法：剩余为 0 表示"没有剩余工作"，见
    // §13.0 的 R9），因此这条用例改用负数验证"拒绝不留历史"这条契约。
    expect(
      (await service.correctRemainingMinutes('task-1', -30)).isSuccess,
      isFalse,
    );
    expect(
      (await service.correctRemainingMinutes('missing', 30)).isSuccess,
      isFalse,
    );

    expect(await corrections(), isEmpty);
  });
}
