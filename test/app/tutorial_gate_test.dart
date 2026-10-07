// 首次启动时的教程闸门：新装先看教程，看过之后直接进主界面。
//
// 用户 2026-10-07 的要求原话是"这样做用户第一次使用的时候可以跟着图片&其他引导来走一遍软件的
// 功能"。因此这里钉住三件事：① 新装确实会看到教程；② 顺序在**首次引导之后**（引导定默认值、
// 教程讲用法）；③ 看过之后不再打扰，且"看过了"真的落库。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_steps.dart';

/// 只实现设置读写的最小仓储；教程闸门读的就是它。
final class _Settings implements SettingsRepository {
  _Settings([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

Future<void> _pump(WidgetTester tester, _Settings settings) async {
  await tester.pumpWidget(
    ProviderScope(
      child: PlannerApp(
        timeZoneId: 'Asia/Shanghai',
        settingsRepository: settings,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('新装（引导已完成、教程没看过）先看到教程，而不是主界面', (tester) async {
    final settings = _Settings({
      OnboardingPage.schemaVersionKey: OnboardingPage.currentSchemaVersion
          .toString(),
    });
    await _pump(tester, settings);

    expect(find.text('新手教程'), findsOneWidget);
    expect(find.text('第 1 / ${tutorialSteps.length} 步'), findsOneWidget);
    // 主界面还没出现。
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('跳过之后落库，并进入主界面', (tester) async {
    final settings = _Settings({
      OnboardingPage.schemaVersionKey: OnboardingPage.currentSchemaVersion
          .toString(),
    });
    await _pump(tester, settings);

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();

    // ① "看过了"真的写进设置，而不是只改内存状态。
    expect(
      settings.values[TutorialPage.seenKey],
      TutorialPage.currentVersion.toString(),
    );
    // ② 主界面出现。
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('看过教程之后不再打扰', (tester) async {
    final settings = _Settings({
      OnboardingPage.schemaVersionKey: OnboardingPage.currentSchemaVersion
          .toString(),
      TutorialPage.seenKey: TutorialPage.currentVersion.toString(),
    });
    await _pump(tester, settings);

    expect(find.text('新手教程'), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets('教程版本抬高时老用户会再看一次增量', (tester) async {
    // 存的是更早的版本号 → 视为"需要再看"。
    final settings = _Settings({
      OnboardingPage.schemaVersionKey: OnboardingPage.currentSchemaVersion
          .toString(),
      TutorialPage.seenKey: '0',
    });
    await _pump(tester, settings);

    expect(find.text('新手教程'), findsOneWidget);
  });

  testWidgets('首次引导优先于教程：引导没做完就先不弹教程', (tester) async {
    // 两个键都不喂 → 引导为必需。
    final settings = _Settings();
    await _pump(tester, settings);

    expect(find.text('新手教程'), findsNothing);
    // 引导页在（它有自己的完成按钮，这里只断言教程没抢在前面）。
    expect(find.byType(NavigationRail), findsNothing);
  });
}
