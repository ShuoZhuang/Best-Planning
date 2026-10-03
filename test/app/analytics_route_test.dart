// W3：统计页此前没有任何路由——功能、页面与测试都在，却没有任何路径能到达它。
//
// 这里验证的是"可达性"本身，而不是统计口径（口径由 analytics_service_test 与
// analytics_page_test 覆盖）：侧边导航能进入统计页，且依赖未装配时页面说明原因，
// 而不是渲染空白页或一个点了没反应的控件。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';

/// 只挂起不返回：页面停在加载态就够了，无需构造完整报表——本测试关心的是路由。
final class _PendingAnalytics implements AnalyticsQuery {
  @override
  Future<AnalyticsReport> query(AnalyticsFilter filter) =>
      Completer<AnalyticsReport>().future;
}

void main() {
  Future<void> pumpApp(WidgetTester tester, {AnalyticsQuery? analytics}) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(settingsRepository: settings, analytics: analytics),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('侧边导航可以进入统计页', (tester) async {
    await pumpApp(tester, analytics: _PendingAnalytics());

    await tester.tap(find.text('统计'));
    // 页面处于加载态，`pumpAndSettle` 会等一个不会结束的动画，因此只推进两帧。
    await tester.pump();
    await tester.pump();

    expect(find.byType(AnalyticsPage), findsOneWidget);
    expect(find.text('统计服务未装配，暂无法展示统计报表。'), findsNothing);
  });

  testWidgets('统计服务未装配时说明原因而不是空白页', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('统计'));
    await tester.pump();
    await tester.pump();

    expect(find.text('统计服务未装配，暂无法展示统计报表。'), findsOneWidget);
    expect(find.byType(AnalyticsPage), findsNothing);
  });
}
