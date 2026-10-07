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
import 'package:personal_planner/domain/models/analytics.dart';
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
}
