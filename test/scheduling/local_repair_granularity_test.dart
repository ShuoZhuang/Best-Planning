// 1.11.0（计划 Task 7 Step 3、DFR-026）：绕开非网格障碍后必须重新吸附网格。
//
// 修复前局部级联把候选直接推到障碍结束点：一个 09:03 结束的固定日程会让目标块
// 从 09:03 开始——既不在排程网格上，也和引擎的候选规则不一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/local_repair.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'UTC';
  final dayStart = DateTime.utc(2026, 10, 19);
  final dayEnd = DateTime.utc(2026, 10, 20);

  PlannedBlock block(String id, DateTime start, int minutes) => PlannedBlock(
    id: id,
    taskId: 'task-$id',
    range: TimeRange(
      startUtc: start,
      endUtc: start.add(Duration(minutes: minutes)),
    ),
  );

  int grid5(DateTime _) => 5;

  test('09:03 障碍结束后从 09:05 开始（目标日 5 分钟粒度）', () {
    final target = block('target', DateTime.utc(2026, 10, 19, 9), 30);
    final obstacle = block('fixed', DateTime.utc(2026, 10, 19, 9), 3);

    final outcome = localRepairCascade(
      targetBlockId: 'target',
      notBeforeUtc: DateTime.utc(2026, 10, 19, 9),
      blocks: [target],
      immovable: [obstacle],
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
      zones: zones,
      timeZoneId: zoneId,
      granularityForDate: grid5,
    );

    expect(outcome.feasible, isTrue);
    final placed = outcome.blocks.firstWhere((b) => b.id == 'target');
    expect(placed.startUtc, DateTime.utc(2026, 10, 19, 9, 5));
    expect(placed.range.startUtc.minute % 5, 0);
  });

  test('粒度 10 分钟时 09:02 障碍后从 09:10 开始', () {
    final target = block('target', DateTime.utc(2026, 10, 19, 9), 30);
    final obstacle = block('fixed', DateTime.utc(2026, 10, 19, 9), 2);

    final outcome = localRepairCascade(
      targetBlockId: 'target',
      notBeforeUtc: DateTime.utc(2026, 10, 19, 9),
      blocks: [target],
      immovable: [obstacle],
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
      zones: zones,
      timeZoneId: zoneId,
      granularityForDate: (_) => 10,
    );

    final placed = outcome.blocks.firstWhere((b) => b.id == 'target');
    expect(placed.startUtc, DateTime.utc(2026, 10, 19, 9, 10));
  });

  test('未提供粒度信息时保持旧行为（仅用于纯算法测试）', () {
    final target = block('target', DateTime.utc(2026, 10, 19, 9), 30);
    final obstacle = block('fixed', DateTime.utc(2026, 10, 19, 9), 3);

    final outcome = localRepairCascade(
      targetBlockId: 'target',
      notBeforeUtc: DateTime.utc(2026, 10, 19, 9),
      blocks: [target],
      immovable: [obstacle],
      dayStartUtc: dayStart,
      dayEndUtc: dayEnd,
    );

    final placed = outcome.blocks.firstWhere((b) => b.id == 'target');
    expect(placed.startUtc, DateTime.utc(2026, 10, 19, 9, 3));
  });
}
