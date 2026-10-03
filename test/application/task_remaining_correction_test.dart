import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_correction_log.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

/// FR-TASK-05：支持手动修正剩余时长，且保留修正记录供统计分析。
void main() {
  late _MutableClock clock;
  late _InMemoryTasks repository;
  late _RecordingLog log;
  late TaskService service;

  setUp(() {
    clock = _MutableClock(DateTime.utc(2026, 10, 5, 10));
    repository = _InMemoryTasks();
    log = _RecordingLog();
    service = TaskService(
      repository: repository,
      clock: clock,
      idGenerator: _SequentialIds(),
      correctionLog: log,
    );
  });

  test('修正剩余时长会保留前后值，且不改写预计时长', () async {
    final created = await service.quickAdd('课程论文', 180);
    final id = created.task!.id;

    clock.instant = DateTime.utc(2026, 10, 5, 11);
    final corrected = await service.correctRemainingMinutes(id, 120);

    expect(corrected.isSuccess, isTrue);
    expect(corrected.task!.remainingMinutes, 120);
    // 预计时长是原始估算，§8 的预估偏差口径依赖它，不能被修正覆盖。
    expect(corrected.task!.estimatedMinutes, 180);
    expect(corrected.task!.updatedAtUtc, DateTime.utc(2026, 10, 5, 11));

    expect(log.entries, hasLength(1));
    final entry = log.entries.single;
    expect(entry.taskId, id);
    expect(entry.previousMinutes, 180);
    expect(entry.correctedMinutes, 120);
    expect(entry.correctedAtUtc, DateTime.utc(2026, 10, 5, 11));
    expect(entry.deltaMinutes, -60);
  });

  test('允许上调剩余时长（用户可能低估了工作量）', () async {
    final created = await service.quickAdd('科研', 120);
    final corrected = await service.correctRemainingMinutes(
      created.task!.id,
      240,
    );

    expect(corrected.isSuccess, isTrue);
    expect(corrected.task!.remainingMinutes, 240);
    expect(log.entries.single.deltaMinutes, 120);
  });

  test('负剩余时长与不存在的任务都被拒绝且不写库', () async {
    final created = await service.quickAdd('任务', 60);
    final id = created.task!.id;
    final savesBefore = repository.saveCount;

    // **0 现在是合法值**（§13.0 的 R9：剩余为 0 表示"没有剩余工作"），因此这条用例改用负数
    // 验证拒绝路径——它原来用 0，已随契约变更而更新，而不是把断言放宽。
    expect((await service.correctRemainingMinutes(id, -30)).isSuccess, isFalse);
    expect(
      (await service.correctRemainingMinutes('missing', 30)).isSuccess,
      isFalse,
    );

    expect(repository.saveCount, savesBefore);
    expect(log.entries, isEmpty);
  });

  test('未注入记录端口时修正仍然生效，只是没有历史', () async {
    final bare = TaskService(
      repository: repository,
      clock: clock,
      idGenerator: _SequentialIds(),
    );
    final created = await bare.quickAdd('无记录端口', 60);

    final corrected = await bare.correctRemainingMinutes(created.task!.id, 30);

    expect(corrected.isSuccess, isTrue);
    expect(corrected.task!.remainingMinutes, 30);
    expect(log.entries, isEmpty);
  });
}

final class _MutableClock implements Clock {
  _MutableClock(this.instant);
  DateTime instant;
  @override
  DateTime nowUtc() => instant;
}

final class _SequentialIds implements IdGenerator {
  var _next = 0;
  @override
  String next() => 'id-${++_next}';
}

final class _InMemoryTasks implements TaskRepository {
  final Map<String, PlannerTask> items = {};
  var saveCount = 0;

  @override
  Future<PlannerTask?> getById(String id) async => items[id];

  @override
  Future<void> save(PlannerTask task) async {
    items[task.id] = task;
    saveCount++;
  }

  @override
  Stream<List<PlannerTask>> watchOpenTasks() =>
      Stream.value(items.values.toList(growable: false));
}

final class _RecordingLog implements TaskCorrectionLog {
  final List<RemainingMinutesCorrection> entries = [];

  @override
  Future<void> record(RemainingMinutesCorrection correction) async =>
      entries.add(correction);
}
