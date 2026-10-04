import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';

void main() {
  testWidgets('首次启动先显示默认设置引导', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: PlannerApp(timeZoneId: 'Asia/Shanghai')),
    );
    await tester.pumpAndSettle();

    expect(find.text('先照顾好生活，再安排任务'), findsOneWidget);
  });

  testWidgets('完成引导后主导航可在今日、任务和日历之间切换', (tester) async {
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今日'), findsWidgets);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('任务'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('任务'), findsWidgets);
    expect(find.text('任务清单'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('日历'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('日历'), findsWidgets);
    expect(find.text('七日日历'), findsOneWidget);
  });

  testWidgets('主工作台使用深色专注主题', (tester) async {
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(NavigationRail));
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, const Color(0xff2f86ff));
    expect(theme.scaffoldBackgroundColor, const Color(0xff0c1522));
  });
}
