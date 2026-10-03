// spec §18 第 18 项「用户可完整导出和永久清除自己的数据」——**永久清除那半边在界面上真的
// 可达**。
//
// 这一项此前不勾选的理由不是功能缺失，而是**入口缺失**：`DataErasureService` 与 `BackupPage`
// 里那一块都已存在、也各有测试，但组合根从不构造它、路由器刻意不传 `erasure`。因此本文件钉住
// 的是**可达性本身**：装配了服务就该出现入口，没装配就不该出现——以及界面对**真实行为**的
// 描述（清除安排在下次启动执行，文案必须如实说，而不是说成"已清除"）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/features/settings/data/backup_page.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/platform/files/backup_archive_adapter.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';

void main() {
  late _Database database;
  late DataErasureService service;

  setUp(() {
    database = _Database();
    service = DataErasureService(
      database: database,
      notifications: _Notifications(),
      credentials: InMemoryAppLockCredentialStore('hash-only'),
    );
  });

  Future<void> pump(WidgetTester tester, {required bool withErasure}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BackupPage(
          // 备份那一半不是本文件的主题，因此只给它一个"未装配即报错"的最小实现。
          backups: _backups(database),
          erasure: withErasure ? service : null,
          files: const FileSelectorAdapter(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('装配了清除服务时，备份页出现该入口', (tester) async {
    await pump(tester, withErasure: true);

    expect(find.text('永久清除'), findsOneWidget);
    expect(find.byKey(const Key('erasure-confirmation')), findsOneWidget);
    expect(find.byKey(const Key('erasure-submit')), findsOneWidget);
  });

  testWidgets('未装配时不出现该入口（不给一个点了不生效的按钮）', (tester) async {
    await pump(tester, withErasure: false);

    expect(find.text('永久清除'), findsNothing);
    expect(find.byKey(const Key('erasure-submit')), findsNothing);
  });

  testWidgets('文案如实说明清除范围与"下次启动生效"', (tester) async {
    await pump(tester, withErasure: true);

    // 范围：外部导出文件不在其中（那是用户自己的文件）。
    expect(find.textContaining('不会删除自行导出的外部文件'), findsOneWidget);
    // 时机：删除发生在下次启动。说成"已清除"而用户重启前还能看到数据，就是在掩盖真实行为。
    expect(find.textContaining('下次启动'), findsOneWidget);
    // 生产里没有"备份索引"这个东西，因此文案不该承诺它（见 buildDataErasureService 的说明）。
    expect(find.textContaining('备份索引'), findsNothing);
  });

  testWidgets('确认短语不匹配时不删除任何数据，并说明原因', (tester) async {
    await pump(tester, withErasure: true);

    await tester.enterText(find.byKey(const Key('erasure-confirmation')), '删除');
    await tester.tap(find.byKey(const Key('erasure-submit')));
    await tester.pumpAndSettle();

    expect(database.erased, isFalse);
    expect(find.textContaining('确认短语不匹配'), findsOneWidget);
  });

  testWidgets('输入正确短语后真的触发清除，并如实说"下次启动"生效', (tester) async {
    await pump(tester, withErasure: true);

    await tester.enterText(
      find.byKey(const Key('erasure-confirmation')),
      DataErasureService.confirmationPhrase,
    );
    await tester.tap(find.byKey(const Key('erasure-submit')));
    await tester.pumpAndSettle();

    expect(database.erased, isTrue);
    // 用**结果文案特有的句子**断言，而不是再找一次"下次启动"：说明文字里本来就有那四个字，
    // 于是"找到一处"既可能指结果、也可能指说明（第一版正是这样失败的：Found 2 widgets）。
    expect(find.textContaining('已安排永久清除'), findsOneWidget);
    expect(find.textContaining('下次启动'), findsNWidgets(2));
  });
}

final class _Database implements DatabaseLifecyclePort {
  bool erased = false;
  @override
  int get supportedSchemaVersion => 3;
  @override
  Future<void> eraseAll() async => erased = true;
  @override
  Future<void> createConsistentSnapshot(String destination) =>
      throw UnimplementedError();
  @override
  Future<DatabaseInspection> inspect(String candidate) =>
      throw UnimplementedError();
  @override
  Future<void> replaceWith(String validatedDatabase) =>
      throw UnimplementedError();
}

final class _Notifications implements NotificationPort {
  @override
  void onTapped(void Function(NotificationPayload payload) handler) {}
  @override
  Future<NotificationPayload?> launchPayload() async => null;
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<NotificationCapability> capability() async =>
      const NotificationCapability.available();
  @override
  Future<List<PendingNotification>> pendingNotifications() async => const [];
  @override
  Future<void> scheduleOneShot(NotificationRequest request) =>
      throw UnimplementedError();
}

/// 备份那一半不是本文件的主题，但 `BackupService` 是 final class（不能实现接口），因此**构造
/// 一个真的**：数据库端口复用上面那个假实现，归档与哈希用生产里同样的适配器。页面只渲染它，
/// 不会真的调用备份，因此这些依赖不会被触及。
BackupService _backups(DatabaseLifecyclePort database) => BackupService(
  database: database,
  archives: const BackupArchiveAdapter(),
  hashes: const Sha256FileHashAdapter(),
  clock: const SystemClock(),
  appVersion: 'test',
  settingsJson: () async => '{}',
);
