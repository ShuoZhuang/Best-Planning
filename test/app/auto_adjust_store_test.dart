// W8："信任自动调整"是一个持久设置，但它驱动的只是一个内存 store。
//
// 此前该 store 每次启动都是新的，且只有**打开设置页**时才被灌入持久值，于是同一个设置在不同
// 启动里表现不同。这里验证两件事：读取入口确实存在；以及 store 的值真的被预览页当作开关初值
// ——启动时种下的就是这个值。
//
// 同时如实记下一处更大的事实：这个开关**不参与任何行为判断**，它只渲染自己。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
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
            conflicts: const [],
            isStale: false,
          ),
          autoAdjustStore: store,
          onConfirm: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool switchValue(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '信任自动调整'))
      .value;

  // 刻意拆成两个用例：同一个测试里连续 pumpWidget 同类型控件会复用 State，
  // `initState` 不再执行，于是第二次读到的仍是第一次的初值——那是测试的假象，不是页面的行为。
  testWidgets('store 关闭时开关关闭', (tester) async {
    await pump(tester, MemoryAutoAdjustStore());

    expect(switchValue(tester), isFalse);
  });

  testWidgets('store 开启时开关开启（组合根在启动时种下的就是这个值）', (tester) async {
    await pump(tester, MemoryAutoAdjustStore()..setEnabled(true));

    expect(switchValue(tester), isTrue);
  });
}
