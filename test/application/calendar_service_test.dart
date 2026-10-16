// Task 2（课程与保护时间管理修复计划 Step 3）：**服务层按范围分派与失败区分**。
//
// 这一层此前只有"返回 true/false"这一条信息，于是"过期"与"端口没装配"与"事务失败"
// 在界面上不可区分。计划 §5 的失败表要求它们给**不同的**用户可见文案与不同的数据结果；
// 这里逐条钉住。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

void main() {
  CalendarService service({
    CalendarEventDeletion? deletion,
    void Function(ScheduleInputChange change)? onChanged,
  }) => CalendarService(
    repository: const _NoopRepository(),
    deletion: deletion,
    clock: const _Clock(),
    idGenerator: _Ids(),
    zones: TimeZoneDatabase(),
    onScheduleInputChanged: onChanged,
  );

  CalendarEventPatch draft({String title = '数据结构课'}) =>
      CalendarEventPatch(
        title: title,
        startAtUtc: DateTime.utc(2026, 10, 5, 1),
        endAtUtc: DateTime.utc(2026, 10, 5, 2),
      );

  test('草稿非法 ⇒ invalid，**不碰端口**', () async {
    final spy = _DeletionSpy();
    final result = await service(deletion: spy).updateEvent(
      target: const CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.entireSeries,
      ),
      patch: draft(title: '   '),
    );

    expect(result.status, CalendarMutationStatus.invalid);
    expect(result.fieldErrors!['title'], isNotNull);
    expect(spy.calls, isEmpty, reason: '校验没过就一个端口都不该被调用');
  });

  test('**缺 occurrenceStartUtc** 的"这一次／此次以后" ⇒ invalid（不猜日期）', () async {
    final spy = _DeletionSpy();
    for (final scope in [
      EventEditScope.singleOccurrence,
      EventEditScope.followingOccurrences,
    ]) {
      final result = await service(deletion: spy).updateEvent(
        target: CalendarEditTarget(anchorId: 'a1', scope: scope),
        patch: draft(),
      );
      expect(
        result.status,
        CalendarMutationStatus.invalid,
        reason:
            '缺少真实发生时间时猜一个日期，会让例外落在用户没看着的那一天上，'
            '而界面上什么都不会提示（scope=$scope）',
      );
      expect(result.fieldErrors!['occurrenceStartUtc'], isNotNull);
    }
    expect(spy.calls, isEmpty);
  });

  test('端口未装配 ⇒ unsupported（不是"保存失败"）', () async {
    final result = await service().updateEvent(
      target: const CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.entireSeries,
      ),
      patch: draft(),
    );

    expect(result.status, CalendarMutationStatus.unsupported);
    expect(result.error, contains('未装配'));
    expect(result.wasPersisted, isFalse);
  });

  test('按范围分派到对应端口，并带上完整草稿', () async {
    final spy = _DeletionSpy();
    final occurrence = DateTime.utc(2026, 10, 12, 1);

    await service(deletion: spy).updateEvent(
      target: CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.singleOccurrence,
        occurrenceStartUtc: occurrence,
      ),
      patch: draft(title: '看医生'),
    );
    expect(spy.calls, ['replaceOccurrence:a1:看医生']);

    spy.calls.clear();
    await service(deletion: spy).updateEvent(
      target: CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.followingOccurrences,
        occurrenceStartUtc: occurrence,
      ),
      patch: draft(title: '看医生'),
    );
    expect(spy.calls, ['replaceFollowingOccurrences:a1:看医生']);

    spy.calls.clear();
    await service(deletion: spy).updateEvent(
      target: const CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.entireSeries,
      ),
      patch: draft(title: '看医生'),
      recurrence: RecurrenceEditDraft(
        weekdays: const {DateTime.tuesday},
        validFromLocalDate: DateTime(2026, 10, 6),
      ),
    );
    expect(spy.calls, ['replaceSeries:a1:看医生'], reason: '系列改写要连规则一起传下去');
  });

  test('**成功后才记重排原因，且只记一次**', () async {
    final changes = <String>[];
    final spy = _DeletionSpy();
    final result =
        await service(
          deletion: spy,
          onChanged: (change) => changes.add(change.label),
        ).updateEvent(
          target: const CalendarEditTarget(
            anchorId: 'a1',
            scope: EventEditScope.entireSeries,
          ),
          patch: draft(),
        );

    expect(result.status, CalendarMutationStatus.saved);
    expect(
      changes,
      ['固定日程系列改写'],
      reason:
          '更新锚点和例外只算**一次**改写。记多条会让统计里的"重排原因"分布失真。'
          '（文案沿用既有实现：`_reportChange` 会加上"固定日程"前缀，'
          'Task 7 再让它对保护时间说"保护时间…"，两条路径因此各自可辨。）',
    );
  });

  test('**端口抛错 ⇒ failed，且不记重排原因**（数据没变就没有重排）', () async {
    final changes = <String>[];
    final spy = _DeletionSpy()..throwOnReplace = true;
    final result =
        await service(
          deletion: spy,
          onChanged: (change) => changes.add(change.label),
        ).updateEvent(
          target: const CalendarEditTarget(
            anchorId: 'a1',
            scope: EventEditScope.entireSeries,
          ),
          patch: draft(),
        );

    expect(result.status, CalendarMutationStatus.failed);
    expect(result.error, contains('原内容未改变'));
    expect(result.wasPersisted, isFalse);
    expect(changes, isEmpty);
  });

  test('**写入成功但重排原因回调抛错 ⇒ savedWithWarning**（不谎称保存失败）', () async {
    final spy = _DeletionSpy();
    final result =
        await service(
          deletion: spy,
          onChanged: (_) => throw StateError('统计模块炸了'),
        ).updateEvent(
          target: const CalendarEditTarget(
            anchorId: 'a1',
            scope: EventEditScope.entireSeries,
          ),
          patch: draft(),
        );

    expect(
      result.status,
      CalendarMutationStatus.savedWithWarning,
      reason:
          '数据**已经落库**。把它报成"保存失败"会让用户再改一次，而那会写第二遍——'
          '计划 §5 的失败表最后一行就是这个场景',
    );
    expect(result.wasPersisted, isTrue);
    expect(spy.calls, hasLength(1), reason: '写入确实发生了');
    expect(result.error, contains('已保存'));
  });

  test('规则草稿非法时同样零写入', () async {
    final spy = _DeletionSpy();
    final result = await service(deletion: spy).updateEvent(
      target: const CalendarEditTarget(
        anchorId: 'a1',
        scope: EventEditScope.entireSeries,
      ),
      patch: draft(),
      recurrence: RecurrenceEditDraft(
        weekdays: const {},
        validFromLocalDate: DateTime(2026, 10, 6),
      ),
    );

    expect(result.status, CalendarMutationStatus.invalid);
    expect(result.fieldErrors!['weekdays'], isNotNull);
    expect(spy.calls, isEmpty);
  });
}

final class _Clock implements Clock {
  const _Clock();
  // 注入的时钟必须是**当前**时刻，否则 `_reportChange` 之类会拿到历史时间。
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 12, 1);
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'generated-${++_count}';
}

final class _NoopRepository implements CalendarRepository {
  const _NoopRepository();

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _DeletionSpy implements CalendarEventDeletion {
  final List<String> calls = [];
  bool throwOnReplace = false;

  @override
  Future<void> deleteEvent(String eventId) async {}

  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async {}

  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {
    if (throwOnReplace) throw StateError('数据库炸了');
    calls.add('replaceOccurrence:$anchorId:${patch.title}');
  }

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    DateTime? updateExceptionsFromUtc,
    required DateTime updatedAtUtc,
  }) async {
    if (throwOnReplace) throw StateError('数据库炸了');
    calls.add('replaceSeries:$anchorId:${patch.title}');
  }

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
  }) async {
    if (throwOnReplace) throw StateError('数据库炸了');
    calls.add('replaceFollowingOccurrences:$anchorId:${patch.title}');
  }

  @override
  Future<void> setEventArea({
    required String eventId,
    required String? areaId,
    required DateTime updatedAtUtc,
  }) async {}
}
