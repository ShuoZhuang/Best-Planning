// W6：应用锁的启动门控。
//
// 这是这条链路唯一真正的"阻止"动作：锁开启时，应用内容（含首次引导）必须先让位于解锁界面。
// 因此断言的不是"解锁界面画得对"（那由 app_lock_unlock_test 覆盖），而是"锁着的时候主界面
// 到底看得到看不到"。
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_page.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class _NoDelay implements AppLockDelayPort {
  const _NoDelay();
  @override
  Future<void> wait(Duration duration) async {}
}

AppLockService freshService() => AppLockService(
  store: InMemoryAppLockCredentialStore(),
  delays: const _NoDelay(),
  // 生产是 600000 次迭代；测试里降到 1，否则每次 verify 都要等上几百毫秒。
  algorithm: Pbkdf2.hmacSha256(iterations: 1, bits: 256),
);

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    AppLockService? appLock,
    bool onboardingDone = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    if (onboardingDone) {
      await settings.write(
        OnboardingPage.schemaVersionKey,
        OnboardingPage.currentSchemaVersion.toString(),
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          settingsRepository: settings,
          appLock: appLock,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('锁开启时先要求解锁，主界面不可见', (tester) async {
    final lock = freshService();
    await lock.enable('pw');

    await pumpApp(tester, appLock: lock);

    expect(find.text('应用锁定'), findsOneWidget);
    // 主界面必须真的看不到，而不只是"多了一个解锁页"。
    expect(find.text('今日'), findsNothing);
  });

  testWidgets('解锁顺序先于首次引导，锁着时引导也不显示', (tester) async {
    final lock = freshService();
    await lock.enable('pw');

    // 未完成首次引导：若门控顺序反了，这里会先看到引导页。
    await pumpApp(tester, appLock: lock, onboardingDone: false);

    expect(find.text('应用锁定'), findsOneWidget);
    expect(find.byType(OnboardingPage), findsNothing);
  });

  testWidgets('输入正确密码后进入主界面', (tester) async {
    final lock = freshService();
    await lock.enable('pw');
    await pumpApp(tester, appLock: lock);

    await tester.enterText(find.byKey(const Key('app-lock-password')), 'pw');
    await tester.tap(find.byKey(const Key('app-lock-unlock')));
    await tester.pumpAndSettle();

    expect(find.text('应用锁定'), findsNothing);
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('密码错误时仍停留在解锁界面', (tester) async {
    final lock = freshService();
    await lock.enable('pw');
    await pumpApp(tester, appLock: lock);

    await tester.enterText(find.byKey(const Key('app-lock-password')), 'nope');
    await tester.tap(find.byKey(const Key('app-lock-unlock')));
    await tester.pumpAndSettle();

    expect(find.text('应用锁定'), findsOneWidget);
    expect(find.text('今日'), findsNothing);
  });

  testWidgets('未开启应用锁时直接进入主界面', (tester) async {
    // 服务装配了，但没有凭据——这是绝大多数安装的默认状态。
    await pumpApp(tester, appLock: freshService());

    expect(find.text('应用锁定'), findsNothing);
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('未装配应用锁服务时不启用门控', (tester) async {
    await pumpApp(tester);

    expect(find.text('应用锁定'), findsNothing);
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('侧边导航可以进入应用锁设置页，用户才能让锁生效', (tester) async {
    // 门控存在但没有设置密码的入口时，锁永远不会开启——这条断言把两件事连起来。
    await pumpApp(tester, appLock: freshService());

    // 应用锁不再是导航栏的一项，而是设置入口页下的一条（信息架构整理）。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-app-lock')));
    await tester.pumpAndSettle();

    expect(find.byType(AppLockPage), findsOneWidget);
    expect(find.text('应用锁服务未装配，暂无法开启或关闭应用锁。'), findsNothing);
  });

  testWidgets('应用锁服务未装配时设置入口页不列出该项', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 入口页只列出**实际装配好的**子页：未装配时不留下一条点了才知道没装 的入口。
    // 该路由本身仍在（可直接经 URL 到达并给出说明），只是不再从界面指向它。
    expect(find.byKey(const Key('settings-app-lock')), findsNothing);
    expect(find.byKey(const Key('settings-rules')), findsOneWidget);
  });
}
