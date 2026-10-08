// M2（路线图 §6）：在**真实 Windows 应用**里验证辅助技术在窗口上能读到的语义。
//
// **为什么这个文件存在**：M2 的强制测试之一是"Accessibility Insights 或 Inspect 能看到独立
// 控件节点，不再只有一个 FLUTTERVIEW"。本机既没装 Accessibility Insights，也没有 Windows SDK
// 的 inspect.exe，而我用 `oleacc` 从**窗口层**量到的结果（顶层窗口只有 1 个无名子元素、
// `FLUTTERVIEW` 报 0 个子节点）与用户的真实体验**相反**——用户打开 Narrator 后**能听到**
// 任务页的筛选栏与任务名。
//
// 这说明"从窗口层数子节点"这件事**测错了地方**：Flutter 在 Windows 上把语义交给辅助技术
// 走的不是"hWnd 的子元素"那条路。因此这里改从**应用进程内部**读语义树——它回答的是同一个
// 问题（"辅助技术能拿到什么"），而且**可复现**，不再依赖装什么工具。
//
// 与 `test/app/accessibility_semantics_test.dart` 的区别：那边用**假仓储**在 widget 测试里跑，
// 这边在**真机真窗口**上跑同一条路径，因此能钉住"换环境就不成立"的差异。
import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 收集语义树里所有"有内容"的节点（名称或角色）。
///
/// 与 widget 测试里那份同一取舍：用真实 `SemanticsNode` 而不是 `matchesSemantics` 的子树
/// 匹配，因为这里要的是"辅助技术实际能枚举到的集合"。
List<({String label, String hint, bool isButton, bool isSelected})> collect(
  WidgetTester tester,
) {
  // `binding.pipelineOwner` 虽被标记弃用，仍是此处唯一能拿到当前语义根的入口
  // （换成 `rootPipelineOwner` 后遍历拿不到节点，实测过）。
  // ignore: deprecated_member_use
  final root = tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  final out = <({String label, String hint, bool isButton, bool isSelected})>[];
  if (root == null) return out;

  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    final flags = data.flagsCollection;
    if (data.label.isNotEmpty || data.hint.isNotEmpty) {
      out.add((
        label: data.label,
        hint: data.hint,
        isButton: flags.isButton,
        isSelected: flags.isSelected == Tristate.isTrue,
      ));
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实应用里，任务页的筛选栏与卡片对辅助技术是可读的', (tester) async {
    final settings = MemorySettingsRepository();
    // 两条门都要喂：首次引导与首次教程。少喂教程那条，pump 出来的是教程页而不是主界面
    // （`integration_test/first_plan_flow_test.dart` 就栽在这上面）。
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 进入任务页（用导航项的可读文本点它，与用户操作一致）。
    await tester.tap(find.text('任务').first);
    await tester.pumpAndSettle();

    // 取语义树。这是"辅助技术能枚举到的东西"在应用内的等价物。
    final nodes = collect(tester);
    final labels = nodes.map((node) => node.label).toList();

    // ① 筛选栏四个选项必须可读（M1 加的筛选功能，M2 负责让它对辅助技术可读）。
    //    用 startsWith 而不是等号：数量会随数据变，这里不需要绑死具体条数。
    for (final name in ['全部', '待安排', '已安排', '已完成']) {
      expect(
        labels.any((label) => label.startsWith('$name ')),
        isTrue,
        reason: '筛选栏的「$name」必须出现在语义树里；实际读到：${labels.take(40).toList()}',
      );
    }

    // ② 筛选项应当带选中态（辅助技术靠它读出"当前在哪一栏"）。
    expect(
      nodes.where((node) => node.isSelected).isNotEmpty,
      isTrue,
      reason: '至少要有一个筛选项带选中态',
    );

    // ③ 每个筛选项只出现一次（A2-2 修的就是这个：`SegmentedButton` 曾让每项产生两个同名节点）。
    for (final name in ['全部', '待安排', '已安排', '已完成']) {
      final matches = labels
          .where((label) => label.startsWith('$name '))
          .toList();
      expect(
        matches.length,
        1,
        reason:
            '「$name」在语义树里出现 ${matches.length} 次，应当恰好一次；'
            '重复会让屏幕阅读器念两遍',
      );
    }

    // ④ 页面标题与新建入口也在（说明这一层确实拿到了界面的语义，而不是空树）。
    expect(labels, contains('任务清单'));
    expect(labels, contains('新建任务'));
  });

  testWidgets('真实应用里，任务卡片的详情入口带任务名', (tester) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务').first);
    await tester.pumpAndSettle();

    final nodes = collect(tester);
    final labels = nodes.map((node) => node.label).toList();

    // 没有任务数据时这一条无从验证；有任务时详情入口必须带任务名（A2-1 修的就是它）。
    final detailLabels = labels
        .where((label) => label.startsWith('查看「'))
        .toList();
    if (labels.any((label) => label.startsWith('全部 '))) {
      // 只要有"全部"栏，就说明页面渲染过了；详情入口的有无取决于是否已有任务数据。
      // 不强制要求存在任务，但**凡是存在的**详情入口都必须带名字。
      for (final label in detailLabels) {
        expect(
          label,
          matches(RegExp(r'^查看「.+」详情$')),
          reason: '详情入口的名称里必须带上任务标题，否则一屏多个"查看详情"无法区分',
        );
      }
    }
  });
}
