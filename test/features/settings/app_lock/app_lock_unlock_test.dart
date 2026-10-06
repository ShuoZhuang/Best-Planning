// W6：应用锁的解锁界面。
//
// `AppLockService.verify` 此前没有任何启动调用方，锁只能被开启、不会拦住任何人。这个界面
// 就是那个缺失的调用方，因此这里的断言围绕"错了不放行、对了才回调"，而不是样式。
//
// PBKDF2 迭代次数在测试里降到 1：生产是 600000，跑一次要几百毫秒到数秒，用它做断言只会
// 让测试变慢而不会多验证任何东西（迭代次数本身由 app_lock_service_test 覆盖）。
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_unlock_view.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class _NoDelay implements AppLockDelayPort {
  const _NoDelay();
  @override
  Future<void> wait(Duration duration) async {}
}

void main() {
  late AppLockService service;
  late int unlocked;

  AppLockService freshService() => AppLockService(
    store: InMemoryAppLockCredentialStore(),
    delays: const _NoDelay(),
    algorithm: Pbkdf2.hmacSha256(iterations: 1, bits: 256),
  );

  setUp(() async {
    service = freshService();
    await service.enable('正确密码');
    unlocked = 0;
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppLockUnlockView(service: service, onUnlocked: () => unlocked++),
      ),
    );
    await tester.pumpAndSettle();
  }

  String typedPassword(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('app-lock-password')))
      .controller!
      .text;

  testWidgets('密码正确时解锁并回调', (tester) async {
    await pump(tester);
    expect(find.text('应用锁定'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('app-lock-password')), '正确密码');
    await tester.tap(find.byKey(const Key('app-lock-unlock')));
    await tester.pumpAndSettle();

    expect(unlocked, 1);
    expect(find.textContaining('密码不正确'), findsNothing);
  });

  testWidgets('密码错误时不放行，给出原因并清空输入', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const Key('app-lock-password')), '错误密码');
    await tester.tap(find.byKey(const Key('app-lock-unlock')));
    await tester.pumpAndSettle();

    expect(unlocked, 0);
    expect(find.textContaining('密码不正确'), findsOneWidget);
    // 失败后输入框被清空：留在框里既没用，也容易被旁观者看到。
    expect(typedPassword(tester), isEmpty);
  });

  testWidgets('空密码同样不放行', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('app-lock-unlock')));
    await tester.pumpAndSettle();

    expect(unlocked, 0);
    expect(find.textContaining('密码不正确'), findsOneWidget);
  });

  testWidgets('说明它只挡正常界面、不宣称加密数据库', (tester) async {
    await pump(tester);

    expect(find.textContaining('数据库文件并未加密'), findsOneWidget);
  });
}
