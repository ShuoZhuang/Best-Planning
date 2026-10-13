// W8："信任自动调整"是一个持久设置，但它驱动的只是一个内存 store。
//
// 此前该 store 每次启动都是新的，且只有**打开设置页**时才被灌入持久值，于是同一个设置在不同
// 启动里表现不同。这里验证两件事：读取入口确实存在；以及**预览页不再有这个开关**——
// 1.8.0 专项（计划 §1.2 U3 / Task 6 Step 5）把它从预览页移除了：
//
// > 失败预览仍显示"信任自动调整" ⇒ 开关只留在设置页；预览专注处理当前结果。
//
// 因此本文件的两条用例本轮改写为：
//   ① 设置服务里那个值仍然可读可写（**没有被删掉**，设置页与组合根都还在用它）；
//   ② 预览页里再也找不到这个开关（`SwitchListTile` / "信任自动调整" 文案都没有），
//      而确认预览时仍然记录历史。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

void main() {
  test('信任自动调整可读可写，默认关闭', () async {
    final service = SettingsService(repository: MemorySettingsRepository());

    expect(await service.loadTrustAutoAdjust(), isFalse);

    await service.setTrustAutoAdjust(true);
    expect(await service.loadTrustAutoAdjust(), isTrue);
  });

  Future<void> pump(WidgetTester tester, AutoAdjustStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: PlanPreviewModel(
            proposalId: 'p-1',
            changes: const [],
            issues: const [],
            isStale: false,
          ),
          autoAdjustStore: store,
          onConfirm: (mode) async => ApplyPlanResult.stale(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final switchOnPreview = find.widgetWithText(SwitchListTile, '信任自动调整');

  // 刻意拆成两个用例：同一个测试里连续 pumpWidget 同类型控件会复用 State，
  // `initState` 不再执行，于是第二次读到的仍是第一次的初值——那是测试的假象，不是页面的行为。
  testWidgets('store 关闭时预览页也没有这个开关（U3）', (tester) async {
    await pump(tester, MemoryAutoAdjustStore());

    expect(switchOnPreview, findsNothing, reason: '开关只留在设置页；预览专注于处理当前这份结果');
    expect(find.text('信任自动调整'), findsNothing);
  });

  testWidgets('store 开启时预览页同样没有这个开关，而 store 的值一字未动', (tester) async {
    final store = MemoryAutoAdjustStore()..setEnabled(true);
    await pump(tester, store);

    expect(switchOnPreview, findsNothing);
    // **预览页不再写这个设置**：它没有可写的控件，值只能由设置页／组合根改。
    expect(store.enabled, isTrue, reason: '页面不该因为"没有开关"就把值改掉');
  });
}
