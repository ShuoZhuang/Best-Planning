// R5 的服务端：写入任务期望时段。
//
// 期望时段因子此前早已注入评分（算法版本 9），但**没有任何界面能写入这个字段**，因此
// 真实数据里它恒为"无偏好"，因子等于不存在。这里补上写入端，并验证它真的落到数据库的
// 两列上——用 drift 而非内存替身，因为列的映射本身也是要验证的部分。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';

final _now = DateTime.utc(2026, 10, 5, 2);
final _later = DateTime.utc(2026, 10, 5, 3);

final class _Clock implements Clock {
  _Clock(this.value);
  DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

void main() {
  late AppDatabase database;
  late _Clock clock;
  late TaskService service;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await database
        .into(database.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-test',
            name: '测试领域',
            color: 0,
            sortOrder: 0,
          ),
        );
    clock = _Clock(_now);
    service = TaskService(
      repository: DriftTaskRepository(database.taskDao),
      clock: clock,
      idGenerator: _Ids(),
    );
  });

  tearDown(() => database.close());

  Future<String> newTask() async => (await service.saveDraft(
    const TaskDraft(title: '写方案', estimatedMinutes: 60, areaId: 'area-test'),
  )).task!.id;

  test('写入期望时段并落到数据库的两列上', () async {
    final taskId = await newTask();

    expect(
      await service.setPreferredWindow(
        taskId,
        startMinute: 540,
        endMinute: 720,
      ),
      isTrue,
    );

    final saved = (await service.findById(taskId))!;
    expect(saved.preferredWindow, isNotNull);
    expect(saved.preferredWindow!.startMinute, 540);
    expect(saved.preferredWindow!.endMinute, 720);

    // 直接读列，确认映射不是只存在于领域模型里。
    final row = await (database.select(
      database.tasks,
    )..where((table) => table.id.equals(taskId))).getSingle();
    expect(row.preferredStartMinute, 540);
    expect(row.preferredEndMinute, 720);
  });

  test('允许跨本地午夜的期望时段', () async {
    final taskId = await newTask();

    // 22:00–02:00 是合法区间（LocalTimeRange 明确支持跨午夜），不能被当成"起点不早于
    // 终点"而拒绝。
    expect(
      await service.setPreferredWindow(
        taskId,
        startMinute: 22 * 60,
        endMinute: 2 * 60,
      ),
      isTrue,
    );
    expect(
      (await service.findById(taskId))!.preferredWindow!.crossesMidnight,
      isTrue,
    );
  });

  test('两个参数都为 null 表示清除偏好', () async {
    final taskId = await newTask();
    await service.setPreferredWindow(taskId, startMinute: 540, endMinute: 720);

    expect(await service.setPreferredWindow(taskId), isTrue);

    final saved = (await service.findById(taskId))!;
    expect(saved.preferredWindow, isNull);
    final row = await (database.select(
      database.tasks,
    )..where((table) => table.id.equals(taskId))).getSingle();
    expect(row.preferredStartMinute, isNull);
    expect(row.preferredEndMinute, isNull);
  });

  test('非法取值被拒绝且不改动已存偏好', () async {
    final taskId = await newTask();
    await service.setPreferredWindow(taskId, startMinute: 540, endMinute: 720);

    // 只给一端：无法构成区间。
    expect(await service.setPreferredWindow(taskId, startMinute: 540), isFalse);
    // 起点不早于终点。
    expect(
      await service.setPreferredWindow(
        taskId,
        startMinute: 720,
        endMinute: 720,
      ),
      isFalse,
    );
    // 超出一日范围。
    expect(
      await service.setPreferredWindow(
        taskId,
        startMinute: 540,
        endMinute: 1500,
      ),
      isFalse,
    );

    final saved = (await service.findById(taskId))!;
    expect(saved.preferredWindow!.startMinute, 540);
    expect(saved.preferredWindow!.endMinute, 720);
  });

  test('偏好未变化时不推进修改时间', () async {
    final taskId = await newTask();
    await service.setPreferredWindow(taskId, startMinute: 540, endMinute: 720);
    final afterFirst = (await service.findById(taskId))!.updatedAtUtc;

    clock.value = _later;
    expect(
      await service.setPreferredWindow(
        taskId,
        startMinute: 540,
        endMinute: 720,
      ),
      isTrue,
    );

    expect((await service.findById(taskId))!.updatedAtUtc, afterFirst);
  });

  test('任务不存在时返回 false', () async {
    expect(
      await service.setPreferredWindow(
        'missing',
        startMinute: 540,
        endMinute: 720,
      ),
      isFalse,
    );
  });
}
