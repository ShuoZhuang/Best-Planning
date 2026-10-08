// ⑩ 信息架构：设置类页面收进一个入口页。
//
// 此前每加一个设置类页面就往侧边导航里塞一项，导航从 6 项涨到 9 项；W3 那行的"信息架构
// 提醒"预告过这件事。这里把"导航回到 6 项"与"入口页列出已装配的子页"钉住——它们是这一项
// 的实质，而不只是"多了一个页面"。
import 'package:flutter/material.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/academic_calendar/academic_calendar_page.dart';
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
  Future<String?> chooseSaveLocation({
    required String suggestedName,
    required String extension,
  }) async => null;
  @override
  Future<String> writeFile({
    required String destination,
    required Stream<List<int>> bytes,
  }) async => '';
}

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    MemorySettingsRepository? settings,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = settings ?? MemorySettingsRepository();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await repository.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    // 首次教程闸门与首次引导是同一条套路（设置键 + 版本比较）。不喂这一条，
    // 整应用 pump 出来的会是教程页而不是主界面——教程自身的用例在 test/features/tutorial/。
    // ignore: unused_local_variable
    await repository.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: repository,
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
          academicCalendar: AcademicCalendarService(
            repository: DriftAcademicCalendarRepository(database),
            clock: const _FixedClock(),
            idGenerator: UuidIdGenerator(),
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

  testWidgets('设置卡片之间保留 12 像素间距且点击高度足够', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: [
            SettingsHubEntry(title: '甲', subtitle: '说明甲', onOpen: () {}),
            SettingsHubEntry(title: '乙', subtitle: '说明乙', onOpen: () {}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final cards = find.byType(Card);
    expect(cards, findsNWidgets(2));
    final first = tester.getRect(cards.at(0));
    final second = tester.getRect(cards.at(1));
    expect(second.top - first.bottom, 12);
    for (final tile in tester.widgetList<ListTile>(find.byType(ListTile))) {
      expect(tile.minTileHeight ?? 0, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('页面底部显示软件版本号（用户 2026-10-07 要求）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          versionLabel: '1.5.0+30',
          entries: [
            SettingsHubEntry(title: '甲', subtitle: '说明甲', onOpen: () {}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-version-label')), findsOneWidget);
    expect(find.text('软件版本 1.5.0+30'), findsOneWidget);

    // 它在**所有入口卡片之后**：用户要往下看才能见到，而不是挤在标题旁边。
    final label = tester.getRect(
      find.byKey(const Key('settings-version-label')),
    );
    final lastCard = tester.getRect(find.byType(Card).last);
    expect(label.top, greaterThan(lastCard.bottom));
  });

  testWidgets('没有版本号时整行不渲染，而不是显示"未知版本"', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: [
            SettingsHubEntry(title: '甲', subtitle: '说明甲', onOpen: () {}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-version-label')), findsNothing);
    expect(find.textContaining('软件版本'), findsNothing);
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
    expect(find.byKey(const Key('settings-appearance')), findsOneWidget);
    expect(find.byKey(const Key('settings-academic-calendar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-rules')));
    await tester.pumpAndSettle();

    expect(find.byType(PlanningRulesPage), findsOneWidget);
    expect(find.byKey(const Key('shell-back-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('shell-back-button')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsHubPage), findsOneWidget);
  });

  testWidgets('设置入口可以进入学期与节次模板页', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-academic-calendar')));
    await tester.pumpAndSettle();

    expect(find.byType(AcademicCalendarPage), findsOneWidget);
    expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
  });

  testWidgets('外观页提供四档材质，切换后立即生效并保存', (tester) async {
    final settings = MemorySettingsRepository();
    await pumpApp(tester, settings: settings);

    expect(find.byKey(const Key('app-material-restrained')), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('设置'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-appearance')));
    await tester.pumpAndSettle();

    expect(find.text('无玻璃效果'), findsOneWidget);
    expect(find.text('克制版'), findsOneWidget);
    expect(find.text('激进版'), findsOneWidget);
    expect(find.text('极致版'), findsOneWidget);

    await tester.tap(find.byKey(const Key('glass-mode-aggressive')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-material-aggressive')), findsOneWidget);
    expect(await settings.read('appearance.glass-mode'), 'aggressive');

    await tester.tap(find.byKey(const Key('glass-mode-liquid')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-material-liquid')), findsOneWidget);
    expect(await settings.read('appearance.glass-mode'), 'liquid');
  });

  testWidgets('启动时恢复已经保存的无玻璃模式', (tester) async {
    final settings = MemorySettingsRepository();
    await settings.write('appearance.glass-mode', 'off');

    await pumpApp(tester, settings: settings);

    expect(find.byKey(const Key('app-material-off')), findsOneWidget);
    expect(
      find.byKey(const Key('glass-chrome-off-fill')),
      findsNWidgets(2),
      reason: '关闭玻璃后，顶栏与侧边导航都必须恢复为实体深色表面',
    );
  });

  testWidgets('一级页面不显示返回按钮，子页面统一显示', (tester) async {
    await pumpApp(tester);

    expect(find.byKey(const Key('shell-back-button')), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('设置'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shell-back-button')), findsNothing);

    await tester.tap(find.byKey(const Key('settings-relaxation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
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

  // ─────────────────────────────────────────────────────────────────────────────
  // M8（路线图 §12「设置整理」）：按四组分组 + 每个入口展示当前关键值。
  // 规格：`docs/superpowers/specs/2026-10-07-m8-onboarding-and-settings.md`
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('M8 设置首页按 §12 的四组分组，顺序与原文一致', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: const [
            SettingsHubEntry(
              title: '规划项',
              subtitle: '说明',
              group: SettingsGroup.planning,
              onOpen: _noop,
            ),
            SettingsHubEntry(
              title: '外观项',
              subtitle: '说明',
              group: SettingsGroup.appearance,
              onOpen: _noop,
            ),
            SettingsHubEntry(
              title: '隐私项',
              subtitle: '说明',
              group: SettingsGroup.notification,
              onOpen: _noop,
            ),
            SettingsHubEntry(
              title: '数据项',
              subtitle: '说明',
              group: SettingsGroup.data,
              onOpen: _noop,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // §12 原文顺序：规划与时间、外观与交互、通知与隐私、数据与帮助。
    const expected = ['规划与时间', '外观与交互', '通知与隐私', '数据与帮助'];
    final positions = [
      for (final title in expected) tester.getTopLeft(find.text(title)).dy,
    ];
    for (var index = 1; index < positions.length; index++) {
      expect(
        positions[index],
        greaterThan(positions[index - 1]),
        reason: '「${expected[index]}」必须排在「${expected[index - 1]}」下面',
      );
    }
    for (final title in expected) {
      expect(find.text(title), findsOneWidget, reason: '「$title」这一组标题要在');
    }
  });

  testWidgets('M8 没有条目的分组整组不渲染（不留空标题）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: const [
            SettingsHubEntry(
              title: '只有外观',
              subtitle: '说明',
              group: SettingsGroup.appearance,
              onOpen: _noop,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外观与交互'), findsOneWidget);
    for (final empty in const ['规划与时间', '通知与隐私', '数据与帮助']) {
      expect(
        find.text(empty),
        findsNothing,
        reason: '「$empty」里没有任何入口，不该留一个空标题',
      );
    }
  });

  testWidgets('M8 每个入口展示当前关键值（§12 举的例子就是"默认专注 50 分钟"）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: [
            SettingsHubEntry(
              title: '规划规则与默认值',
              subtitle: '作息、精力区间……',
              group: SettingsGroup.planning,
              // §12 原文举的例子。
              currentValue: () async => '默认专注 50 分钟',
              onOpen: _noop,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('默认专注 50 分钟'),
      findsOneWidget,
      reason: '设置页的意义就是"不用点进去也能看到现状"',
    );
  });

  testWidgets('M8 当前值异步读到：首帧不卡加载态，读到后补上', (tester) async {
    final completer = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: [
            SettingsHubEntry(
              title: '外观与材质',
              subtitle: '切换玻璃强度',
              group: SettingsGroup.appearance,
              currentValue: () => completer.future,
              onOpen: _noop,
            ),
          ],
        ),
      ),
    );
    // 只 pump 一帧：副标题与入口必须**已经可见**，不能为了一个提示把整页卡在加载态。
    await tester.pump();
    expect(find.text('切换玻璃强度'), findsOneWidget);
    expect(find.textContaining('材质：'), findsNothing);

    completer.complete('材质：克制');
    await tester.pumpAndSettle();
    expect(find.textContaining('材质：克制'), findsOneWidget);
  });

  testWidgets('M8 当前值为空时只显示副标题，不显示占位文案', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: [
            SettingsHubEntry(
              title: '窗口与后台',
              subtitle: '关闭窗口后的行为',
              group: SettingsGroup.appearance,
              currentValue: () async => null,
              onOpen: _noop,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关闭窗口后的行为'), findsOneWidget);
    // 「未设置」「未知」这类占位对用户没有用——与本仓库既有的"没有值就不渲染"同一口径。
    for (final placeholder in const ['未设置', '未知', 'null']) {
      expect(find.textContaining(placeholder), findsNothing);
    }
  });

  testWidgets('M8 读取当前值失败时入口照常可用、不崩', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsHubPage(
          entries: [
            SettingsHubEntry(
              title: '规划规则与默认值',
              subtitle: '作息与默认值',
              group: SettingsGroup.planning,
              currentValue: () async => throw StateError('设置读不出来'),
              onOpen: () => opened++,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 与"设置写失败不崩"同一取舍：读不出当前值只是少一行提示，
    // 不该让整个设置页打不开——那会把一个小故障放大成用不了。
    expect(tester.takeException(), isNull);
    expect(find.text('作息与默认值'), findsOneWidget);
    await tester.tap(find.text('规划规则与默认值'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}

void _noop() {}
