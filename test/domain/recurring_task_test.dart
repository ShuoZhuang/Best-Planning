import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';

void main() {
  final created = DateTime.utc(2026, 10, 1);

  RecurringTaskTemplate template({
    String title = '每周英语',
    int targetMinutes = 180,
    int minChunk = 25,
    int maxChunk = 90,
    int? preferredStart,
    int? preferredEnd,
    int mask = recurringAllWeekdaysMask,
    DateTime? startsOn,
    DateTime? endsOn,
    DateTime? pausedUntil,
    RecurringTemplateStatus status = RecurringTemplateStatus.active,
    String timeZoneId = 'Asia/Shanghai',
  }) => RecurringTaskTemplate(
    id: 'template-1',
    title: title,
    targetMinutes: targetMinutes,
    minChunkMinutes: minChunk,
    maxChunkMinutes: maxChunk,
    preferredStartMinute: preferredStart,
    preferredEndMinute: preferredEnd,
    allowedWeekdaysMask: mask,
    startsOnLocalDate: startsOn ?? DateTime(2026, 10, 5),
    endsOnLocalDate: endsOn,
    pausedUntilLocalDate: pausedUntil,
    timeZoneId: timeZoneId,
    status: status,
    createdAtUtc: created,
    updatedAtUtc: created,
  );

  group('模板校验', () {
    test('标题为空被拒绝', () {
      expect(() => template(title: '   '), throwsArgumentError);
    });

    test('目标分钟必须为正', () {
      expect(() => template(targetMinutes: 0), throwsArgumentError);
      expect(() => template(targetMinutes: -30), throwsArgumentError);
    });

    test('片段范围必须为正且最小值不大于最大值', () {
      expect(() => template(minChunk: 0), throwsArgumentError);
      expect(() => template(minChunk: 60, maxChunk: 30), throwsArgumentError);
    });

    test('期望时段必须成对出现', () {
      // 只给一端意味着"每天从 20:00 到 ???"。宁可拒绝，也不要在排程器里编一个钟点。
      expect(() => template(preferredStart: 20 * 60), throwsArgumentError);
      expect(() => template(preferredEnd: 22 * 60), throwsArgumentError);
      expect(
        () => template(preferredStart: 20 * 60, preferredEnd: 22 * 60),
        returnsNormally,
      );
    });

    test('星期掩码必须是 1..127 的非零值', () {
      expect(() => template(mask: 0), throwsArgumentError);
      expect(() => template(mask: 128), throwsArgumentError);
      expect(() => template(mask: 127), returnsNormally);
    });

    test('结束日不得早于开始日', () {
      expect(
        () => template(
          startsOn: DateTime(2026, 10, 5),
          endsOn: DateTime(2026, 10, 4),
        ),
        throwsArgumentError,
      );
    });

    test('日期字段被截成纯日期，跨夏令时也不会漂移', () {
      final value = template(startsOn: DateTime(2026, 10, 5, 23, 30));
      expect(value.startsOnLocalDate, DateTime(2026, 10, 5));
      // 按日历日位移，而不是 add(Duration(days:))。
      expect(shiftLocalDate(value.startsOnLocalDate, 1), DateTime(2026, 10, 6));
    });

    test('默认周一至周日、均匀分布、不结转', () {
      final value = template();
      expect(value.allowedWeekdaysMask, recurringAllWeekdaysMask);
      expect(value.pace, RecurringPace.even);
      expect(value.carryOverUnfinished, isFalse);
      expect(value.allowedWeekdays, [1, 2, 3, 4, 5, 6, 7]);
    });

    test('时间标识不得为空', () {
      expect(() => template(timeZoneId: ' '), throwsArgumentError);
    });
  });

  group('生效与暂停', () {
    test('归档模板不再生成', () {
      final value = template(status: RecurringTemplateStatus.archived);
      expect(value.isActiveOn(DateTime(2026, 10, 5)), isFalse);
    });

    test('开始日之前不生成，结束日之后不生成', () {
      final value = template(
        startsOn: DateTime(2026, 10, 12),
        endsOn: DateTime(2026, 10, 26),
      );
      expect(value.isActiveOn(DateTime(2026, 10, 5)), isFalse);
      expect(value.isActiveOn(DateTime(2026, 10, 12)), isTrue);
      expect(value.isActiveOn(DateTime(2026, 10, 26)), isTrue);
      expect(value.isActiveOn(DateTime(2026, 11, 2)), isFalse);
    });

    test('暂停到某日（含）之前不生成，到期后自动恢复', () {
      final value = template(pausedUntil: DateTime(2026, 10, 20));
      expect(value.isPausedOn(DateTime(2026, 10, 19)), isTrue);
      expect(value.isPausedOn(DateTime(2026, 10, 20)), isTrue);
      expect(value.isPausedOn(DateTime(2026, 10, 26)), isFalse);
      expect(
        value.isActiveOn(DateTime(2026, 10, 19)),
        isTrue,
        reason: '暂停不是归档',
      );
    });
  });

  group('周期实例', () {
    RecurringTaskCycle cycle({
      DateTime? periodStart,
      int baseTarget = 180,
      int carryIn = 0,
      RecurringCycleStatus status = RecurringCycleStatus.open,
    }) => RecurringTaskCycle(
      templateId: 'template-1',
      periodStartLocalDate: periodStart ?? DateTime(2026, 10, 5),
      taskId: 'task-1',
      baseTargetMinutes: baseTarget,
      carryInMinutes: carryIn,
      status: status,
      createdAtUtc: created,
      updatedAtUtc: created,
    );

    test('周期开始日必须是周一', () {
      expect(
        () => cycle(periodStart: DateTime(2026, 10, 6)),
        throwsArgumentError,
      );
      expect(() => cycle(periodStart: DateTime(2026, 10, 5)), returnsNormally);
    });

    test('目标快照必须为正，结转不得为负', () {
      expect(() => cycle(baseTarget: 0), throwsArgumentError);
      expect(() => cycle(carryIn: -1), throwsArgumentError);
    });

    test('有效目标＝快照＋结转', () {
      expect(cycle(carryIn: 30).effectiveTargetMinutes, 210);
    });
  });

  group('进度口径', () {
    RecurringProgress progress(
      int recorded, {
      int target = 180,
      int carryIn = 0,
    }) => RecurringProgress(
      templateId: 'template-1',
      periodStartLocalDate: DateTime(2026, 10, 5),
      targetMinutes: target + carryIn,
      recordedMinutes: recorded,
      remainingMinutes: (target + carryIn - recorded).clamp(0, 1 << 30),
      status: RecurringCycleStatus.open,
      carryInMinutes: carryIn,
    );

    test('180 目标、80 已记录 ⇒ 剩余 100（路线图 §7.2）', () {
      final value = progress(80);
      expect(value.targetMinutes, 180);
      expect(value.recordedMinutes, 80);
      expect(value.remainingMinutes, 100);
    });

    test('超额时剩余为 0，但记录保留', () {
      final value = progress(200);
      expect(value.remainingMinutes, 0);
      expect(value.recordedMinutes, 200);
      expect(value.overTargetMinutes, 20);
      expect(value.isMet, isTrue);
    });

    test('刚好达标时剩余为 0 且判定为达标', () {
      final value = progress(180);
      expect(value.remainingMinutes, 0);
      expect(value.isMet, isTrue);
      expect(value.completionRatio, 1.0);
    });
  });

  group('星期掩码', () {
    test('按 DateTime 的 1..7 编号读写', () {
      final mask = weekdayMaskOf([DateTime.monday, DateTime.sunday]);
      expect(isWeekdayAllowed(mask, DateTime.monday), isTrue);
      expect(isWeekdayAllowed(mask, DateTime.tuesday), isFalse);
      expect(isWeekdayAllowed(mask, DateTime.sunday), isTrue);
    });

    test('非法星期编号被拒绝', () {
      expect(() => isWeekdayAllowed(1, 0), throwsArgumentError);
      expect(() => isWeekdayAllowed(1, 8), throwsArgumentError);
    });
  });

  group('日期文本', () {
    test('格式化为定宽 YYYY-MM-DD 并按时间序比较', () {
      expect(formatLocalDate(DateTime(2026, 10, 5)), '2026-10-05');
      expect(
        formatLocalDate(DateTime(2026, 10, 5))
                .compareTo(formatLocalDate(DateTime(2026, 10, 12))) <
            0,
        isTrue,
      );
    });

    test('解析拒绝不存在的日历日', () {
      expect(parseLocalDate('2026-10-05'), DateTime(2026, 10, 5));
      expect(() => parseLocalDate('2026-02-30'), throwsArgumentError);
      expect(() => parseLocalDate('2026-10'), throwsArgumentError);
    });
  });

  group('优先级与精力复用任务枚举', () {
    test('默认值与任务一致', () {
      final value = template();
      expect(value.priority, TaskPriority.medium);
      expect(value.energyLevel, TaskEnergyLevel.medium);
      expect(value.splitMode, TaskSplitMode.splittable);
    });
  });
}
