// M6（路线图 §11 Task 7 Step 3／5／6）：周期目标详情页。
//
// 这个文件钉住四件事：
//   1. 这一周的进度、**本段分钟**、历史周次都真的显示出来；
//   2. 每种操作**写明它影响哪些周**（"仅本周""从下周开始""以后所有周"）；
//   3. 达标与未达标的**完成路径不同**：未达标根本没有"完成本周"这个按钮；
//   4. 150%/200% 缩放下三块内容都能读到。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart' as db;
import 'package:personal_planner/data/database/daos/recurring_task_dao.dart';
import 'package:personal_planner/data/repositories/drift_recurring_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_detail_page.dart';

final _now = DateTime.utc(2026, 10, 7, 4); // 本地 2026-10-07（周三）

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

void main() {
  late db.AppDatabase database;
  late DriftRecurringTaskRepository repository;
  late RecurringTaskService service;

  setUp(() {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftRecurringTaskRepository(
      database,
      RecurringTaskDao(database),
    );
    service = RecurringTaskService(
      repository: repository,
      clock: const _Clock(),
      idGenerator: UuidIdGenerator(),
      zones: TimeZoneDatabase(),
      timeZoneId: 'Asia/Shanghai',
      tasks: DriftTaskRepository(database.taskDao),
    );
  });

  tearDown(() => database.close());

  /// 建一个已经生成本周实例的模板，并可选地补记若干分钟。
  Future<RecurringTaskTemplate> seed({
    String title = '每周英语',
    int targetMinutes = 180,
    List<int> recorded = const [],
    int? previousWeekRecorded,
  }) async {
    final template = await service.createTemplate(
      title: title,
      targetMinutes: targetMinutes,
      nowUtc: _now,
    );
    await service.ensureCycles(
      TimeRange(startUtc: _now, endUtc: _now.add(const Duration(days: 7))),
      _now,
    );
    for (final minutes in recorded) {
      await service.recordManualMinutes(
        template.id,
        DateTime(2026, 10, 5),
        minutes,
      );
    }
    return template;
  }

  Future<void> pump(
    WidgetTester tester,
    String templateId, {
    void Function(String taskId)? onStartFocus,
    void Function(RecurringTaskTemplate template)? onEdit,
    Future<void> Function(RecurringTaskTemplate template)? onDelete,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: RecurringTaskDetailPage(
              service: service,
              templateId: templateId,
              nowUtc: _now,
              onStartFocus: onStartFocus,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 把目标滚到视口里，再返回它。
  ///
  /// **为什么不用 `ensureVisible`／`scrollUntilVisible`**：这一页很长，目标可能**还没有被
  /// 布局**，两个现成方法都会先去找元素、找不到就报 `Bad state: No element`（实测）。
  /// 因此这里改成"拖动 → 找 → 再拖动"的循环：每拖一段就重新找一次，直到它真的出现在
  /// Widget 树里且已经可见。
  Future<Finder> scrollTo(WidgetTester tester, Finder finder) async {
    final scrollable = find.byType(Scrollable).first;
    for (var attempt = 0; attempt < 12; attempt++) {
      if (finder.evaluate().isNotEmpty) {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        return finder;
      }
      await tester.drag(scrollable, const Offset(0, -260));
      await tester.pumpAndSettle();
    }
    return finder;
  }

  testWidgets('显示本周进度：「本周已完成 80/180 分钟」与「本段 45 分钟」', (tester) async {
    final template = await seed(recorded: const [45, 35]);
    await pump(tester, template.id);

    expect(find.text('每周英语'), findsOneWidget);
    expect(
      find.text('本周已完成 80/180 分钟'),
      findsOneWidget,
      reason: '§3.3：卡片要写"本周已完成 80/180 分钟"',
    );
    // "本段"是**最近一段**，不是today之和；两次补记各是一段。
    expect(
      find.text('本段 35 分钟'),
      findsOneWidget,
      reason: '§3.3：同时要写"本段 45 分钟"（这里是最近一段 35）',
    );
    expect(find.textContaining('本周还差 100 分钟'), findsOneWidget);
  });

  testWidgets('安排与完成使用不同文案：不把已安排写成已完成', (tester) async {
    final template = await seed(recorded: const [45]);
    await pump(tester, template.id);

    // 页面上关于投入的数字一律说"已完成"/"本段"，不说"已安排"。
    expect(find.textContaining('已完成'), findsWidgets);
    expect(find.textContaining('已安排'), findsNothing);
  });

  testWidgets('超额时保留记录并说明不再安排', (tester) async {
    final template = await seed(recorded: const [200]);
    await pump(tester, template.id);

    expect(find.text('本周已完成 200/180 分钟'), findsOneWidget);
    expect(find.textContaining('已超出目标 20 分钟'), findsOneWidget);
  });

  testWidgets('历史周次逐周显示，并给出结果文字（不只靠颜色）', (tester) async {
    final template = await seed(recorded: const [80]);
    await pump(tester, template.id);

    await scrollTo(tester, find.byKey(const Key('recurring-history-list')));
    expect(find.textContaining('2026-10-05 起那一周'), findsOneWidget);
    expect(find.textContaining('已完成 80/180 分钟'), findsWidgets);
    // 本周还在进行中：结果写"进行中"，不能提前写"未达标"。
    expect(find.text('进行中'), findsWidgets);
  });

  testWidgets('未达标时不出现"完成本周"（要防"点一下就悄悄过了"）', (tester) async {
    final pending = await seed();
    await pump(tester, pending.id);
    expect(
      find.byKey(const Key('recurring-detail-complete')),
      findsNothing,
      reason: '§3.3：未达标不能一键完成',
    );
  });

  testWidgets('达标后才建议完成，点它把本周标记为 met', (tester) async {
    // **达标之后再挂载页面**（而不是在同一个测试里对同一个 State 二次 pumpWidget）：
    // `pumpWidget` 对同型同 key 的组件会复用 State，`initState` 不会再跑一次，
    // 于是"重新加载"这件事根本没发生——那样断言的是 Widget 树的缓存，不是行为。
    final template = await seed(recorded: const [180]);
    await pump(tester, template.id);

    await scrollTo(tester, find.byKey(const Key('recurring-detail-complete')));
    expect(
      find.byKey(const Key('recurring-detail-complete')),
      findsOneWidget,
      reason: '§3.3：达到目标时可以建议完成本周任务',
    );

    await tester.tap(find.byKey(const Key('recurring-detail-complete')));
    await tester.pumpAndSettle();
    final cycle = await repository.findCycle(
      template.id,
      DateTime(2026, 10, 5),
    );
    expect(cycle!.status, RecurringCycleStatus.met);
  });

  testWidgets('手动补记写进本周进度并刷新页面', (tester) async {
    final template = await seed();
    await pump(tester, template.id);

    await tester.tap(find.byKey(const Key('recurring-detail-record-minutes')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('recurring-record-minutes-field')),
      '50',
    );
    await tester.tap(find.byKey(const Key('recurring-record-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('本周已完成 50/180 分钟'),
      findsOneWidget,
      reason: [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          if (t.data != null) t.data!,
      ].join(' | '),
    );
    expect(find.text('本段 50 分钟'), findsOneWidget);
  });

  testWidgets('跳过本周写明"仅这一周"，且执行后不再显示补记入口', (tester) async {
    final template = await seed();
    await pump(tester, template.id);

    await scrollTo(tester, find.byKey(const Key('recurring-detail-skip')));
    expect(find.text('影响：仅这一周；模板与其他周不变。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recurring-detail-skip')));
    await tester.pumpAndSettle();

    expect(
      await repository.findCycle(template.id, DateTime(2026, 10, 5)),
      isNotNull,
    );
    final cycle = await repository.findCycle(
      template.id,
      DateTime(2026, 10, 5),
    );
    expect(cycle!.status, RecurringCycleStatus.skipped);
    // 已定案的一周不能再补记：入口消失。
    expect(
      find.byKey(const Key('recurring-detail-record-minutes')),
      findsNothing,
    );
  });

  testWidgets('编辑与删除都写明影响范围', (tester) async {
    final template = await seed();
    await pump(tester, template.id, onEdit: (_) {}, onDelete: (_) async {});

    await scrollTo(tester, find.byKey(const Key('recurring-detail-edit')));
    expect(find.text('影响：从下周开始；本周实例保持原样。'), findsOneWidget);

    await scrollTo(tester, find.byKey(const Key('recurring-detail-delete')));
    expect(find.textContaining('历史周次同时消失'), findsOneWidget);

    // 删除要二次确认：这是一条不可撤销的破坏性动作。
    await tester.tap(find.byKey(const Key('recurring-detail-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recurring-delete-dialog')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('删除失败时留在详情页并显示错误，不能静默假装成功', (tester) async {
    final template = await seed();
    await pump(
      tester,
      template.id,
      onDelete: (_) async => throw StateError('FOREIGN KEY constraint failed'),
    );

    await scrollTo(tester, find.byKey(const Key('recurring-detail-delete')));
    await tester.tap(find.byKey(const Key('recurring-detail-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recurring-delete-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recurring-detail-title')), findsOneWidget);
    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(
      find.textContaining('FOREIGN KEY constraint failed'),
      findsOneWidget,
    );
  });

  testWidgets('停止以后生成写明"以后所有周"，并真的变成归档', (tester) async {
    final template = await seed();
    await pump(tester, template.id);

    await scrollTo(tester, find.byKey(const Key('recurring-detail-stop')));
    expect(find.textContaining('以后所有周'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recurring-detail-stop')));
    await tester.pumpAndSettle();

    final stored = await repository.findTemplate(template.id);
    expect(stored!.status, RecurringTemplateStatus.archived);
    // 归档之后可以恢复。
    await scrollTo(tester, find.byKey(const Key('recurring-detail-resume')));
    expect(find.byKey(const Key('recurring-detail-resume')), findsOneWidget);
  });

  testWidgets('暂停写明到期自动恢复，并写进模板', (tester) async {
    final template = await seed();
    await pump(tester, template.id);

    await scrollTo(tester, find.byKey(const Key('recurring-detail-pause')));
    expect(find.textContaining('到期自动恢复'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recurring-detail-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recurring-pause-7')));
    await tester.pumpAndSettle();

    final stored = await repository.findTemplate(template.id);
    expect(stored!.pausedUntilLocalDate, DateTime(2026, 10, 14));
  });

  testWidgets('还没有本周实例时给出解释，而不是空白', (tester) async {
    // 模板的起始日在未来：本周不该生成。
    final template = await service.createTemplate(
      title: '下学期才开始',
      targetMinutes: 120,
      startsOnLocalDate: DateTime(2026, 10, 19),
      nowUtc: _now,
    );
    await service.ensureCycles(
      TimeRange(startUtc: _now, endUtc: _now.add(const Duration(days: 7))),
      _now,
    );
    await pump(tester, template.id);

    expect(find.byKey(const Key('recurring-detail-no-cycle')), findsOneWidget);
    expect(find.textContaining('还没有生成周期实例'), findsOneWidget);
  });

  testWidgets('模板不存在时如实说明，而不是画一个空页面', (tester) async {
    await pump(tester, 'missing-template');
    expect(find.byKey(const Key('recurring-detail-missing')), findsOneWidget);
    expect(find.textContaining('不存在'), findsOneWidget);
  });

  testWidgets('未注入回调的入口不渲染（不给死入口）', (tester) async {
    final template = await seed();
    await pump(tester, template.id);

    expect(find.byKey(const Key('recurring-detail-edit')), findsNothing);
    expect(find.byKey(const Key('recurring-detail-delete')), findsNothing);
    expect(find.byKey(const Key('recurring-detail-start-focus')), findsNothing);
  });

  testWidgets('150% 与 200% 缩放下进度、管理与历史都能读到', (tester) async {
    final template = await seed(recorded: const [60]);
    for (final scale in const [1.5, 2.0]) {
      await pump(tester, template.id, textScale: scale);
      expect(tester.takeException(), isNull, reason: '$scale 倍缩放下不应有布局异常');

      await scrollTo(
        tester,
        find.byKey(const Key('recurring-detail-progress-label')),
      );
      expect(find.text('本周已完成 60/180 分钟'), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('recurring-detail-skip')));
      expect(find.byKey(const Key('recurring-detail-skip')), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('recurring-history-list')));
      expect(find.byKey(const Key('recurring-history-list')), findsOneWidget);
    }
  });
}
