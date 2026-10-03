// W3：偏好设置页此前没有任何路由，学习到的偏好用户既看不到也改不了。
//
// 与 analytics_route_test 同样只验证"可达性"：偏好本身的语义由
// preference_service_test 与 preferences_page_test 覆盖。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester, {PreferenceService? preferences}) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
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

    await tester.tap(find.text('偏好'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(PreferencesPage), findsOneWidget);
    expect(find.text('偏好服务未装配，暂无法查看或调整学习到的偏好。'), findsNothing);
  });

  testWidgets('偏好服务未装配时说明原因而不是空白页', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('偏好'));
    await tester.pump();
    await tester.pump();

    expect(find.text('偏好服务未装配，暂无法查看或调整学习到的偏好。'), findsOneWidget);
    expect(find.byType(PreferencesPage), findsNothing);
  });
}
