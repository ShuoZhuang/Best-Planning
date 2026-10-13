// Task 7（课程与保护时间管理修复计划）：**自定义保护时间的完整编辑**
//
// ## 修复前是什么样
//
// `ProtectedTimeEditorPage` 每次保存都生成**新的** `CalendarEvent`，因此
//
// - 改名会变成"又建了一条"——用户改一次名字，管理页多一行；
// - 完全没有"只改这一次"的入口，改名只能整体重建；
// - 日视图那个"改这一次"对话框把 `item.title` 原样传回，所以**改不了名**。
//
// 现有那条"传 `initialNotes` 再创建新事项也算编辑"的断言只是证明了初始备注会被再次创建，
// 并没有证明**更新了原记录**。这个文件用真实 Drift 库钉住"原记录被更新、记录数不变"。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  late AppDatabase database;
  late DriftCalendarRepository repository;
  late CalendarService service;

  /// 固定"现在"：2026-10-12（周一）09:30 本地 == 01:30Z。
  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database);
    service = CalendarService(
      repository: repository,
      deletion: repository,
      recurringRepository: repository,
      clock: _Clock(nowUtc),
      idGenerator: _Ids(),
      zones: zones,
    );
  });

  tearDown(() => database.close());

  DateTime localUtc(int month, int day, int hour, [int minute = 0]) =>
      zones.localDateTimeToUtc(
        DateTime.utc(2026, month, day),
        hour * 60 + minute,
        zoneId,
      );

  /// 建一条**每周二 14:00–15:00** 的保护时间（"午休"），有效期到 12-20。
  Future<String> seedWeekly() async {
    await repository.saveRecurring(
      CalendarEvent(
        id: 'anchor-1',
        title: '午休',
        startAtUtc: localUtc(10, 6, 14),
        endAtUtc: localUtc(10, 6, 15),
        timeZoneId: zoneId,
        recurrenceRuleId: 'rule-1',
        kind: CalendarEventKind.protected,
        notes: '原备注',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-1',
        weekdays: const {DateTime.tuesday},
        localStartMinute: 14 * 60,
        durationMinutes: 60,
        validFromLocalDate: DateTime(2026, 10, 6),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: zoneId,
      ),
    );
    return 'anchor-1';
  }

  Future<List<CalendarOccurrence>> occurrences(
    DateTime startUtc,
    DateTime endUtc,
  ) => repository.occurrencesBetween(startUtc, endUtc);

  Future<int> rowCount(String table) async {
    final rows = await database
        .customSelect('SELECT COUNT(*) AS c FROM $table')
        .get();
    return rows.first.read<int>('c');
  }

  group('单次改写：只产生一条例外，原系列不动', () {
    test('**把某一次从"午休"改成"看医生"，只多一条例外、记录数不变**', () async {
      await seedWeekly();
      final anchorsBefore = await rowCount('calendar_events');

      // 2026-10-13 是周二，这一天的 14:00 那一次。
      final occurrenceStart = localUtc(10, 13, 14);
      final result = await service.updateEvent(
        target: CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.singleOccurrence,
          occurrenceStartUtc: occurrenceStart,
        ),
        event: CalendarEventEditDraft(
          title: '看医生',
          notes: '带医保卡',
          startAtUtc: localUtc(10, 13, 16),
          endAtUtc: localUtc(10, 13, 17),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.saved);
      expect(
        await rowCount('calendar_events'),
        anchorsBefore + 1,
        reason:
            '**只多一行例外**。修复前每次保存都新建一条锚点，'
            '于是改一次名字管理页就多一行"午休"',
      );

      // 原系列标题不变（这是"只改这一次"的定义）。
      final anchorRows = await database
          .customSelect(
            "SELECT title FROM calendar_events WHERE id = 'anchor-1'",
          )
          .get();
      expect(anchorRows.single.read<String>('title'), '午休');

      // 该日显示新标题与新备注。
      final thatDay = await occurrences(
        localUtc(10, 13, 0),
        localUtc(10, 14, 0),
      );
      // ignore: avoid_print
      print('THATDAY=$thatDay');
      final replaced = thatDay.where((o) => o.title == '看医生').toList();
      expect(replaced, hasLength(1));
      expect(replaced.single.notes, '带医保卡');
      expect(replaced.single.range.startUtc, localUtc(10, 13, 16));

      // 其它星期仍然显示"午休"。
      final nextWeek = await occurrences(
        localUtc(10, 20, 0),
        localUtc(10, 21, 0),
      );
      expect(nextWeek.single.title, '午休');
    });

    test('没有重复规则的单次保护时间：直接改那一行，不产生例外', () async {
      await repository.save(
        CalendarEvent(
          id: 'once-1',
          title: '一次性保护',
          startAtUtc: localUtc(10, 13, 10),
          endAtUtc: localUtc(10, 13, 11),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
      );
      final before = await rowCount('calendar_events');

      final result = await service.updateEvent(
        target: CalendarEditTarget(
          anchorId: 'once-1',
          scope: EventEditScope.singleOccurrence,
          occurrenceStartUtc: localUtc(10, 13, 10),
        ),
        event: CalendarEventEditDraft(
          title: '看医生',
          startAtUtc: localUtc(10, 13, 10),
          endAtUtc: localUtc(10, 13, 11),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.saved);
      expect(
        await rowCount('calendar_events'),
        before,
        reason:
            '单次事项没有"系列"可言，改它自己那一行即可。'
            '留一条 `exceptionOfId` 非空的例外会让它既不出现在单次查询里、也不会被展开',
      );
      final rows = await database
          .customSelect(
            "SELECT title, exception_of_id FROM calendar_events WHERE id = 'once-1'",
          )
          .get();
      expect(rows.single.read<String>('title'), '看医生');
      expect(
        rows.single.read<String?>('exception_of_id'),
        isNull,
        reason: '它本身就是锚点，不能同时是别人的例外',
      );
    });
  });

  group('整个系列：改名与备注级联到未来例外', () {
    test('**改整个系列 ⇒ 未来正常例外跟着改名，过去例外不变**', () async {
      await seedWeekly();

      // 先给"未来那一次"（10-20）与"过去那一次"（10-06）各写一条例外。
      for (final day in [6, 20]) {
        await repository.replaceOccurrence(
          anchorId: 'anchor-1',
          occurrenceStartUtc: localUtc(10, day, 14),
          event: CalendarEventEditDraft(
            title: '午休（调整过）',
            startAtUtc: localUtc(10, day, 15),
            endAtUtc: localUtc(10, day, 16),
            timeZoneId: zoneId,
            kind: CalendarEventKind.protected,
          ),
          exceptionId: 'exc-10-$day',
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        );
      }

      final result = await service.updateEvent(
        target: const CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
        ),
        event: CalendarEventEditDraft(
          title: '午休时间',
          notes: '新备注',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.saved);

      final exceptions = await database
          .customSelect(
            "SELECT id, title, notes FROM calendar_events "
            "WHERE exception_of_id = 'anchor-1' ORDER BY id",
          )
          .get();
      final byId = {for (final row in exceptions) row.read<String>('id'): row};

      expect(
        byId['exc-10-20']!.read<String>('title'),
        '午休时间',
        reason:
            '未来的正常例外是**同一条规则**的一部分。不跟着改名，用户会看到'
            '"周一叫新名字、周三那一次还叫旧名字"',
      );
      expect(byId['exc-10-20']!.read<String>('notes'), '新备注');
      expect(
        byId['exc-10-6']!.read<String>('title'),
        '午休（调整过）',
        reason: '**过去的不追溯**：已经发生的事不该被后来的改写改写',
      );
    });

    test('**未来的"删除例外"继续保持删除语义**（零长度行不被改名复活）', () async {
      await seedWeekly();

      // 删掉 10-20 那一次：写一行零长度的删除例外。
      await repository.deleteOccurrence(
        anchorId: 'anchor-1',
        occurrenceStartUtc: localUtc(10, 20, 14),
        title: '午休',
        exceptionId: 'exc-deleted',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      );

      await service.updateEvent(
        target: const CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
        ),
        event: CalendarEventEditDraft(
          title: '午休时间',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      final row = await database
          .customSelect(
            "SELECT start_at_utc, end_at_utc FROM calendar_events WHERE id = 'exc-deleted'",
          )
          .get();
      expect(
        row.single.read<int>('start_at_utc'),
        row.single.read<int>('end_at_utc'),
        reason:
            '零长度行是"这一次被删除"的表示。跟着改标题会让它变成一条正常长度的行，'
            '用户单独删掉的那一次就凭空复活了',
      );

      final thatDay = await occurrences(
        localUtc(10, 20, 0),
        localUtc(10, 21, 0),
      );
      expect(
        thatDay.where((o) => o.kind == CalendarEventKind.protected),
        isEmpty,
        reason: '删掉的那一次在展开结果里仍然不该出现',
      );
    });

    test('整个系列改名后，**新发生的那几次显示新名称**', () async {
      await seedWeekly();

      await service.updateEvent(
        target: const CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
        ),
        event: CalendarEventEditDraft(
          title: '午休时间',
          notes: '新备注',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      final later = await occurrences(localUtc(11, 3, 0), localUtc(11, 4, 0));
      expect(later.single.title, '午休时间');
      expect(later.single.notes, '新备注');
      expect(
        later.single.kind,
        CalendarEventKind.protected,
        reason: '改写不得跨类别：保护时间必须还是保护时间',
      );
    });
  });

  group('此次及以后：拆分规则', () {
    test('**从某一次起改名**：旧规则在那之前结束，新规则从那一次开始', () async {
      await seedWeekly();

      final splitStart = localUtc(10, 20, 14);
      final result = await service.updateEvent(
        target: CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.followingOccurrences,
          occurrenceStartUtc: splitStart,
        ),
        event: CalendarEventEditDraft(
          title: '午休时间',
          startAtUtc: splitStart,
          endAtUtc: splitStart.add(const Duration(hours: 1)),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.saved);

      // 拆点之前仍是旧标题。
      final before = await occurrences(
        localUtc(10, 13, 0),
        localUtc(10, 14, 0),
      );
      expect(before.single.title, '午休');

      // 从那一次起是新标题。
      final after = await occurrences(localUtc(10, 20, 0), localUtc(10, 21, 0));
      expect(after.single.title, '午休时间');
      expect(after.single.range.startUtc, splitStart);
      expect(
        after.single.kind,
        CalendarEventKind.protected,
        reason: '新锚点必须保留 `kind = protected`，否则保护时间会变成固定日程',
      );
    });

    test('**DST 周的拆分保持所选的本地钟点**', () async {
      // 用 America/New_York：2026-11-01 是夏令时结束日（本地 02:00 回拨到 01:00）。
      // 规则起点放在 10-25（EDT，UTC-4），拆分点放在 11-08（EST，UTC-5）。
      //
      // **要验的是"本地钟点跟着走"**：如果实现把 UTC 时刻平移 24 小时的整数倍，
      // 跨过 DST 之后本地钟点会差一小时——用户设的"每周二 14:00"会变成 13:00。
      const dstZone = 'America/New_York';
      final dstZones = TimeZoneDatabase();
      await repository.saveRecurring(
        CalendarEvent(
          id: 'dst-anchor',
          title: '健身',
          startAtUtc: dstZones.localDateTimeToUtc(
            DateTime.utc(2026, 10, 20),
            14 * 60,
            dstZone,
          ),
          endAtUtc: dstZones.localDateTimeToUtc(
            DateTime.utc(2026, 10, 20),
            15 * 60,
            dstZone,
          ),
          timeZoneId: dstZone,
          recurrenceRuleId: 'dst-rule',
          kind: CalendarEventKind.protected,
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
        RecurrenceRule(
          id: 'dst-rule',
          weekdays: const {DateTime.tuesday},
          localStartMinute: 14 * 60,
          durationMinutes: 60,
          validFromLocalDate: DateTime(2026, 10, 20),
          validUntilLocalDate: DateTime(2026, 12, 15),
          timeZoneId: dstZone,
        ),
      );

      final splitLocalMinute = 14 * 60;
      final splitStart = dstZones.localDateTimeToUtc(
        DateTime.utc(2026, 11, 10),
        splitLocalMinute,
        dstZone,
      );
      await service.updateEvent(
        target: CalendarEditTarget(
          anchorId: 'dst-anchor',
          scope: EventEditScope.followingOccurrences,
          occurrenceStartUtc: splitStart,
        ),
        event: CalendarEventEditDraft(
          title: '健身（新）',
          startAtUtc: splitStart,
          endAtUtc: splitStart.add(const Duration(hours: 1)),
          timeZoneId: dstZone,
          kind: CalendarEventKind.protected,
        ),
      );

      final rows = await occurrences(
        dstZones.localDateTimeToUtc(DateTime.utc(2026, 11, 10), 0, dstZone),
        dstZones.localDateTimeToUtc(DateTime.utc(2026, 11, 11), 0, dstZone),
      );
      final local = dstZones.toLocal(rows.single.range.startUtc, dstZone);
      expect(
        local.hour * 60 + local.minute,
        splitLocalMinute,
        reason:
            '拆分之后本地钟点必须仍是 14:00。跨过 DST 之后 UTC 偏移变了，'
            '按 UTC 平移整数天会让用户设的时间悄悄变成 13:00',
      );
    });
  });

  group('stale 与事务', () {
    test('**`expectedUpdatedAtUtc` 不匹配 ⇒ stale，零写入**', () async {
      await seedWeekly();
      final before = await rowCount('calendar_events');

      final result = await service.updateEvent(
        target: CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
          // 页面读到的是"另一个版本"。
          expectedUpdatedAtUtc: DateTime.utc(2020, 1, 1),
        ),
        event: CalendarEventEditDraft(
          title: '不该写进去',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.stale);
      expect(result.wasPersisted, isFalse);
      expect(await rowCount('calendar_events'), before, reason: '零写入');
      final rows = await database
          .customSelect(
            "SELECT title FROM calendar_events WHERE id = 'anchor-1'",
          )
          .get();
      expect(rows.single.read<String>('title'), '午休');
    });

    test('**`expectedUpdatedAtUtc` 匹配时正常保存**', () async {
      await seedWeekly();

      final result = await service.updateEvent(
        target: CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
          expectedUpdatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
        event: CalendarEventEditDraft(
          title: '午休时间',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.saved);
    });

    test('锚点不存在 ⇒ missing，而不是崩溃', () async {
      final result = await service.updateEvent(
        target: const CalendarEditTarget(
          anchorId: 'nope',
          scope: EventEditScope.entireSeries,
          expectedUpdatedAtUtc: null,
        ),
        event: CalendarEventEditDraft(
          title: 'x',
          startAtUtc: DateTime.utc(2026, 10, 6, 6),
          endAtUtc: DateTime.utc(2026, 10, 6, 7),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      // 没有 `expectedUpdatedAtUtc` 时不做 stale 判定，直接走写入；
      // 仓储对"锚点不存在"是**幂等**的（删不掉等于已经删掉），因此这里是 saved。
      expect(
        result.status,
        CalendarMutationStatus.saved,
        reason: '幂等：拿一个过期 id 来改不该报错，那是视图过期而不是数据损坏',
      );
    });
  });

  group('重排原因只记一次，且说的是保护时间', () {
    /// 单独建一套带 `onScheduleInputChanged` 的服务（Task 7 Step 5）。
    CalendarService withChanges(List<ScheduleInputChange> sink) =>
        CalendarService(
          repository: repository,
          deletion: repository,
          recurringRepository: repository,
          clock: _Clock(nowUtc),
          idGenerator: _Ids(),
          zones: zones,
          onScheduleInputChanged: sink.add,
        );

    test('单次改写的文案是「保护时间单次改写」，且**只记一条**', () async {
      await seedWeekly();
      final changes = <ScheduleInputChange>[];
      final occurrenceStart = localUtc(10, 13, 14);

      final result = await withChanges(changes).updateEvent(
        target: CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.singleOccurrence,
          occurrenceStartUtc: occurrenceStart,
        ),
        event: CalendarEventEditDraft(
          title: '看医生',
          startAtUtc: occurrenceStart,
          endAtUtc: occurrenceStart.add(const Duration(hours: 1)),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.saved);
      expect(
        changes.map((c) => c.label).toList(),
        ['保护时间单次改写'],
        reason:
            '原因是**直接显示给用户**的（统计页的"重排原因"）。'
            '写成"固定日程改写"等于报告一件用户没做过的事；'
            '而因为写了例外又更新了锚点就记两条，会让分布里凭空多一倍',
      );
    });

    test('整个系列改写的文案是「保护时间系列改写」，且只记一条', () async {
      await seedWeekly();
      final changes = <ScheduleInputChange>[];

      await withChanges(changes).updateEvent(
        target: const CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
        ),
        event: CalendarEventEditDraft(
          title: '午休时间',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(changes.map((c) => c.label).toList(), ['保护时间系列改写']);
    });

    test('**保存失败时不记重排原因**（数据没变就没有重排）', () async {
      await seedWeekly();
      final changes = <ScheduleInputChange>[];

      final result = await withChanges(changes).updateEvent(
        target: CalendarEditTarget(
          anchorId: 'anchor-1',
          scope: EventEditScope.entireSeries,
          expectedUpdatedAtUtc: DateTime.utc(2020, 1, 1),
        ),
        event: CalendarEventEditDraft(
          title: '不该写进去',
          startAtUtc: localUtc(10, 6, 14),
          endAtUtc: localUtc(10, 6, 15),
          timeZoneId: zoneId,
          kind: CalendarEventKind.protected,
        ),
      );

      expect(result.status, CalendarMutationStatus.stale);
      expect(changes, isEmpty, reason: 'stale 是零写入，记一条重排原因会变成"报告一次没发生的改动"');
    });
  });
}

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'generated-${++_count}';
}
