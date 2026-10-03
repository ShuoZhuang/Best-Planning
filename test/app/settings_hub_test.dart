// ⑩ 信息架构：设置类页面收进一个入口页。
//
// 此前每加一个设置类页面就往侧边导航里塞一项，导航从 6 项涨到 9 项；W3 那行的"信息架构
// 提醒"预告过这件事。这里把"导航回到 6 项"与"入口页列出已装配的子页"钉住——它们是这一项
// 的实质，而不只是"多了一个页面"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';
import 'package:personal_planner/features/settings/settings_hub_page.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class _NoDelay implements AppLockDelayPort {
  const _NoDelay();
  @override
  Future<void> wait(Duration duration) async {}
}

/// 什么都不建议的分析器：本用例只关心入口页列出哪些条目，不关心偏好内容。
final class _NoAnalyzer implements PreferenceAnalyzer {
  const _NoAnalyzer();
  @override
  List<PreferenceSuggestion> analyze(
    List<PreferenceEvidence> evidence,
    PreferenceProfile current,
  ) => const [];
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 2);
}

final class _NoFacts implements ExportDataSource {
  const _NoFacts();
  @override
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts() async =>
      const {};
}

final class _NoFiles implements ExportFilePort {
  const _NoFiles();
  @override
  Future<String?> chooseDirectory() async => null;
  @override
  Future<String> writeNewFile({
    required String directory,
    required String preferredName,
    required Stream<List<int>> bytes,
  }) async => '';
}

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(timeZoneId: 'Asia/Shanghai', 
          settingsRepository: settings,
          // 四个子页都装配，入口页才应列出四条。
          preferences: PreferenceService(
            analyzer: const _NoAnalyzer(),
            store: MemoryPreferenceStore(),
          ),
          appLock: AppLockService(
            store: InMemoryAppLockCredentialStore(),
            delays: const _NoDelay(),
          ),
          exportService: ExportService(
            source: const _NoFacts(),
            files: const _NoFiles(),
            clock: const _FixedClock(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('侧边导航回到 6 项，设置类页面不再各占一项', (tester) async {
    await pumpApp(tester);

    // `NavigationRailDestination` 是配置对象而不是树里的控件，因此按"导航栏里的文本"数：
    // 它恰好是六项标签。
    final labels = find.descendant(
      of: find.byType(NavigationRail),
      matching: find.byType(Text),
    );
    expect(labels, findsNWidgets(6));
    for (final label in ['今日', '任务', '领域', '日历', '统计', '设置']) {
      expect(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }

    // 这些页面仍可达（经设置入口页），但不再各自占用一个导航项。
    expect(find.text('偏好'), findsNothing);
    expect(find.text('导出'), findsNothing);
  });

  testWidgets('设置入口页列出已装配的子页，并能进入规划规则', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsHubPage), findsOneWidget);
    expect(find.byKey(const Key('settings-rules')), findsOneWidget);
    expect(find.byKey(const Key('settings-preferences')), findsOneWidget);
    expect(find.byKey(const Key('settings-app-lock')), findsOneWidget);
    expect(find.byKey(const Key('settings-export')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-rules')));
    await tester.pumpAndSettle();

    expect(find.byType(PlanningRulesPage), findsOneWidget);
  });

  // B6：通知设置（四类提醒开关、提前量、免打扰时段）装在"规划规则"这一页里，而入口副标题
  // 原文一个字都没提通知——真实的反馈就是"按说明去找通知设置，翻遍设置页都没看到"。
  // 这条守卫把"入口说明必须提到它实际装了什么"钉住：它不是文案洁癖，而是**入口描述与实际
  // 内容不符导致的功能不可发现**。
  testWidgets('通往规划规则的入口说明了它含通知设置', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('settings-rules'));
    expect(entry, findsOneWidget);
    expect(
      find.descendant(of: entry, matching: find.textContaining('通知')),
      findsOneWidget,
      reason: '该页装着通知设置；入口不提通知，用户就找不到它',
    );
  });
}
