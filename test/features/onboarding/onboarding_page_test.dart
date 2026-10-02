import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
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

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('保存修改'), findsOneWidget);
    expect(find.text('稍后设置'), findsOneWidget);
    await tester.tap(find.text('稍后设置'));
    await tester.pumpAndSettle();
    expect(await repository.read(OnboardingPage.schemaVersionKey), '1');
  });
}
