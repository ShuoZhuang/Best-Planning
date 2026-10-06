// W3：偏好设置页此前没有任何路由，学习到的偏好用户既看不到也改不了。
//
// 与 analytics_route_test 同样只验证"可达性"：偏好本身的语义由
// preference_service_test 与 preferences_page_test 覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    PreferenceService? preferences,
  }) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          preferences: preferences,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('侧边导航可以进入偏好设置页', (tester) async {
    await pumpApp(
      tester,
      preferences: PreferenceService(
        analyzer: const RuleBasedPreferenceAnalyzer(),
        store: MemoryPreferenceStore(),
      ),
    );

    // 偏好页不再是导航栏的一项，而是设置入口页下的一条（信息架构整理）。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-preferences')));
    await tester.pumpAndSettle();

    expect(find.byType(PreferencesPage), findsOneWidget);
    expect(find.text('偏好服务未装配，暂无法查看或调整学习到的偏好。'), findsNothing);
  });

  testWidgets('偏好服务未装配时设置入口页不列出该项', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 入口页只列出实际装配好的子页；未装配时不留一条"点了才知道没装"的入口。
    expect(find.byKey(const Key('settings-preferences')), findsNothing);
    expect(find.byKey(const Key('settings-rules')), findsOneWidget);
  });
}
