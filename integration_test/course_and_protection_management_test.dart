// Task 10 Steps 3–5（课程与保护时间管理修复计划）：**三条用户主路径的集成证据**。
//
// 与 `test/` 下的用例不同，这里装配的是**真实服务组合**（真实 Drift 库、真实仓储、
// 真实引擎），只在时钟与 id 生成器上做替换。单元测试证明"每个方法按契约工作"，
// 集成测试证明"把这些方法接起来，用户走一遍之后看到的东西是对的"——
// 本批次修的三处缺陷（课程资料改了不生效、保护时间只能建不能改、早餐无处可设）
// 恰恰都属于后者：每一层单独看都没问题，接起来才错。
//
// 用 `IntegrationTestWidgetsFlutterBinding` 以便在 Windows 上跑（计划 Task 10 Step 7）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_protected_time_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const timeZoneId = 'Asia/Shanghai';
  final zones = TimeZoneDatabase();

  /// 2026-10-12（周一）09:00 本地。
  final nowUtc = DateTime.utc(2026, 10, 12, 1);

  late AppDatabase database;
  late DriftCalendarRepository calendar;
  late DriftCourseSeriesRepository courses;
  late CourseManagementService courseManagement;
  late DriftProtectedTimeSeriesRepository protectedSeries;
  late SettingsService settings;

  Future<void> open({Map<String, String> existingSettings = const {}}) async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    calendar = DriftCalendarRepository(database, zones: zones);
    courses = DriftCourseSeriesRepository(
      database,
      clock: _Clock(nowUtc),
      zones: zones,
      timeZoneId: timeZoneId,
    );
    protectedSeries = DriftProtectedTimeSeriesRepository(
      database,
      zones: zones,
    );
    courseManagement = CourseManagementService(
      courses: courses,
      calendar: CalendarService(
        repository: calendar,
        deletion: calendar,
        recurringRepository: calendar,
        clock: _Clock(nowUtc),
        idGenerator: _Ids(),
        zones: zones,
      ),
      deletion: calendar,
      gateway: calendar,
      academicCalendar: DriftAcademicCalendarRepository(database),
      zones: zones,
      timeZoneId: timeZoneId,
      clock: _Clock(nowUtc),
    );
    settings = SettingsService(
      repository: DriftSettingsRepository(database, _Clock(nowUtc)),
    );
    for (final entry in existingSettings.entries) {
      await database.customInsert(
        'INSERT INTO settings (key, json_value, created_at_utc, updated_at_utc) '
        "VALUES ('${entry.key}', '${entry.value}', 1, 1)",
      );
    }
  }

  tearDown(() => database.close());

  Future<void> seedTerm() async {
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
              'committed', 3, 1, 1)
    ''');
  }

  /// 造一门**单双周**课：单周周一 08:00、双周周三 10:00 —— 库里是**两条规则**。
  Future<void> seedOddEvenCourse({
    required String logicalCourseId,
    String title = '高等数学(上)',
    String teacher = '赵敏',
  }) async {
    for (final (suffix, weekday, startMinute) in [
      ('odd', DateTime.monday, 8 * 60),
      ('even', DateTime.wednesday, 10 * 60),
    ]) {
      await calendar.saveRecurring(
        CalendarEvent(
          id: 'evt-$logicalCourseId-$suffix',
          title: title,
          startAtUtc: DateTime.utc(2026, 9, 7, 0),
          endAtUtc: DateTime.utc(2026, 9, 7, 0, 45),
          timeZoneId: timeZoneId,
          recurrenceRuleId: 'rule-$logicalCourseId-$suffix',
          sourceKind: CalendarEventSourceKind.timetableImport,
          importBatchId: 'batch-autumn',
          logicalCourseId: logicalCourseId,
          notes: teacher,
          location: 'D206',
          updatedAtUtc: DateTime.utc(2026, 10, 1),
        ),
        RecurrenceRule(
          id: 'rule-$logicalCourseId-$suffix',
          weekdays: {weekday},
          localStartMinute: startMinute,
          durationMinutes: 45,
          intervalWeeks: 2,
          validFromLocalDate: DateTime(2026, 9, 7),
          validUntilLocalDate: DateTime(2026, 12, 20),
          timeZoneId: timeZoneId,
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Step 3：**课程路径**
  // ─────────────────────────────────────────────────────────────────────────────

  test('导入的单双周课程：改名称、教师、地点与其中一条安排，保存后列表与日历一致', () async {
    await open();
    await seedTerm();
    await seedOddEvenCourse(logicalCourseId: 'course-calc');

    // 管理页读到的形状：**一门课、两个片段**。
    final listed = await courseManagement.listCourses();
    expect(listed, hasLength(1), reason: '单双周在库里是两条规则，用户眼里是一门课');
    expect(listed.single.anchorEventIds, hasLength(2));

    final detail = (await courseManagement.findCourse('course-calc'))!;
    final monday = detail.segments.firstWhere(
      (segment) => segment.weekdays.contains(DateTime.monday),
    );
    final wednesday = detail.segments.firstWhere(
      (segment) => segment.weekdays.contains(DateTime.wednesday),
    );

    // 改名称、教师、地点，并把**周三那一条**挪到 14:00。
    final preview = await courseManagement.previewCourseEdit(
      CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '高等数学(下)',
          teacher: '李娜',
          location: 'E101',
          schedule: [
            _draftOf(monday),
            _draftOf(wednesday, startMinute: 14 * 60),
          ],
        ),
      ),
    );
    expect(preview!.removedSegments, 0, reason: '**改时间不该被当成删一条加一条**：时间不是匹配键');
    expect(preview.updatedSegments, 2);

    final saved = await courseManagement.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '高等数学(下)',
          teacher: '李娜',
          location: 'E101',
          schedule: [
            _draftOf(monday),
            _draftOf(wednesday, startMinute: 14 * 60),
          ],
        ),
      ),
    );
    expect(saved.status, CourseSaveStatus.saved);

    // **重开一次连接**（模拟重启应用）：读到的必须是改后的样子。
    final after = (await courses.findCourse('course-calc'))!;
    expect(after.summary.title, '高等数学(下)');
    expect(after.segments, hasLength(2), reason: '仍然是两段，改动不该合并');
    for (final segment in after.segments) {
      expect(segment.title, '高等数学(下)');
      expect(segment.teacher, '李娜');
      expect(segment.location, 'E101');
    }
    final moved = after.segments.firstWhere(
      (segment) => segment.weekdays.contains(DateTime.wednesday),
    );
    expect(moved.startMinute, 14 * 60, reason: '只有周三那一条被挪动');
    final untouched = after.segments.firstWhere(
      (segment) => segment.weekdays.contains(DateTime.monday),
    );
    expect(untouched.startMinute, 8 * 60, reason: '周一那一条保持原样');
    expect(untouched.weekdays, {
      DateTime.monday,
    }, reason: '星期集合不能被另一条覆盖（多星期规则曾经被丢成单值）');
  });

  test('**同名但不同 id 的课程不被修改**', () async {
    await open();
    await seedTerm();
    await seedOddEvenCourse(logicalCourseId: 'course-calc');
    await seedOddEvenCourse(logicalCourseId: 'course-calc-b', teacher: '王强');

    final detail = (await courseManagement.findCourse('course-calc'))!;
    await courseManagement.saveCourse(
      CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '改过的名字',
          teacher: '李娜',
          schedule: [for (final segment in detail.segments) _draftOf(segment)],
        ),
      ),
    );

    final other = (await courses.findCourse('course-calc-b'))!;
    expect(
      other.summary.title,
      '高等数学(上)',
      reason:
          '**同名不是同一门课**。按标题匹配会让"改 A 班的时间表"顺手改掉 B 班——'
          '这正是计划 §10 的 Review Focus',
    );
    expect(other.segments.first.teacher, '王强');
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Step 4：**保护时间路径**
  // ─────────────────────────────────────────────────────────────────────────────

  test('自定义保护时间：建一次、管理页一行、改名后重启仍在、例外只影响那一次', () async {
    await open();

    // ① 建一条**每周二 "健身"** 的保护时间。
    await calendar.saveRecurring(
      CalendarEvent(
        id: 'protected-gym',
        title: '健身',
        startAtUtc: zones.localDateTimeToUtc(
          DateTime.utc(2026, 10, 6),
          14 * 60,
          timeZoneId,
        ),
        endAtUtc: zones.localDateTimeToUtc(
          DateTime.utc(2026, 10, 6),
          15 * 60,
          timeZoneId,
        ),
        timeZoneId: timeZoneId,
        recurrenceRuleId: 'rule-gym',
        kind: CalendarEventKind.protected,
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-gym',
        weekdays: const {DateTime.tuesday},
        localStartMinute: 14 * 60,
        durationMinutes: 60,
        validFromLocalDate: DateTime(2026, 10, 6),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: timeZoneId,
      ),
    );

    // ② 管理页读到的必须是**一行**，而不是未来 180 天的每一次发生。
    final series = await protectedSeries.listProtectedSeries();
    expect(
      series.map((item) => item.anchorId),
      ['protected-gym'],
      reason:
          '按展开结果列出会得到二十多行（用户以为建了二十多条）。'
          '读模型必须是锚点行',
    );
    expect(series.single.weekdays, {DateTime.tuesday});
    expect(series.single.title, '健身');

    // ③ 改名并调整时间，走**整条系列**编辑（不是新建）。
    final service = CalendarService(
      repository: calendar,
      deletion: calendar,
      recurringRepository: calendar,
      clock: _Clock(nowUtc),
      idGenerator: _Ids(),
      zones: zones,
    );
    final renamed = await service.updateEvent(
      target: CalendarEditTarget(
        anchorId: 'protected-gym',
        scope: EventEditScope.entireSeries,
        expectedUpdatedAtUtc: series.single.updatedAtUtc,
      ),
      event: CalendarEventEditDraft(
        title: '游泳',
        startAtUtc: zones.localDateTimeToUtc(
          DateTime.utc(2026, 10, 6),
          16 * 60,
          timeZoneId,
        ),
        endAtUtc: zones.localDateTimeToUtc(
          DateTime.utc(2026, 10, 6),
          17 * 60,
          timeZoneId,
        ),
        timeZoneId: timeZoneId,
        kind: CalendarEventKind.protected,
      ),
    );
    expect(renamed.status, CalendarMutationStatus.saved);

    // ④ "重启应用"：管理页仍然只有一行，且是新名字、新时间。
    final reopened = await DriftProtectedTimeSeriesRepository(
      database,
      zones: zones,
    ).listProtectedSeries();
    expect(reopened, hasLength(1), reason: '改名绝不能变成"又建了一条"');
    expect(reopened.single.title, '游泳');
    expect(reopened.single.startMinute, 16 * 60);
    // 改写不得跨类别：保护时间必须还是保护时间。读模型只列 `kind = protected`
    // 的锚点，因此"它还在这个清单里"本身就是这条判据。
    expect(reopened.single.repeats, isTrue, reason: '整条系列改写不该把它退化成一次性事项');

    // ⑤ 从某一周起**只改一次**为"体检"，其它周仍是"游泳"。
    final occurrenceStart = zones.localDateTimeToUtc(
      DateTime.utc(2026, 10, 20),
      16 * 60,
      timeZoneId,
    );
    final exception = await service.updateEvent(
      target: CalendarEditTarget(
        anchorId: 'protected-gym',
        scope: EventEditScope.singleOccurrence,
        occurrenceStartUtc: occurrenceStart,
      ),
      event: CalendarEventEditDraft(
        title: '体检',
        notes: '带化验单',
        startAtUtc: occurrenceStart,
        endAtUtc: occurrenceStart.add(const Duration(hours: 1)),
        timeZoneId: timeZoneId,
        kind: CalendarEventKind.protected,
      ),
    );
    expect(exception.status, CalendarMutationStatus.saved);

    final thatDay = await calendar.occurrencesBetween(
      zones.localDateTimeToUtc(DateTime.utc(2026, 10, 20), 0, timeZoneId),
      zones.localDateTimeToUtc(DateTime.utc(2026, 10, 21), 0, timeZoneId),
    );
    expect(
      thatDay.single.title,
      '体检',
      reason:
          '**仅本次改名必须真的生效**。修复前例外行只能换时间——'
          '展开器把锚点标题套给每一次，于是用户改了名、保存之后一切照旧',
    );
    expect(thatDay.single.notes, '带化验单');

    final nextWeek = await calendar.occurrencesBetween(
      zones.localDateTimeToUtc(DateTime.utc(2026, 10, 27), 0, timeZoneId),
      zones.localDateTimeToUtc(DateTime.utc(2026, 10, 28), 0, timeZoneId),
    );
    expect(nextWeek.single.title, '游泳', reason: '只改一次不得影响其它各次');
  });

  test('**排程不能占用保护时间**', () async {
    await open();
    final source = RepositoryScheduleProblemSource(
      tasks: DriftTaskRepository(database.taskDao),
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendar,
      settings: settings,
      plans: DriftPlanRepository(database, clock: _Clock(nowUtc)),
      clock: _Clock(nowUtc),
      timeZoneId: timeZoneId,
      zones: zones,
    );
    final engine = DeterministicScheduleEngine(zones);

    // 一条 08:00–09:00 的自定义保护时间（本地）。
    final startUtc = zones.localDateTimeToUtc(
      DateTime.utc(2026, 10, 12),
      8 * 60,
      timeZoneId,
    );
    await calendar.saveRecurring(
      CalendarEvent(
        id: 'protected-morning',
        title: '晨间保护',
        startAtUtc: startUtc,
        endAtUtc: startUtc.add(const Duration(hours: 1)),
        timeZoneId: timeZoneId,
        recurrenceRuleId: 'rule-morning',
        kind: CalendarEventKind.protected,
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-morning',
        weekdays: const {DateTime.monday},
        localStartMinute: 8 * 60,
        durationMinutes: 60,
        validFromLocalDate: DateTime(2026, 10, 5),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: timeZoneId,
      ),
    );

    final plan = engine.generate(await source.load());
    final protectedWindow = TimeRange(
      startUtc: startUtc,
      endUtc: startUtc.add(const Duration(hours: 1)),
    );
    for (final block in plan.blocks) {
      expect(
        block.range.overlaps(protectedWindow),
        isFalse,
        reason: '保护时间的语义是"这段时间不许安排"。排程块落进去等于把它降级成建议',
      );
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Step 5：**早餐路径**
  // ─────────────────────────────────────────────────────────────────────────────

  test('早餐：老设置升级后关闭；启用后任务不落进去；关闭后恢复可用', () async {
    await open();
    final source = RepositoryScheduleProblemSource(
      tasks: DriftTaskRepository(database.taskDao),
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendar,
      settings: settings,
      plans: DriftPlanRepository(database, clock: _Clock(nowUtc)),
      clock: _Clock(nowUtc),
      timeZoneId: timeZoneId,
      zones: zones,
    );
    final engine = DeterministicScheduleEngine(zones);

    // ① **老设置升级后早餐关闭**（计划 §2.4：既有用户不该被悄悄改变已确认的计划）。
    final upgraded = await settings.resolveForDate(DateTime(2026, 10, 12));
    expect(
      upgraded.rules.protectedTimes.where(
        (rule) => rule.kind == ProtectedTimeKind.breakfast,
      ),
      isEmpty,
      reason:
          '`DefaultSettings.v1()` 里不能有 breakfast——'
          '那会让升级后的用户凭空多出一条没同意的保护时间',
    );
    expect(
      DefaultSettings.breakfastStartMinute,
      450,
      reason: '建议范围是公开常量，界面的默认值必须来自它',
    );
    expect(DefaultSettings.breakfastEndMinute, 480);

    // ② 启用早餐 07:30–08:00（本地）。
    await settings.saveUserRules(
      UserPlanningRules(
        common: PlanningRulesPatch(
          protectedTimes: [
            ProtectedTimeRule(
              kind: ProtectedTimeKind.breakfast,
              range: LocalTimeRange(startMinute: 450, endMinute: 480),
            ),
          ],
        ),
      ),
    );
    final enabled = await settings.resolveForDate(DateTime(2026, 10, 12));
    expect(
      enabled.rules.protectedTimes
          .where((rule) => rule.kind == ProtectedTimeKind.breakfast)
          .single
          .range
          .startMinute,
      450,
      reason: '启用之后规则里必须真的有一条早餐保护',
    );

    // ③ **任务不进入早餐窗口**：直接问引擎。
    final breakfastStart = zones.localDateTimeToUtc(
      DateTime.utc(2026, 10, 12),
      450,
      timeZoneId,
    );
    final breakfast = TimeRange(
      startUtc: breakfastStart,
      endUtc: breakfastStart.add(const Duration(minutes: 30)),
    );
    final withBreakfast = engine.generate(await source.load());
    for (final block in withBreakfast.blocks) {
      expect(
        block.range.overlaps(breakfast),
        isFalse,
        reason: '启用早餐后任务不能落进 07:30–08:00',
      );
    }

    // ④ 关闭后**恢复可用**：规则里不再有 breakfast，同一个窗口不再被排除。
    await settings.saveUserRules(
      UserPlanningRules(common: PlanningRulesPatch(protectedTimes: const [])),
    );
    final disabled = await settings.resolveForDate(DateTime(2026, 10, 12));
    expect(
      disabled.rules.protectedTimes.where(
        (rule) => rule.kind == ProtectedTimeKind.breakfast,
      ),
      isEmpty,
      reason:
          '关闭必须**移除**这条规则，而不是留一条 `enabled: false` 的重复表示——'
          '两种表示并存会让"这条规则到底有没有"有两个答案',
    );
  });

  test('早餐与睡眠重叠时保存被拦截，且**旧规则不变**', () async {
    await open();

    // ① 先写一份**正常的**用户规则：睡眠 23:30–07:30 ＋ 早餐 07:30–08:00（首尾相接）。
    //
    // **两份在同一次保存里给**：`saveUserRules` 是**整体替换**（不是增量合并），
    // 因此第二次保存若不带睡眠，那份规则里就没有睡眠了——而"早餐与睡眠重叠"
    // 这个场景要求两者同时存在。设置页保存时正是这么做的：它每次交上整张表单。
    await settings.saveUserRules(
      UserPlanningRules(
        common: PlanningRulesPatch(
          sleepRange: LocalTimeRange(startMinute: 1410, endMinute: 450),
          protectedTimes: [
            ProtectedTimeRule(
              kind: ProtectedTimeKind.breakfast,
              range: LocalTimeRange(startMinute: 450, endMinute: 480),
            ),
          ],
        ),
      ),
    );
    final before = await settings.resolveForDate(DateTime(2026, 10, 12));
    expect(
      before.rules.protectedTimes
          .where((rule) => rule.kind == ProtectedTimeKind.breakfast)
          .single
          .range
          .startMinute,
      450,
      reason:
          '前置条件：首尾相接（睡眠 07:30 结束、早餐 07:30 开始）**不算重叠**，'
          '因此这一份能存下去',
    );

    // ② 再把早餐改成 07:00–08:00：与睡眠的尾巴重叠 30 分钟。
    await expectLater(
      settings.saveUserRules(
        UserPlanningRules(
          common: PlanningRulesPatch(
            sleepRange: LocalTimeRange(startMinute: 1410, endMinute: 450),
            protectedTimes: [
              ProtectedTimeRule(
                kind: ProtectedTimeKind.breakfast,
                range: LocalTimeRange(startMinute: 420, endMinute: 480),
              ),
            ],
          ),
        ),
      ),
      throwsA(isA<SettingsValidationException>()),
    );

    final after = await settings.resolveForDate(DateTime(2026, 10, 12));
    expect(
      after.rules.protectedTimes
          .where((rule) => rule.kind == ProtectedTimeKind.breakfast)
          .single
          .range
          .startMinute,
      450,
      reason:
          '**被拦下的保存不得留下半条改动**：读回来必须还是那次成功保存的 07:30–08:00。'
          '修复前这条路径会留下 `enabled: false` 的早餐，于是"保存失败"与'
          '"规则里多了一条"同时成立',
    );
    expect(
      after.rules.sleepRange.startMinute,
      before.rules.sleepRange.startMinute,
    );
  });
}

CourseScheduleDraft _draftOf(CourseSeriesSegment segment, {int? startMinute}) {
  final start = startMinute ?? segment.startMinute;
  return CourseScheduleDraft(
    startMinute: start,
    endMinute: start + (segment.endMinute - segment.startMinute),
    weekdays: segment.weekdays,
    intervalWeeks: segment.intervalWeeks,
    validFromLocalDate: segment.validFromLocalDate,
    validUntilLocalDate: segment.validUntilLocalDate,
  );
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
