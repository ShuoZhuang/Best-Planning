// R1 的界面入口：在任务详情页给任务打标签。
//
// 这是整条标签链路能否被用户触发的一环。此前 `tags`/`task_tags` 两张表、迁移与
// `TagService` 都在，但没有任何界面能建立标签，因此统计的标签筛选即便取数正确也没有
// 数据可筛——"结构就绪"与"需求兑现"的差别就在这个控件上。
//
// 这里刻意用真实的 drift 仓库与会话内的内存数据库，而不是内存假的标签仓库：关联表对
// `tasks.id` 有外键，页面写的是真实关联行，用假仓库就绕过了这一层。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_tag_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';

final _now = DateTime.utc(2026, 10, 5, 2);

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => _now;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

void main() {
  late AppDatabase database;
  late TaskService tasks;
  late TagService tags;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    tasks = TaskService(
      repository: DriftTaskRepository(database.taskDao),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
    tags = TagService(
      repository: DriftTagRepository(database),
      clock: const _Clock(),
      idGenerator: _Ids(),
    );
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-1',
            title: '写论文',
            priority: 'medium',
            estimatedMinutes: 120,
            remainingMinutes: 120,
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            status: 'open',
            createdAtUtc: 1,
            updatedAtUtc: 1,
          ),
        );
  });

  tearDown(() => database.close());

  Future<void> pump(WidgetTester tester, {bool withTags = true}) async {
    // 页面比默认的 800x600 测试视口高：ListView 只给已布局的子项建立 element，
    // 视口外的控件连"找到"都做不到（ensureVisible 会报 Bad state: No element）。
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskDetailPage(
            service: tasks,
            tags: withTags ? tags : null,
            taskId: 'task-1',
            nowUtc: _now,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  bool chipSelected(WidgetTester tester, String name) =>
      tester.widget<FilterChip>(find.byKey(Key('tag-chip-$name'))).selected;

  testWidgets('在详情页建立新标签并打到当前任务上', (tester) async {
    await pump(tester);
    // 空列表要说明原因与下一步，否则看起来像功能失效。
    expect(find.textContaining('尚无标签'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('new-tag-name')), '论文');
    await tapKey(tester, 'add-tag');

    expect(
      (await tags.tagsForTask('task-1')).map((tag) => tag.name).toList(),
      ['论文'],
    );
    expect(chipSelected(tester, '论文'), isTrue);
    expect(find.textContaining('已更新标签：论文'), findsOneWidget);
    // 输入框被清空，方便连续加下一个。
    expect(
      tester.widget<TextField>(find.byKey(const Key('new-tag-name'))).controller!.text,
      isEmpty,
    );
  });

  testWidgets('再次点击已有标签会解除它，并在全部解除时说明已清除', (tester) async {
    await tags.setTaskTags('task-1', ['论文']);
    await pump(tester);
    expect(chipSelected(tester, '论文'), isTrue);

    await tapKey(tester, 'tag-chip-论文');

    expect(await tags.tagsForTask('task-1'), isEmpty);
    expect(chipSelected(tester, '论文'), isFalse);
    // 标签本身没有被删除，只是不再属于这个任务。
    expect((await tags.listTags()).map((tag) => tag.name).toList(), ['论文']);
    expect(find.textContaining('已清除本任务的标签'), findsOneWidget);
  });

  testWidgets('标签是任务级的：给一个任务打标签不会影响另一个', (tester) async {
    await database
        .into(database.tasks)
        .insert(
          TasksCompanion.insert(
            id: 'task-2',
            title: '另一个任务',
            priority: 'medium',
            estimatedMinutes: 60,
            remainingMinutes: 60,
            energyLevel: 'medium',
            splitMode: 'splittable',
            minChunkMinutes: 30,
            maxChunkMinutes: 60,
            status: 'open',
            createdAtUtc: 1,
            updatedAtUtc: 1,
          ),
        );
    await pump(tester);

    await tester.enterText(find.byKey(const Key('new-tag-name')), '论文');
    await tapKey(tester, 'add-tag');

    expect(await tags.tagsForTask('task-1'), hasLength(1));
    expect(await tags.tagsForTask('task-2'), isEmpty);
  });

  testWidgets('空标签名被拒绝且不写入', (tester) async {
    await pump(tester);

    await tapKey(tester, 'add-tag');

    expect(find.text('请填写标签名'), findsOneWidget);
    expect(await tags.listTags(), isEmpty);
  });

  testWidgets('未装配标签服务时不显示标签区，也不留点不动的控件', (tester) async {
    await pump(tester, withTags: false);

    expect(find.byKey(const Key('new-tag-name')), findsNothing);
    expect(find.byKey(const Key('add-tag')), findsNothing);
    // 其余部分照常可用。
    expect(find.byKey(const Key('remaining-minutes')), findsOneWidget);
  });
}
