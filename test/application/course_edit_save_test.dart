// Task 4（课程与保护时间管理修复计划）：**整门课程资料的事务性编辑**（服务层编排）。
//
// 仓储那一半（一个事务换掉四条表、保住例外、回滚）在 `course_write_gateway_test.dart`
// 里用真实库验；这里验**编排的顺序与取舍**：
//
// 1. **顺序不可改变**：先判过期（stale ⇒ 零写入），再校验字段，最后才写；
// 2. **指纹与逐锚点两级过期检测**；
// 3. **预览的四个数**（新增／删除／更新片段数、受影响课次变化、会删掉的例外数）；
// 4. **失败时如实说"原内容未改变"**。
//
// 用**真实 drift 库**做端到端那两条：只有真的写入，"零写入"才有意义。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';

void main() {
  const zoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();
  late AppDatabase database;
  late DriftCalendarRepository repository;
  late DriftCourseSeriesRepository courses;
  late CourseManagementService service;

  final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftCalendarRepository(database, zones: TimeZoneDatabase());
    courses = DriftCourseSeriesRepository(
      database,
      clock: _Clock(nowUtc),
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
    );
    service = CourseManagementService(
      courses: courses,
      calendar: CalendarService(
        repository: repository,
        deletion: repository,
        recurringRepository: repository,
        clock: _Clock(nowUtc),
        idGenerator: _Ids(),
        zones: TimeZoneDatabase(),
      ),
      deletion: repository,
      gateway: repository,
      zones: TimeZoneDatabase(),
      timeZoneId: zoneId,
      clock: _Clock(nowUtc),
    );

    await database.customInsert('''
      INSERT INTO academic_terms
        (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
         created_at_utc, updated_at_utc)
      VALUES ('term-autumn', '2026 秋季学期', '2026-09-07', 16,
              'Asia/Shanghai', 1, 1)
    ''');
    await database.customInsert('''
      INSERT INTO timetable_import_batches
        (id, term_id, source_image_hash, source_file_name, status,
         created_event_count, created_at_utc, updated_at_utc)
      VALUES ('batch-autumn', 'term-autumn', 'sha256:x', 'schedule.png',
              'committed', 2, 1, 1)
    ''');
  });

  tearDown(() => database.close());

  Future<void> seedSegment({
    required String eventId,
    required String ruleId,
    Set<int> weekdays = const {DateTime.monday},
    int startMinute = 8 * 60,
    int durationMinutes = 45,
    int intervalWeeks = 1,

    /// `null` 表示"这条锚点没有批次归属"——旧缺陷造成的混合来源形状（§2.1）。
    String? batchId = 'batch-autumn',
  }) async {
    await repository.saveRecurring(
      CalendarEvent(
        id: eventId,
        title: '高等数学(上)',
        startAtUtc: DateTime.utc(2026, 9, 7, 0),
        endAtUtc: DateTime.utc(2026, 9, 7, 0, 45),
        timeZoneId: zoneId,
        recurrenceRuleId: ruleId,
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: batchId,
        logicalCourseId: 'course-calc',
        notes: '赵敏',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: ruleId,
        weekdays: weekdays,
        localStartMinute: startMinute,
        durationMinutes: durationMinutes,
        intervalWeeks: intervalWeeks,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: zoneId,
      ),
    );
  }

  CourseScheduleDraft draft({
    int startMinute = 8 * 60,
    int? endMinute,
    Set<int> weekdays = const {DateTime.monday},
    int intervalWeeks = 1,
  }) => CourseScheduleDraft(
    startMinute: startMinute,
    endMinute: endMinute ?? startMinute + 45,
    weekdays: weekdays,
    intervalWeeks: intervalWeeks,
    validFromLocalDate: DateTime(2026, 9, 7),
    validUntilLocalDate: DateTime(2026, 12, 20),
  );

  /// 用**详情自己**的修订号与指纹组装请求——这就是"页面刚打开"的状态。
  Future<CourseSaveRequest> requestFor(
    List<CourseScheduleDraft> schedule, {
    String title = '高等数学(上)',
    String teacher = '赵敏',
    Map<String, DateTime>? revisions,
    String? fingerprint,
  }) async {
    final detail = await courses.findCourse('course-calc');
    return CourseSaveRequest(
      logicalCourseId: 'course-calc',
      expectedRevisions: revisions ?? detail!.sourceRevisions,
      expectedFingerprint: fingerprint ?? detail!.revisionFingerprint,
      profile: CourseProfileDraft(
        logicalCourseId: 'course-calc',
        title: title,
        teacher: teacher,
        schedule: schedule,
      ),
    );
  }

  Future<List<String>> segmentIds() async {
    final rows = await database
        .customSelect(
          'SELECT id FROM calendar_events WHERE exception_of_id IS NULL '
          'ORDER BY id',
        )
        .get();
    return [for (final row in rows) row.read<String>('id')];
  }

  Future<List<String>> batchIdsOfCourse(String logicalCourseId) async {
    final rows = await database
        .customSelect(
          "SELECT import_batch_id FROM calendar_events "
          "WHERE exception_of_id IS NULL AND logical_course_id = "
          "'$logicalCourseId' ORDER BY id",
        )
        .get();
    return [for (final row in rows) row.read<String?>('import_batch_id') ?? ''];
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Task 6（课程编辑完整性修复计划）：**来源解析与统一**（P2、P3）
  // ───────────────────────────────────────────────────────────────────────────

  group('课程来源（计划 §2.1）', () {
    test('P2：一空一非空的存量数据可以保存，并在成功事务里统一来源', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      // 旧缺陷造成的第二个片段：同一个课程、**没有批次**。
      await seedSegment(
        eventId: 'evt-b',
        ruleId: 'rule-b',
        weekdays: const {DateTime.wednesday},
        batchId: null,
      );
      expect(await batchIdsOfCourse('course-calc'), ['batch-autumn', '']);

      final result = await service.saveCourse(
        await requestFor([
          draft(startMinute: 8 * 60),
          draft(startMinute: 8 * 60, weekdays: const {DateTime.wednesday}),
        ]),
      );

      expect(result.isSuccess, isTrue, reason: result.error ?? '');
      expect(await batchIdsOfCourse('course-calc'), [
        'batch-autumn',
        'batch-autumn',
      ], reason: '成功事务把全部最终片段统一到那个唯一批次（§2.1）');
      final detail = await courses.findCourse('course-calc');
      expect(
        resolveCourseLineage([
          for (final segment in detail!.segments) segment.importBatchId,
        ]).state,
        CourseLineageState.imported,
        reason: '保存一次之后这门课不再处于混合来源',
      );
    });

    test('P3：两个不同的非空批次 ⇒ 阻止保存、零写入、给出可执行的一句话', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await database.customInsert('''
        INSERT INTO timetable_import_batches
          (id, term_id, source_image_hash, source_file_name, status,
           created_event_count, created_at_utc, updated_at_utc)
        VALUES ('batch-other', 'term-autumn', 'sha256:y', 'other.png',
                'committed', 1, 1, 1)
      ''');
      await seedSegment(
        eventId: 'evt-b',
        ruleId: 'rule-b',
        weekdays: const {DateTime.wednesday},
        batchId: 'batch-other',
      );
      final before = await segmentIds();
      final beforeBatches = await batchIdsOfCourse('course-calc');

      final result = await service.saveCourse(
        await requestFor([
          draft(startMinute: 10 * 60),
          draft(startMinute: 10 * 60, weekdays: const {DateTime.wednesday}),
        ]),
      );

      expect(result.status, CourseSaveStatus.integrityConflict);
      expect(result.error, contains('多个导入批次'));
      expect(result.error, contains('备份'));
      expect(
        result.error,
        isNot(contains('evt-')),
        reason: '界面不得显示内部 id（规范全局不变量第 7 条）',
      );
      expect(await segmentIds(), before, reason: '零写入');
      expect(await batchIdsOfCourse('course-calc'), beforeBatches);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 11／LI3（计划 §2.0.3 路径一）：**手工修复一次事务保存，修复后提示消失**
  // ───────────────────────────────────────────────────────────────────────────

  test('LI3：受损课程补全资料后重读，确定性问题消失且其它字段不被顺手改掉', () async {
    await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
    // 造出旧版损伤的确定形状：占位标题 ＋ 事件时区与规则时区不一致。
    await database.customStatement(
      "UPDATE calendar_events SET title = '未命名事项', time_zone_id = 'UTC' "
      "WHERE id = 'evt-a'",
    );

    final damaged = await courses.findCourse('course-calc');
    expect(damaged!.hasLegacyPlaceholderTitle, isTrue);
    expect(
      damaged.integrityIssues.map((issue) => issue.kind),
      contains(CourseIntegrityIssueKind.eventRuleTimeZoneMismatch),
    );

    final result = await service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: damaged.sourceRevisions,
        expectedFingerprint: damaged.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '算法与数据结构',
          teacher: '张老师',
          location: '教一 302',
          schedule: [draft()],
        ),
      ),
    );

    expect(result.isSuccess, isTrue, reason: result.error ?? '');
    final repaired = await courses.findCourse('course-calc');
    expect(
      repaired!.hasIntegrityIssues,
      isFalse,
      reason: '只有所有确定性问题都消失，提示条才该移除（Task 4 Step 3）',
    );
    expect(repaired.summary.title, '算法与数据结构');
    expect(repaired.segments.single.teacher, '张老师');
    expect(repaired.segments.single.location, '教一 302');
    expect(
      repaired.segments.single.timeZoneId,
      zoneId,
      reason: '保存时把事件时区对齐到规则时区，两处不再分家',
    );
    expect(
      repaired.segments.single.importBatchId,
      'batch-autumn',
      reason: '手工修复资料不该把导入课程变成手工课程（C16）',
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Task 8（计划 §2.5／§3.3）：**预览分开报两类例外删除**，并守住 E5 的并发变化
  // ───────────────────────────────────────────────────────────────────────────

  group('例外清理的预览与过期（E1、E5）', () {
    Future<int> exceptionCount(String anchorId) async {
      final rows = await database
          .customSelect(
            "SELECT COUNT(*) AS c FROM calendar_events "
            "WHERE exception_of_id = '$anchorId'",
          )
          .get();
      return rows.first.read<int>('c');
    }

    /// 给 [anchorId] 在 [localDate] 那一天写一条"改到 14:00"的例外。
    Future<void> addException(String anchorId, String id, DateTime localDate) =>
        repository.replaceOccurrence(
          anchorId: anchorId,
          occurrenceStartUtc: zones.localDateTimeToUtc(
            localDate,
            8 * 60,
            zoneId,
          ),
          patch: CalendarEventPatch(
            title: '高等数学(上)',
            startAtUtc: zones.localDateTimeToUtc(localDate, 14 * 60, zoneId),
            endAtUtc: zones.localDateTimeToUtc(localDate, 15 * 60, zoneId),
          ),
          exceptionId: id,
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        );

    test('预览把"随片段删除的例外"与"超出新周次的例外"分开计数', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await seedSegment(
        eventId: 'evt-b',
        ruleId: 'rule-b',
        weekdays: const {DateTime.wednesday},
      );
      // evt-a 名下两条例外：09-07 与 09-14。
      await addException('evt-a', 'exc-1', DateTime(2026, 9, 7));
      await addException('evt-a', 'exc-2', DateTime(2026, 9, 14));
      // evt-b 名下一条：删掉那一段时它会一起消失。
      await addException('evt-b', 'exc-3', DateTime(2026, 9, 9));

      final detail = await courses.findCourse('course-calc');
      final preview = await service.previewCourseEdit(
        CourseSaveRequest(
          logicalCourseId: 'course-calc',
          expectedRevisions: detail!.sourceRevisions,
          expectedFingerprint: detail.revisionFingerprint,
          profile: CourseProfileDraft(
            logicalCourseId: 'course-calc',
            title: '高等数学(上)',
            // 只保留周一那一段，并把有效期缩到 09-07：09-14 的那条例外因此失效。
            schedule: [
              CourseScheduleDraft(
                startMinute: 8 * 60,
                endMinute: 8 * 60 + 45,
                weekdays: const {DateTime.monday},
                validFromLocalDate: DateTime(2026, 9, 7),
                validUntilLocalDate: DateTime(2026, 9, 7),
              ),
            ],
          ),
        ),
      );

      expect(preview, isNotNull);
      expect(
        preview!.removedSegmentExceptionCount,
        1,
        reason: '周三那一段被整段删除，它名下的 1 条例外随之消失',
      );
      expect(
        preview.invalidatedRetainedExceptionCount,
        1,
        reason: '周一那一段保留，但 09-14 已超出新周次，将被清理',
      );
      expect(
        preview.removedExceptionCount,
        2,
        reason: '总数是派生值：两个分量各自可测，总数因此不可能与它们不一致',
      );
      expect(preview.removedSegments, 1);
      expect(preview.updatedSegments, 1);
      // **预览是只读的**：一条例外都不许被它删掉。
      expect(await exceptionCount('evt-a'), 2);
      expect(await exceptionCount('evt-b'), 1);
    });

    test('E5：预览之后別处新增一条例外 ⇒ 保存判为 stale 且零写入', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final request = await requestFor([draft(startMinute: 10 * 60)]);
      expect(await service.previewCourseEdit(request), isNotNull);

      // 用户在预览之后、确认之前，从日视图给这次课加了一条逐次调整。
      await addException('evt-a', 'exc-late', DateTime(2026, 9, 7));
      final beforeRules = await database
          .customSelect('SELECT COUNT(*) AS c FROM recurrence_rules')
          .get();

      final result = await service.saveCourse(request);

      expect(
        result.status,
        CourseSaveStatus.stale,
        reason:
            '指纹含例外修订：不比它就会按旧结论保存，而那条新调整落在新规则之外，'
            '会被当作"失效例外"悄悄删掉',
      );
      expect(await exceptionCount('evt-a'), 1, reason: '零写入：那条调整必须还在');
      expect(
        (await database
                .customSelect('SELECT COUNT(*) AS c FROM recurrence_rules')
                .get())
            .first
            .read<int>('c'),
        beforeRules.first.read<int>('c'),
        reason: '规则也没被动过',
      );
    });

    test('E5：**删一条再加一条**（条数不变）同样判为过期', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await addException('evt-a', 'exc-1', DateTime(2026, 9, 7));
      final request = await requestFor([draft(startMinute: 10 * 60)]);
      expect(await service.previewCourseEdit(request), isNotNull);

      // 删掉原例外的同时补一条**不同日期**的例外：数量相同、内容不同。
      await repository.deleteEvent('exc-1');
      await addException('evt-a', 'exc-2', DateTime(2026, 9, 14));

      final result = await service.saveCourse(request);

      expect(
        result.status,
        CourseSaveStatus.stale,
        reason: '只比条数会让这种情况漏判，而"用户逐次调整过的内容"已经换了一批',
      );
      expect(await exceptionCount('evt-a'), 1);
    });

    test('E5：纯查询顺序变化不改变指纹', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await addException('evt-a', 'exc-1', DateTime(2026, 9, 7));

      final first = (await courses.findCourse('course-calc'))!
          .revisionFingerprint;
      final second = (await courses.findCourse('course-calc'))!
          .revisionFingerprint;

      expect(first, second, reason: '指纹整体排序后拼接，因此仓储返回顺序不参与判定');
      expect(first, isNotEmpty);
    });
  });

  group('顺序：先判过期，再校验，最后才写', () {
    test('**指纹不匹配 ⇒ stale 且零写入**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final before = await segmentIds();

      final result = await service.saveCourse(
        await requestFor(
          [draft(startMinute: 10 * 60)],
          // 页面打开的是"上一版"。
          fingerprint: 'stale-fingerprint',
        ),
      );

      expect(result.status, CourseSaveStatus.stale);
      expect(await segmentIds(), before);
    });

    test('**单个锚点的修订号不匹配 ⇒ stale 且零写入**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final before = await segmentIds();

      final result = await service.saveCourse(
        await requestFor(
          [draft(startMinute: 10 * 60)],
          revisions: {'evt-a': DateTime.utc(2020, 1, 1)},
        ),
      );

      expect(result.status, CourseSaveStatus.stale);
      expect(result.error, contains('重新打开'), reason: 'stale 要用户做的事是重新打开，而不是重试');
      expect(await segmentIds(), before);
    });

    test('**过期优先于字段错误**：两个都错时报 stale', () async {
      // 把校验放在过期判定之前会有一个坏结果：用户基于**过期数据**填的表单
      // 先收到"字段错误"，修完再保存才发现"其实早该重新打开"——白改一遍。
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

      final result = await service.saveCourse(
        await requestFor(
          [draft()],
          // 空标题（字段错误）＋ 过期指纹。
          title: '   ',
          fingerprint: 'stale-fingerprint',
        ),
      );

      expect(
        result.status,
        CourseSaveStatus.stale,
        reason: '过期先判。先报字段错误会让用户白改一遍再发现要重新打开',
      );
    });

    test('**字段错误时报 invalid 并给出字段名，且零写入**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final before = await segmentIds();

      final result = await service.saveCourse(
        await requestFor([draft()], title: '   '),
      );

      expect(result.status, CourseSaveStatus.invalid);
      expect(result.fieldErrors, contains('title'));
      expect(await segmentIds(), before, reason: '校验在写之前');
    });

    test('**课程不存在 ⇒ stale**（而不是崩溃或静默成功）', () async {
      final result = await service.saveCourse(
        CourseSaveRequest(
          logicalCourseId: 'nope',
          expectedRevisions: const {},
          expectedFingerprint: '',
          profile: CourseProfileDraft(
            logicalCourseId: 'nope',
            title: 'x',
            schedule: [draft()],
          ),
        ),
      );

      expect(result.status, CourseSaveStatus.stale);
      expect(result.error, contains('重新打开'));
    });
  });

  group('端到端：真的写进去，且保住既有锚点', () {
    test('**改名与换教师**：原锚点 id 不变、notes 跟着变', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

      final result = await service.saveCourse(
        await requestFor([draft()], title: '高等数学(下)', teacher: '李娜'),
      );

      expect(result.status, CourseSaveStatus.saved);
      expect(await segmentIds(), ['evt-a'], reason: '沿用原 id，不新建');
      final row = await database
          .customSelect(
            "SELECT title, notes FROM calendar_events WHERE id = 'evt-a'",
          )
          .get();
      expect(row.single.read<String>('title'), '高等数学(下)');
      expect(row.single.read<String>('notes'), '李娜');
    });

    test('**换时间**：同一条规则被改写，锚点与规则 id 都不变', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

      final result = await service.saveCourse(
        await requestFor([draft(startMinute: 14 * 60)]),
      );

      expect(result.status, CourseSaveStatus.saved);
      final rules = await database
          .customSelect(
            'SELECT id, local_start_minute, duration_minutes FROM recurrence_rules',
          )
          .get();
      expect(rules, hasLength(1), reason: '规则条数不变：改的是同一门课的同一段');
      expect(
        rules.single.read<String>('id'),
        'rule-a',
        reason:
            '**时间不是匹配键**。把它算进键会让"周一 08:00 改到 14:00"被识别成'
            '"删旧片段、加新片段"，于是既有锚点名下的例外全部消失——'
            '而改时间正是这个功能最主要的用途',
      );
      expect(rules.single.read<int>('local_start_minute'), 14 * 60);
      expect(rules.single.read<int>('duration_minutes'), 45);
    });

    test('**改时间之后，用户逐次调整过的例外还在**', () async {
      // 这一条是"时间不是匹配键"的**实际收益**，也是它值得存在的原因：
      // 把时间算进键会让改时间变成"删旧片段、加新片段"，而旧锚点名下的例外
      // 会随之全部消失——用户之前一个个改过的内容就没了。
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await repository.replaceOccurrence(
        anchorId: 'evt-a',
        occurrenceStartUtc: DateTime.utc(2026, 9, 14, 0),
        patch: CalendarEventPatch(
          title: '高等数学(上)',
          startAtUtc: DateTime.utc(2026, 9, 14, 3),
          endAtUtc: DateTime.utc(2026, 9, 14, 3, 45),
        ),
        exceptionId: 'exc-1',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      );

      final result = await service.saveCourse(
        await requestFor([draft(startMinute: 14 * 60)]),
      );

      expect(result.status, CourseSaveStatus.saved);
      final exceptions = await database
          .customSelect(
            "SELECT COUNT(*) AS c FROM calendar_events "
            "WHERE exception_of_id = 'evt-a'",
          )
          .get();
      expect(
        exceptions.first.read<int>('c'),
        1,
        reason:
            '例外挂在原锚点上。锚点没被换掉，因此它还在——'
            '锚点被换掉的话，用户那次单独调整就静默丢了',
      );
    });

    test('**增删片段**：一条变两条，再变回一条', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final added = draft(
        startMinute: 14 * 60,
        weekdays: const {DateTime.wednesday},
      );

      expect(
        (await service.saveCourse(await requestFor([draft(), added]))).status,
        CourseSaveStatus.saved,
      );
      expect(await segmentIds(), ['course-calc-1', 'evt-a']);

      // 再回到一条：新增的那条连同它的规则一起消失。
      final detail = await courses.findCourse('course-calc');
      expect(
        (await service.saveCourse(
          CourseSaveRequest(
            logicalCourseId: 'course-calc',
            expectedRevisions: detail!.sourceRevisions,
            expectedFingerprint: detail.revisionFingerprint,
            profile: CourseProfileDraft(
              logicalCourseId: 'course-calc',
              title: '高等数学(上)',
              teacher: '赵敏',
              schedule: [draft()],
            ),
          ),
        )).status,
        CourseSaveStatus.saved,
      );
      expect(await segmentIds(), ['evt-a']);
      final rules = await database
          .customSelect('SELECT COUNT(*) AS c FROM recurrence_rules')
          .get();
      expect(rules.first.read<int>('c'), 1);
    });
  });

  group('影响预览：四个数都要报准', () {
    test('**删掉一条 ⇒ 课次变化为负、例外数被报出来**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      await seedSegment(
        eventId: 'evt-b',
        ruleId: 'rule-b',
        weekdays: const {DateTime.thursday},
        startMinute: 10 * 60,
      );
      // 给要删掉的那条写两条例外：它们会跟着被删，用户必须知道。
      for (final day in const [10, 17]) {
        await repository.replaceOccurrence(
          anchorId: 'evt-b',
          occurrenceStartUtc: DateTime.utc(2026, 9, day, 2),
          patch: CalendarEventPatch(
            title: '高等数学(上)',
            startAtUtc: DateTime.utc(2026, 9, day, 3),
            endAtUtc: DateTime.utc(2026, 9, day, 3, 45),
          ),
          exceptionId: 'exc-$day',
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        );
      }

      final preview = await service.previewCourseEdit(
        await requestFor([draft()]),
      );

      expect(preview, isNotNull);
      expect(preview!.removedSegments, 1);
      expect(preview.addedSegments, 0);
      expect(preview.updatedSegments, 1);
      expect(
        preview.affectedOccurrenceDelta,
        lessThan(0),
        reason: '删掉一条 ⇒ 这学期少上几次课，这个数必须是负的',
      );
      expect(
        preview.removedExceptionCount,
        2,
        reason:
            '那些例外是用户之前逐次调整过的内容，删掉它们必须**在预览里说出来**，'
            '而不是等保存完才发现',
      );
    });

    test('**新增一条 ⇒ 课次变化为正**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');
      final added = draft(
        startMinute: 14 * 60,
        weekdays: const {DateTime.wednesday},
      );

      final preview = await service.previewCourseEdit(
        await requestFor([draft(), added]),
      );

      expect(preview!.addedSegments, 1);
      expect(preview.removedSegments, 0);
      expect(preview.updatedSegments, 1);
      expect(preview.affectedOccurrenceDelta, greaterThan(0));
      expect(preview.removedExceptionCount, 0);
    });

    test('**只改名 ⇒ 没有任何片段增删**（匹配不靠标题）', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

      final preview = await service.previewCourseEdit(
        await requestFor([draft()], title: '完全不同的名字'),
      );

      expect(preview!.hasChanges, isTrue, reason: '名字变了，因此确实有改动要保存');
      expect(
        preview.addedSegments + preview.removedSegments,
        0,
        reason:
            '**匹配不能靠标题**：用户正在改的正是标题，用它当键会把"改了一条"'
            '误报成"删一条加一条"，于是预览里的课次数整个失真',
      );
    });

    test('课程不存在 ⇒ 预览返回 null', () async {
      expect(
        await service.previewCourseEdit(
          CourseSaveRequest(
            logicalCourseId: 'nope',
            expectedRevisions: const {},
            expectedFingerprint: '',
            profile: CourseProfileDraft(
              logicalCourseId: 'nope',
              title: 'x',
              schedule: [draft()],
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('单双周与起始周', () {
    test('**不相符时报错，不自动改用户的输入**', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a');

      // 学期第一周周一 = 2026-09-07。`validFrom = 09-07` 落在**单周**（第 1 周），
      // 而用户选了"双周"。
      final parityMismatch = CourseScheduleDraft(
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        weekdays: const {DateTime.monday},
        intervalWeeks: 2,
        parity: WeekParity.even,
        startWeek: 2,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
      );

      final result = await service.saveCourse(
        await requestFor([parityMismatch]),
      );

      expect(result.status, CourseSaveStatus.invalid);
      expect(
        result.fieldErrors!.keys.any((key) => key.endsWith('.parity')),
        isTrue,
        reason:
            '计划 §2.1：起始周与单双周不相符时保存前明确报错，'
            '**不自动把第 2 周改成第 3 周**——自动改会静默把用户选的周次挪走一周',
      );
    });

    test('相符时正常保存', () async {
      await seedSegment(eventId: 'evt-a', ruleId: 'rule-a', intervalWeeks: 2);

      final matching = CourseScheduleDraft(
        startMinute: 8 * 60,
        endMinute: 8 * 60 + 45,
        weekdays: const {DateTime.monday},
        intervalWeeks: 2,
        // 09-07 是第 1 周（单周），因此"单周"相符。
        parity: WeekParity.odd,
        startWeek: 1,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
      );

      final result = await service.saveCourse(await requestFor([matching]));

      expect(result.status, CourseSaveStatus.saved);
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
