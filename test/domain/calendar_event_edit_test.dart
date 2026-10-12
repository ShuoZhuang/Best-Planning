// Task 2（课程与保护时间管理修复计划）：**日历改写草稿的校验与不可变性**。
//
// 这些是纯模型测试，因此可以把"哪些输入非法"逐条钉住，而不必启动界面或数据库。
// 计划 Task 2 Step 1 点名的七种情况：
// 空标题、非 UTC、结束不晚于开始、空时区、无效星期、重复间隔不在 1–52、截止早于开始，
// 外加"合法跨午夜区间"与"草稿创建后集合不可被外部修改"。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/calendar_event_edit.dart';

void main() {
  CalendarEventEditDraft draft({
    String title = '数据结构课',
    DateTime? start,
    DateTime? end,
    String timeZoneId = 'Asia/Shanghai',
    String notes = '',
  }) => CalendarEventEditDraft(
    title: title,
    startAtUtc: start ?? DateTime.utc(2026, 10, 5, 1),
    endAtUtc: end ?? DateTime.utc(2026, 10, 5, 2),
    timeZoneId: timeZoneId,
    notes: notes,
  );

  RecurrenceEditDraft recurrence({
    Set<int>? weekdays,
    int intervalWeeks = 1,
    DateTime? from,
    DateTime? until,
  }) => RecurrenceEditDraft(
    weekdays: weekdays ?? {DateTime.monday},
    intervalWeeks: intervalWeeks,
    validFromLocalDate: from ?? DateTime(2026, 10, 5),
    validUntilLocalDate: until,
  );

  group('CalendarEventEditDraft 校验', () {
    test('合法草稿通过，且标题去掉首尾空白', () {
      final value = draft(title: '  数据结构课  ');
      expect(value.isValid, isTrue);
      expect(value.title, '数据结构课', reason: '用户很容易多打一个空格；留着它会让"同一门课"看起来是两条');
      expect(value.fieldErrors, isEmpty);
    });

    test('**空标题**（含只有空白）⇒ title 字段错误', () {
      expect(draft(title: '').isValid, isFalse);
      expect(draft(title: '').fieldErrors['title'], isNotNull);
      expect(draft(title: '   ').fieldErrors['title'], isNotNull);
    });

    test('**非 UTC** 的开始或结束 ⇒ 对应字段错误', () {
      // 本地时刻传进来会在别的时区表现为"差了几小时"，且不报错——因此必须挡在门口。
      final localStart = DateTime(2026, 10, 5, 9);
      expect(draft(start: localStart).fieldErrors['startAtUtc'], isNotNull);
      expect(
        draft(end: DateTime(2026, 10, 5, 10)).fieldErrors['endAtUtc'],
        isNotNull,
      );
    });

    test('**结束不晚于开始** ⇒ 结束字段错误（相等也算）', () {
      final same = DateTime.utc(2026, 10, 5, 1);
      expect(
        draft(start: same, end: same).fieldErrors['endAtUtc'],
        isNotNull,
        reason: '零长度日程在数据里是用来表达"这一次被删除"的，用户改出来的不该是它',
      );
      expect(
        draft(
          start: DateTime.utc(2026, 10, 5, 2),
          end: DateTime.utc(2026, 10, 5, 1),
        ).fieldErrors['endAtUtc'],
        isNotNull,
      );
    });

    test('**空时区** ⇒ 字段错误', () {
      expect(draft(timeZoneId: '').fieldErrors['timeZoneId'], isNotNull);
      expect(draft(timeZoneId: '   ').fieldErrors['timeZoneId'], isNotNull);
    });

    test('**合法的跨午夜区间**通过（22:00 本地到次日 02:00）', () {
      // 本地 22:00 = UTC 14:00；本地次日 02:00 = UTC 18:00。
      final value = draft(
        start: DateTime.utc(2026, 10, 5, 14),
        end: DateTime.utc(2026, 10, 5, 18),
      );
      expect(
        value.isValid,
        isTrue,
        reason: '跨午夜是**合法**的：夜班、跨天的自习都真实存在，不能按"同一天"校验',
      );
    });

    test('备注与地点原样保留（它们此前没有写入路径）', () {
      final value = CalendarEventEditDraft(
        title: '课',
        startAtUtc: DateTime.utc(2026, 10, 5, 1),
        endAtUtc: DateTime.utc(2026, 10, 5, 2),
        timeZoneId: 'Asia/Shanghai',
        notes: '赵敏',
        location: 'D206',
      );
      expect(value.notes, '赵敏');
      expect(value.location, 'D206');
    });

    test('字段错误是**不可修改视图**：调用方改不动内部状态', () {
      final value = draft(title: '');
      expect(
        () => value.fieldErrors['title'] = '被改了',
        throwsUnsupportedError,
        reason: '可变的 fieldErrors 会让"校验通过"与"实际写入"看到两份不同的数据',
      );
    });
  });

  group('RecurrenceEditDraft 校验', () {
    test('合法规则通过', () {
      expect(recurrence().isValid, isTrue);
      expect(recurrence(until: DateTime(2026, 12, 20)).isValid, isTrue);
    });

    test('**空星期集合** ⇒ 字段错误', () {
      expect(recurrence(weekdays: const {}).fieldErrors['weekdays'], isNotNull);
    });

    test('**星期越界**（0 或 8）⇒ 字段错误', () {
      // DateTime.monday…sunday 是 1…7。越界值会让"这一天该不该展开"永远为假，
      // 于是规则看起来存在却一次都不发生。
      expect(
        recurrence(weekdays: const {0}).fieldErrors['weekdays'],
        isNotNull,
      );
      expect(
        recurrence(weekdays: const {8}).fieldErrors['weekdays'],
        isNotNull,
      );
      expect(
        recurrence(weekdays: const {1, 2, 3, 4, 5, 6, 7}).isValid,
        isTrue,
        reason: '七天都选是合法的',
      );
    });

    test('**间隔周数不在 1–52** ⇒ 字段错误', () {
      expect(
        recurrence(intervalWeeks: 0).fieldErrors['intervalWeeks'],
        isNotNull,
      );
      expect(
        recurrence(intervalWeeks: 53).fieldErrors['intervalWeeks'],
        isNotNull,
      );
      expect(recurrence(intervalWeeks: 1).isValid, isTrue);
      expect(recurrence(intervalWeeks: 52).isValid, isTrue);
    });

    test('**结束日期早于开始日期** ⇒ 字段错误；相等合法（只发生一次）', () {
      final from = DateTime(2026, 10, 5);
      expect(
        recurrence(
          from: from,
          until: DateTime(2026, 10, 4),
        ).fieldErrors['validUntilLocalDate'],
        isNotNull,
      );
      expect(recurrence(from: from, until: from).isValid, isTrue);
    });

    test('星期集合**不可被外部修改**', () {
      final weekdays = {DateTime.monday};
      final value = recurrence(weekdays: weekdays);
      // 改原集合不该影响草稿。
      weekdays.add(DateTime.tuesday);
      expect(value.weekdays, {DateTime.monday});
      expect(() => value.weekdays.add(DateTime.friday), throwsUnsupportedError);
    });
  });

  group('CalendarEditTarget', () {
    test('"整个系列"不需要 occurrenceStartUtc', () {
      const target = CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.entireSeries,
      );
      expect(target.occurrenceStartUtc, isNull);
      expect(target.expectedUpdatedAtUtc, isNull);
    });

    test('"这一次／此次以后"带上真实发生时间，供服务层判定缺失', () {
      final target = CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.singleOccurrence,
        occurrenceStartUtc: DateTime.utc(2026, 10, 5, 1),
        expectedUpdatedAtUtc: DateTime.utc(2026, 10, 4),
      );
      expect(target.occurrenceStartUtc, isNotNull);
      expect(target.expectedUpdatedAtUtc!.isUtc, isTrue);
    });
  });

  group('CalendarMutationResult', () {
    test('`saved` 与 `savedWithWarning` 都算**已经落库**', () {
      expect(CalendarMutationResult.saved().wasPersisted, isTrue);
      expect(CalendarMutationResult.saved().isSuccess, isTrue);
      final warned = CalendarMutationResult.savedWithWarning('变更记录失败');
      expect(
        warned.wasPersisted,
        isTrue,
        reason: '把已经写进去的改动报成"保存失败"，用户会再改一次——那会写第二遍',
      );
      expect(warned.isSuccess, isFalse, reason: '它不是完全成功：要如实告诉用户"变更记录失败"');
      expect(warned.error, contains('变更记录失败'));
    });

    test('各类失败互相可区分（界面要按类型说不同的话）', () {
      expect(
        CalendarMutationResult.failed(
          CalendarMutationStatus.stale,
          '已过期',
        ).status,
        CalendarMutationStatus.stale,
      );
      expect(
        CalendarMutationResult.failed(
          CalendarMutationStatus.unsupported,
          '未装配',
        ).wasPersisted,
        isFalse,
      );
      final invalid = CalendarMutationResult.invalid(const {'title': '不能为空'});
      expect(invalid.status, CalendarMutationStatus.invalid);
      expect(invalid.fieldErrors!['title'], '不能为空');
      expect(invalid.wasPersisted, isFalse);
    });
  });

  test('类别默认是固定日程；改写不得跨类别（保护时间保持保护时间）', () {
    expect(draft().kind, CalendarEventKind.fixed);
    final protected = CalendarEventEditDraft(
      title: '健身',
      startAtUtc: DateTime.utc(2026, 10, 5, 1),
      endAtUtc: DateTime.utc(2026, 10, 5, 2),
      timeZoneId: 'Asia/Shanghai',
      kind: CalendarEventKind.protected,
    );
    expect(protected.kind, CalendarEventKind.protected);
  });
}
