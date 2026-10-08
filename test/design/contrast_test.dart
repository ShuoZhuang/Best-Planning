// M2（路线图 §6）第二组强制测试：**四档材质下的对比度**。
//
// 用 Flutter 自带的 `textContrastGuideline`（它按 WCAG 的 4.5:1 / 3:1 规则逐节点检查），
// 而不是靠肉眼估——"看着还行"和"测得达标"是两件事。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_theme.dart';

/// 四档材质。
const _modes = PlannerMaterialMode.values;

Future<void> _pump(
  WidgetTester tester,
  PlannerMaterialMode mode,
  Widget child,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: PlannerTheme.dark(glassMode: mode),
      home: PlannerBackdrop(
        child: Builder(
          builder: (context) => Scaffold(
            // 与真实装配一致：内容画在玻璃表面上。
            body: PlannerGlassSurface(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 一页典型正文：三种文字层级都出现，用来一次量出 `textPrimary`／`textSecondary`／
/// `textMuted` 在**合成后的真实背景**上的比值。
Widget _samplePage(BuildContext context) {
  final text = Theme.of(context).textTheme;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('任务清单', style: text.headlineMedium),
      const SizedBox(height: 12),
      Text('算法作业', style: text.bodyLarge),
      const SizedBox(height: 8),
      Text('待安排 · 预计 50 分钟', style: text.bodyMedium),
      const SizedBox(height: 8),
      Text('已逾期 · 截止于 10月6日 23:59', style: text.bodySmall),
      const SizedBox(height: 16),
      const TextField(decoration: InputDecoration(hintText: '搜索任务')),
      const SizedBox(height: 16),
      Row(
        children: [
          FilledButton(onPressed: () {}, child: const Text('新建任务')),
          const SizedBox(width: 12),
          TextButton(onPressed: () {}, child: const Text('多选')),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: () {}, child: const Text('本周')),
        ],
      ),
    ],
  );
}

void main() {
  for (final mode in _modes) {
    testWidgets('正文与背景对比度达标：${mode.storedValue}', (tester) async {
      await _pump(tester, mode, Builder(builder: _samplePage));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }
}
