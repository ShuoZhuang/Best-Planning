import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_page.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

void main() {
  testWidgets('应用锁页面明确说明数据库未加密并要求两次输入一致', (tester) async {
    final service = AppLockService(
      store: InMemoryAppLockCredentialStore(),
      algorithm: Pbkdf2.hmacSha256(iterations: 1, bits: 256),
      random: Random(1),
    );
    await tester.pumpWidget(MaterialApp(home: AppLockPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.textContaining('SQLite 数据库并未加密'), findsOneWidget);
    expect(find.text('设置密码'), findsOneWidget);
    expect(find.text('再次输入密码'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '设置密码'), 'one');
    await tester.enterText(find.widgetWithText(TextField, '再次输入密码'), 'two');
    await tester.tap(find.text('开启应用锁'));
    await tester.pump();

    expect(find.textContaining('必须一致'), findsOneWidget);
    expect(await service.isEnabled(), isFalse);
  });
}
