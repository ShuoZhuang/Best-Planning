// R1 的统计接线：标签此前从未被读出来，因此"按标签筛选"恒返回空集。
//
// 这是本项里最容易看错的一处：`AnalyticsFilter.tags` 的字段、界面契约与
// `_matches` 里的判断都在，看起来像"已经能用"，但数据源从不填 `tags`，而模型默认空集，
// 于是 `!task.tags.containsAll(filter.tags)` 对每个任务都为真——选中任何标签都会得到
// 一份空报表，且不报错。因此下面用两种方式断言：数据层直接看 `tags` 是否被填充，
// 服务层看整条链路是否只剩命中任务（修复前该断言会得到 0）。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/daos/analytics_dao.dart';
import 'package:personal_planner/design/protected_time_labels.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';

void main() {
  late AppDatabase database;
  late AnalyticsDao dao;
  late AnalyticsService service;

  final start = DateTime.utc(2026, 10, 1);
  final end = DateTime.utc(2026, 10, 8);

  Future<void> seedTask(
    String id,
    int estimateMinutes, {
    String? areaId,
    String? projectId,
  }) => database
      .into(database.tasks)
      .insert(
        TasksCompanion.insert(
          id: id,
          title: '任务 $id',
          priority: 'medium',
          estimatedMinutes: estimateMinutes,
          remainingMinutes: estimateMinutes,
          energyLevel: 'medium',
          splitMode: 'splittable',
          minChunkMinutes: 30,
          maxChunkMinutes: 60,
          status: 'open',
          createdAtUtc: 1,
          updatedAtUtc: 1,
          areaId: Value(areaId),
          projectId: Value(projectId),
          // 截止落在窗口内，任务才会进入完成率的分母，从而让服务层的筛选结果可观测。
          dueAtUtc: Value(DateTime.utc(2026, 10, 3).microsecondsSinceEpoch),
        ),
      );

  Future<void> seedTag(String id, String name, String taskId) async {
    await database
        .into(database.tags)
        .insert(
          TagsCompanion.insert(
            id: id,
            name: name,
            createdAtUtc: const Value(1),
            updatedAtUtc: const Value(1),
          ),
        );
    await database
        .into(database.taskTags)
        .insert(
          TaskTagsCompanion.insert(
            taskId: taskId,
            tagId: id,
            createdAtUtc: const Value(1),
          ),
        );
  }

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = AnalyticsDao(database, calendar: DriftCalendarRepository(database));
    service = AnalyticsService(source: dao);
    await seedTask('task-1', 120);
    await seedTask('task-2', 60);
    await seedTag('tag-1', '论文', 'task-1');
    await seedTag('tag-2', '深度工作', 'task-1');
  });

  tearDown(() => database.close());

  AnalyticsFilter filterWith(Set<String> tags) =>
      AnalyticsFilter(startUtc: start, endUtc: end, tags: tags);

  test('数据层按任务填充标签，且是整词匹配', () async {
    final dataset = await dao.load(filterWith(const {}));
    final byId = {for (final task in dataset.tasks) task.id: task};

    expect(dataset.tasks, hasLength(2));
    expect(byId['task-1']!.tags, {'论文', '深度工作'});
    expect(byId['task-2']!.tags, isEmpty);

    // 数据层只按领域／项目／状态在 SQL 里过滤，标签谓词在服务层的 `_matches` 里，
    // 因此这里仍然返回两个任务；收窄发生在服务层（见下一条用例）。
    final tagged = await dao.load(filterWith({'论文'}));
    expect(tagged.tasks, hasLength(2));
    expect(byId['task-1']!.tags.containsAll({'论文'}), isTrue);
    expect(byId['task-2']!.tags.containsAll({'论文'}), isFalse);
  });

  test('按标签筛选后只剩命中任务，而不是空集', () async {
    // 修复前：tags 恒为空集，任何非空标签筛选都会把任务全部排除，
    // 这里的分母会是 0——报表看起来像"这个标签下没有任何数据"。
    final all = await service.query(filterWith(const {}));
    final tagged = await service.query(filterWith({'论文'}));

    expect(all.completionRate.denominator, 2);
    expect(tagged.completionRate.denominator, 1);
  });

  test('固定日程进入数据集，带领域名与生活标记', () async {
    // 2026-10-06 的反馈："领域时间分配为什么不把固定日程统计进去"。此前数据集里
    // **完全没有日历事件**，因此领域占比只统计任务计划块，把每周占大头的课表漏掉了。
    await database
        .into(database.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-study',
            name: '学业',
            color: 0xff2f86ff,
            sortOrder: 0,
            isLife: const Value(false),
            createdAtUtc: const Value(1),
            updatedAtUtc: const Value(1),
          ),
        );
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event-1',
            title: '高等数学',
            startAtUtc: start
                .add(const Duration(hours: 1))
                .microsecondsSinceEpoch,
            endAtUtc: start
                .add(const Duration(hours: 3))
                .microsecondsSinceEpoch,
            timeZoneId: 'Asia/Shanghai',
            areaId: const Value('area-study'),
            updatedAtUtc: 1,
          ),
        );

    final dataset = await dao.load(filterWith(const {}));

    expect(dataset.fixedEvents, hasLength(1));
    final event = dataset.fixedEvents.single;
    expect(event.title, '高等数学');
    expect(event.areaId, 'area-study');
    expect(event.areaName, '学业', reason: '领域名要一起带出来，统计层不该再自己查一次');
    expect(event.isLife, isFalse);
    expect(event.endUtc.difference(event.startUtc), const Duration(hours: 2));
  });

  test('保护时间不进"固定日程投入"（规范 §9.1）', () async {
    // 保护时间在数据里与固定日程同形（同一张表、同一套重复规则），但语义是
    // "这段时间不安排任何事"。把它算成固定投入，用户的"固定日程"统计里会混进一半
    // "不许安排"的时间，领域时间分配的饼图也会凭空多出一块并不存在的占用。
    await database
        .into(database.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-study',
            name: '学业',
            color: 0xff2f86ff,
            sortOrder: 0,
            isLife: const Value(false),
            createdAtUtc: const Value(1),
            updatedAtUtc: const Value(1),
          ),
        );
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event-fixed',
            title: '高等数学',
            startAtUtc: start
                .add(const Duration(hours: 1))
                .microsecondsSinceEpoch,
            endAtUtc: start
                .add(const Duration(hours: 3))
                .microsecondsSinceEpoch,
            timeZoneId: 'Asia/Shanghai',
            areaId: const Value('area-study'),
            updatedAtUtc: 1,
          ),
        );
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event-protected',
            title: '保护时间',
            startAtUtc: start
                .add(const Duration(hours: 4))
                .microsecondsSinceEpoch,
            endAtUtc: start
                .add(const Duration(hours: 6))
                .microsecondsSinceEpoch,
            timeZoneId: 'Asia/Shanghai',
            kind: const Value('protected'),
            updatedAtUtc: 1,
          ),
        );

    final dataset = await dao.load(filterWith(const {}));

    expect(dataset.fixedEvents.map((event) => event.title), [
      '高等数学',
    ], reason: '保护时间不得进入 fixedEvents（它不算固定日程投入）');
  });

  test('自定义保护时间进入 protectedInstances，带精确 UTC 区间与用户标题', () async {
    // 规范 §9.1 的最后一条：保护时间**仍然出现在保护时间那一节**。
    // 把它排除出"固定日程投入"不等于把它藏起来——用户建它就是为了看到"这段时间被保护了"，
    // 而"休息保护情况"与"休息总结"两节的分子分母都读这一份数据。
    //
    // **为什么必须是精确 UTC 区间而不是"本地分钟窗"**：`AnalyticsProtectedWindow` 表达的是
    // "每天 12:00–13:00 都是保护时间"。一条只覆盖某一天的一次性保护若被投影成"每天
    // 14:00–15:00"，统计里会凭空多出六天的保护时间——数字错了，而且错的方向恰好是
    // "看起来休息得更多"，最不容易被发现。
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event-protected-only',
            title: '每周二下午不排事',
            startAtUtc: start
                .add(const Duration(hours: 4))
                .microsecondsSinceEpoch,
            endAtUtc: start
                .add(const Duration(hours: 6))
                .microsecondsSinceEpoch,
            timeZoneId: 'Asia/Shanghai',
            kind: const Value('protected'),
            updatedAtUtc: 1,
          ),
        );

    final dataset = await dao.load(filterWith(const {}));

    expect(dataset.protectedInstances, hasLength(1));
    final instance = dataset.protectedInstances.single;
    expect(instance.label, '每周二下午不排事', reason: '用用户给的标题，而不是另编一个"自定义保护"');
    expect(instance.startUtc, start.add(const Duration(hours: 4)));
    expect(instance.endUtc, start.add(const Duration(hours: 6)));
    expect(
      dataset.fixedEvents,
      isEmpty,
      reason: '同一条记录不能既进固定日程投入、又进保护时间（两份互为补集）',
    );
  });

  test('固定日程的时长按领域计入，读来源是日程本身而不是任务表', () async {
    // 课表不挂在任何任务上：它必须靠自己的 areaId 归集，否则"有课表但没建任务"的领域
    // 在占比里恒为 0。
    await database
        .into(database.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-study',
            name: '学业',
            color: 0xff2f86ff,
            sortOrder: 0,
            isLife: const Value(false),
            createdAtUtc: const Value(1),
            updatedAtUtc: const Value(1),
          ),
        );
    await database
        .into(database.calendarEvents)
        .insert(
          CalendarEventsCompanion.insert(
            id: 'event-1',
            title: '高等数学',
            startAtUtc: start
                .add(const Duration(hours: 1))
                .microsecondsSinceEpoch,
            endAtUtc: start
                .add(const Duration(hours: 3))
                .microsecondsSinceEpoch,
            timeZoneId: 'Asia/Shanghai',
            areaId: const Value('area-study'),
            updatedAtUtc: 1,
          ),
        );

    final report = await service.query(filterWith(const {}));
    final study = report.domainDistribution.firstWhere(
      (item) => item.label == '学业',
    );

    expect(study.fixedMinutes, 120);
    expect(study.plannedMinutes, 0);
    expect(study.totalMinutes, 120);
  });

  test('多个标签是"同时满足"，不是"满足任意一个"', () async {
    // 让 task-2 只带其中一个标签：这样"同时满足"与"满足任意一个"才会给出不同结果。
    await database
        .into(database.taskTags)
        .insert(
          TaskTagsCompanion.insert(
            taskId: 'task-2',
            tagId: 'tag-1',
            createdAtUtc: const Value(1),
          ),
        );

    // 单标签：两个任务都带"论文"。
    expect(
      (await service.query(filterWith({'论文'}))).completionRate.denominator,
      2,
    );
    // 两个标签的交集只有 task-1；若实现是"满足任意一个"，这里会得到 2。
    expect(
      (await service.query(filterWith({'论文', '深度工作'})))
          .completionRate
          .denominator,
      1,
    );
    // 交集为空。
    expect(
      (await service.query(filterWith({'论文', '不存在'})))
          .completionRate
          .denominator,
      0,
    );
  });

  test('无项目任务按直接领域进入统计，冲突项目不能覆盖直接领域', () async {
    await database
        .into(database.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-life',
            name: '生活',
            color: 0,
            sortOrder: 0,
            isLife: const Value(true),
          ),
        );
    await database
        .into(database.areas)
        .insert(
          AreasCompanion.insert(
            id: 'area-work',
            name: '工作',
            color: 0,
            sortOrder: 1,
          ),
        );
    await database
        .into(database.projects)
        .insert(
          ProjectsCompanion.insert(
            id: 'project-work',
            areaId: 'area-work',
            name: '实习',
          ),
        );
    await seedTask('task-direct', 30, areaId: 'area-life');
    await seedTask(
      'task-conflict',
      30,
      areaId: 'area-life',
      projectId: 'project-work',
    );

    final dataset = await dao.load(filterWith(const {}));
    final byId = {for (final task in dataset.tasks) task.id: task};
    for (final id in ['task-direct', 'task-conflict']) {
      expect(byId[id]!.areaId, 'area-life');
      expect(byId[id]!.areaName, '生活');
      expect(byId[id]!.isLifeTask, isTrue);
    }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 2（计划 §2.5）：保护时间的**两条**数据路径都要给出正确的中文标签。
  //
  // `AnalyticsDao._protectedWindows()` 有两条把保护时间投影成标签的路径：
  // · `raw == null`（用户没保存过规则）→ typed 的 `_protectedLabel(ProtectedTimeKind)`；
  // · 用户保存过规则 → JSON 字符串 switch。
  // 后者此前只有 lunch／dinner／fixedRest，于是**开了早餐的用户在「休息保护」里看到一条
  // 「保护时间」**，对应不到任何设置（R1 在统计侧的同一条缺陷）。
  //
  // **数据层不 import `lib/design/`**（计划 §2.5 明确禁止反向依赖），因此两份映射由下面
  // 的契约测试保证一致——测试层同时 import 数据层与 design 层是允许的。
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> seedUserRules(String json) => database
      .into(database.settings)
      .insert(
        SettingsCompanion.insert(
          key: 'planning.userRules.v1',
          jsonValue: json,
          updatedAtUtc: 1,
        ),
      );

  Future<void> clearUserRules() => (database.delete(
    database.settings,
  )..where((row) => row.key.equals('planning.userRules.v1'))).go();

  Future<List<AnalyticsProtectedWindow>> protectedWindows() async =>
      (await dao.load(filterWith(const {}))).protectedWindows;

  /// 一条只含 [kind] 的用户规则 JSON（时钟点刻意与默认值都不同，免得两条路径混起来）。
  String rulesJsonFor(ProtectedTimeKind kind) =>
      '{"common":{"protectedTimes":[{'
      '"kind":"${kind.name}",'
      '"range":{"startMinute":600,"endMinute":660},'
      '"dayKind":"any","enabled":true}]}}';

  test('JSON 规则路径：breakfast 映射为「早餐」，不再回落为「保护时间」', () async {
    await seedUserRules(
      '{"common":{"protectedTimes":[{'
      '"kind":"breakfast","range":{"startMinute":450,"endMinute":480},'
      '"dayKind":"any","enabled":true}]}}',
    );

    final windows = await protectedWindows();
    final breakfast = windows.singleWhere((item) => item.startMinute == 450);

    expect(
      breakfast.label,
      '早餐',
      reason:
          'JSON 路径的 switch 必须显式覆盖 breakfast；修复前它落到 `_ =>`，'
          '用户看到一条「保护时间」，而它对应不到任何设置',
    );
    expect(breakfast.endMinute, 480);
    expect(
      windows.map((item) => item.label),
      isNot(contains('保护时间')),
      reason: '兜底文案只负责"不认识的 kind"，不能替 breakfast 回答',
    );
  });

  test('默认规则路径：每条默认保护时间的标签都取自同一份类型映射', () async {
    // 没有保存过规则 → `raw == null` → typed 的 `_protectedLabel` 那条路径。
    final windows = await protectedWindows();
    final defaults = DefaultSettings.v1();

    expect(windows, isNotEmpty, reason: '默认值里午餐与晚餐本来就受保护');
    for (final rule in defaults.protectedTimes) {
      final window = windows.singleWhere(
        (item) => item.startMinute == rule.range.startMinute,
      );
      expect(
        window.label,
        protectedTimeKindLabel(rule.kind),
        reason:
            '默认路径 ${rule.kind.name} 的标签必须与日历共用同一份文案'
            '（否则同一个类别在两个页面显示不同的话）',
      );
    }
    expect(windows.map((item) => item.label), containsAll(['午餐', '晚餐']));
  });

  test('契约：两条路径的输出都与 protectedTimeKindLabel 一致（含 breakfast）', () async {
    // ① JSON 路径：四个类别逐个比对。**这是 breakfast 唯一能真正出现的数据路径**。
    for (final kind in ProtectedTimeKind.values) {
      await clearUserRules();
      await seedUserRules(rulesJsonFor(kind));

      final windows = await protectedWindows();
      final window = windows.singleWhere((item) => item.startMinute == 600);

      expect(
        window.label,
        protectedTimeKindLabel(kind),
        reason: 'JSON 路径的 ${kind.name} 必须与界面文案一致',
      );
    }
    expect(
      protectedTimeKindLabel(ProtectedTimeKind.breakfast),
      '早餐',
      reason: 'breakfast 的文案固定为「早餐」（计划 §2.5）',
    );

    // ② 默认规则路径：逐个默认规则比对——它只可能产出 v1 里真有的类别。
    await clearUserRules();
    final defaultWindows = await protectedWindows();
    final labelsByStart = {
      for (final rule in DefaultSettings.v1().protectedTimes)
        rule.range.startMinute: protectedTimeKindLabel(rule.kind),
    };

    expect(labelsByStart, isNotEmpty);
    for (final window in defaultWindows) {
      final expected = labelsByStart[window.startMinute];
      // 睡眠不在 `protectedTimes` 里（它是 `sleepRange`），标签是另一回事。
      if (expected == null) continue;
      expect(window.label, expected, reason: '默认路径的标签必须来自同一份界面文案');
    }

    // ③ **为什么默认路径不需要（也无法）断言 breakfast**：`v1()` 是既有用户升级后拿到的
    //    规则，早餐刻意不在里面（`DefaultSettings.breakfastStartMinute` 的说明、计划 §2.4
    //    "既有用户默认关闭"）。因此 typed 分支的 breakfast 只由**穷尽 switch**在编译期
    //    保证（那份 switch 没有 `_ =>` 兜底）。这条 canary 把该前提钉住：一旦有人把早餐
    //    放进 v1，它会立刻变红，提醒他把默认路径的 breakfast 也纳入覆盖。
    expect(
      DefaultSettings.v1().protectedTimes.any(
        (rule) => rule.kind == ProtectedTimeKind.breakfast,
      ),
      isFalse,
      reason: 'v1 不替既有用户开启早餐；若改成开启，本文件的默认路径覆盖必须同步扩展',
    );
  });
}
