// M2（路线图 §6）第四组强制测试：**表单错误的语义播报**。
//
// 路线图要求"表单错误既显示文字，也进入语义播报；不能只通过红色表达错误"。
// 这里钉两件事：
//   1. 错误**有文字**且文字内容可读（不是只把边框染红）；
//   2. 错误所在节点是**live region**——屏幕阅读器才会在它出现时主动播报，
//      否则用户必须先手动逛到那个控件才知道出错了。
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/tasks/task_editor_page.dart';

final _now = DateTime.utc(2026, 10, 7, 12);

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

/// 一个**始终保存失败**的仓储，用来稳定地造出"保存失败"这条错误。
final class _FailingTasks implements TaskRepository {
  @override
  Stream<List<PlannerTask>> watchAllTasks() => Stream.value(const []);

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(const []);

  @override
  Future<PlannerTask?> getById(String id) async => null;

  @override
  Future<void> save(PlannerTask task) async =>
      throw StateError('磁盘已满（测试制造的失败）');
}

final class _EmptyWorkspace implements WorkspaceRepository {
  const _EmptyWorkspace();
  @override
  Future<List<PlannerArea>> listAreas() async => [
    PlannerArea(
      id: 'area-study',
      name: '学业',
      color: 0,
      sortOrder: 0,
      createdAtUtc: DateTime.utc(2026),
      updatedAtUtc: DateTime.utc(2026),
    ),
  ];

  @override
  Future<List<PlannerProject>> listProjects() async => const [];

  @override
  Future<void> saveArea(PlannerArea area) async {}

  @override
  Future<void> saveProject(PlannerProject project) async {}
}

/// 收集语义树里所有 live region 节点的文本。
List<String> liveRegionLabels(WidgetTester tester) {
  // 与 `accessibility_semantics_test.dart` 同一取舍：`binding.pipelineOwner` 虽被标记
  // 弃用，仍是此处唯一能拿到当前测试树语义根的入口（换成 `rootPipelineOwner` 后遍历
  // 拿不到节点）。理由写在这里，而不是为了消警告换一个不工作的 API。
  // ignore: deprecated_member_use
  final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  final found = <String>[];
  if (root == null) return found;
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.flagsCollection.isLiveRegion) found.add(data.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return found;
}

void main() {
  Future<void> pumpEditor(
    WidgetTester tester, {
    required TaskRepository repository,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: PlannerTheme.dark(),
        home: Scaffold(
          body: TaskEditorPage(
            service: TaskService(
              repository: repository,
              workspace: const _EmptyWorkspace(),
              clock: const _Clock(),
              idGenerator: _Ids(),
            ),
            settings: SettingsService(repository: MemorySettingsRepository()),
            workspace: WorkspaceService(
              repository: const _EmptyWorkspace(),
              clock: const _Clock(),
              idGenerator: _Ids(),
            ),
            zones: TimeZoneDatabase(),
            timeZoneId: 'UTC',
            nowUtc: _now,
            onSaved: (_) {},
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('保存失败的错误', () {
    testWidgets('既显示可读文字，也进入语义播报（live region）', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpEditor(tester, repository: _FailingTasks());

      // 填一个合法标题，点保存
      await tester.enterText(find.byKey(const Key('task-title')), '算法作业');
      await tester.pumpAndSettle();
      final saveFinder = find.byKey(const Key('save-task'));
      // 表单是可滚动的，保存按钮落在视口下方；先滚到它再点，否则 tap 会命中空处
      // （实测：不 ensureVisible 时 tap 的落点是 Offset(309, 1820)，已在 1280×1600 之外）。
      await tester.ensureVisible(saveFinder);
      await tester.pumpAndSettle();
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();

      // ① 文字必须存在且可读（"不能只通过红色表达错误"）
      expect(
        find.textContaining('保存失败'),
        findsOneWidget,
        reason: '保存失败必须给出可读文字，而不是只把按钮或边框染红',
      );

      // ② 它必须是 live region，屏幕阅读器才会主动播报
      final announced = liveRegionLabels(tester);
      expect(
        announced.any((label) => label.contains('保存失败')),
        isTrue,
        reason:
            '错误节点必须是 live region；否则屏幕阅读器不会主动念出它，'
            '用户得自己逛到那个控件才知道出错了。当前 live region：$announced',
      );

      handle.dispose();
    });
  });

  group('字段级错误', () {
    testWidgets('标题为空时给出可读错误文字', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpEditor(tester, repository: _FailingTasks());

      final saveFinder = find.byKey(const Key('save-task'));
      await tester.ensureVisible(saveFinder);
      await tester.pumpAndSettle();
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('请输入任务标题'),
        findsOneWidget,
        reason: '字段级错误也必须有文字',
      );

      handle.dispose();
    });
  });
}
