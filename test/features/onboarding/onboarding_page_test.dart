import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

void main() {
  testWidgets('首次引导展示默认值且一键采用不会开启自动调整和应用锁', (tester) async {
    final repository = MemorySettingsRepository();
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(
          repository: repository,
          onComplete: () => completed = true,
        ),
      ),
    );

    expect(find.textContaining('09:00–12:00'), findsOneWidget);
    expect(find.textContaining('23:30–07:30'), findsOneWidget);
    expect(find.textContaining('50 分钟专注'), findsOneWidget);
    expect(find.textContaining('10 分钟休息'), findsOneWidget);
    expect(find.textContaining('360 分钟生活娱乐'), findsOneWidget);
    expect(find.textContaining('自动调整：关闭'), findsOneWidget);
    expect(find.textContaining('应用锁：关闭'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键采用默认设置'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(await repository.read(OnboardingPage.schemaVersionKey), '1');
    expect(await repository.read('planning.trustAutoAdjust.v1'), 'false');
    expect(
      await repository.read(SettingsAppLockCredentialStore.credentialKey),
      isNull,
    );
  });

  testWidgets('允许修改默认设置或稍后设置', (tester) async {
    final repository = MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(repository: repository, onComplete: () {}),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding-focus-minutes')), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('保存修改'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.text('稍后设置'), findsOneWidget);
    await tester.tap(find.text('稍后设置'));
    await tester.pumpAndSettle();
    expect(await repository.read(OnboardingPage.schemaVersionKey), '1');
  });

  testWidgets('修改设置覆盖全部关键排程默认值并持久化', (tester) async {
    final repository = MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(repository: repository, onComplete: () {}),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改设置'));
    await tester.pumpAndSettle();

    for (final key in <String>[
      'onboarding-high-start',
      'onboarding-medium-start',
      'onboarding-low-start',
      'onboarding-sleep-start',
      'onboarding-minimum-sleep',
      'onboarding-breakfast-start',
      'onboarding-breakfast-end',
      'onboarding-breakfast-enabled',
      'onboarding-lunch-start',
      'onboarding-dinner-start',
      'onboarding-focus-minutes',
      'onboarding-break-minutes',
      'onboarding-min-chunk',
      'onboarding-max-chunk',
      'onboarding-daily-limit',
      'onboarding-life-quota',
      'onboarding-trust-auto-adjust',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }

    await tester.enterText(
      find.byKey(const Key('onboarding-high-start')),
      '08:30',
    );
    await tester.enterText(
      find.byKey(const Key('onboarding-focus-minutes')),
      '45',
    );
    await tester.dragUntilVisible(
      find.text('保存修改'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final resolved = await SettingsService(repository: repository)
        .resolveForDate(DateTime(2026, 10, 5));
    expect(resolved.rules.energyWindows.first.range.startMinute, 8 * 60 + 30);
    expect(resolved.rules.defaultFocusMinutes, 45);
    expect(resolved.trustAutoAdjust, isFalse);
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 9 Step 4（课程与保护时间管理修复计划）：**早餐在首次引导里默认开启**
  //
  // 与设置页**故意不同**：设置页里早餐默认关闭（既有用户升级后不该被悄悄改变
  // 已确认的计划，计划 §2.4），而首次引导是在**建立**这份计划——用户此刻正被问
  // "你的作息是什么样的"，此时把早餐摆出来让他自己决定才是对的。
  // ─────────────────────────────────────────────────────────────────────────────

  testWidgets('**早餐开关默认开启，时间是 07:30–08:00**', (tester) async {
    final repository = MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(repository: repository, onComplete: () {}),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改设置'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('onboarding-breakfast-enabled')),
          )
          .value,
      isTrue,
      reason: '首次引导是"建立计划"，因此把早餐摆出来默认采纳',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('onboarding-breakfast-start')),
          )
          .controller
          ?.text,
      '07:30',
      reason: '建议值必须来自 `DefaultSettings` 的公开常量，而不是再写一遍字面量',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('onboarding-breakfast-end')))
          .controller
          ?.text,
      '08:00',
    );
  });

  testWidgets('**完成引导会保存 breakfast**', (tester) async {
    final repository = MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(repository: repository, onComplete: () {}),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改设置'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('保存修改'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final resolved = await SettingsService(repository: repository)
        .resolveForDate(DateTime(2026, 10, 5));
    final breakfast = resolved.rules.protectedTimes
        .where((item) => item.kind.name == 'breakfast')
        .toList();

    expect(breakfast, hasLength(1), reason: '默认开启 ⇒ 完成引导就必须写下这条规则');
    expect(breakfast.single.range.startMinute, 7 * 60 + 30);
    expect(breakfast.single.range.endMinute, 8 * 60);
  });

  testWidgets('**关掉早餐再完成引导 ⇒ 规则里没有 breakfast**', (tester) async {
    final repository = MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(repository: repository, onComplete: () {}),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改设置'));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('onboarding-breakfast-enabled'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(toggle).value,
      isFalse,
      reason: '前置条件：点了开关它必须真的变',
    );

    await tester.dragUntilVisible(
      find.text('保存修改'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    final resolved = await SettingsService(repository: repository)
        .resolveForDate(DateTime(2026, 10, 5));
    expect(
      resolved.rules.protectedTimes.where(
        (item) => item.kind.name == 'breakfast',
      ),
      isEmpty,
      reason:
          '**不写 `enabled: false`**：那会留下一条"存在但关闭"的规则，'
          '而设置页保存时是**移除**它——两种表示并存会让"这条规则到底有没有"'
          '有两个答案（计划 Task 9 Step 2）',
    );
  });

  testWidgets('**跳过引导不写任何规则**（也不会顺手开启早餐）', (tester) async {
    final repository = MemorySettingsRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingPage(repository: repository, onComplete: () {}),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一键采用默认设置'));
    await tester.pumpAndSettle();

    final resolved = await SettingsService(repository: repository)
        .resolveForDate(DateTime(2026, 10, 5));
    expect(
      resolved.rules.protectedTimes.where(
        (item) => item.kind.name == 'breakfast',
      ),
      isEmpty,
      reason:
          '"一键采用默认设置"走的是 `saveChanges: false`，因此不写规则。'
          '顺手开启早餐会让一个只想"先看看"的用户多出一条他没同意的保护时间',
    );
  });
}
