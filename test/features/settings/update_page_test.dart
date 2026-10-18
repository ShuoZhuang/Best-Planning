// 设置页：状态与诊断（UPD-023 / UPD-005 / 规格 §11.6）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_settings.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/features/settings/update/update_page.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late InMemoryUpdateSafetyCoordinator safety;
  late FakeManifestSource source;
  late MemoryLogSink log;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_page_test_');
    safety = InMemoryUpdateSafetyCoordinator();
    log = MemoryLogSink();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<UpdateController> buildController({
    bool autoUpdateEnabled = true,
  }) async {
    final verified = await verifiedManifestFixture();
    source = FakeManifestSource(ManifestFetchResult.verified(verified));
    final settings = _MemorySettings();
    final settingsStore = JsonUpdateSettingsStore(settings: settings);
    await settingsStore.save(
      UpdateSettings(autoUpdateEnabled: autoUpdateEnabled),
    );
    final orchestrator = UpdateOrchestrator(
      manifestSource: source,
      stateStore: InMemoryStateStore(),
      installedPackages: FakeInstalledPackages(),
      downloader: FakeDownloader(),
      verifier: FakeVerifier(),
      layout: UpdateStorageLayout(root: directory),
      safety: safety,
      log: log,
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );
    final controller = UpdateController(
      orchestrator: orchestrator,
      settings: settingsStore,
      safety: safety,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    return controller;
  }

  Future<void> pumpPage(
    WidgetTester tester,
    UpdateController controller, {
    Future<bool> Function(Uri url)? openUrl,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UpdatePage(
          controller: controller,
          openUrl: openUrl,
          readLogs: controller.readLogs,
          clearLogs: controller.clearLogs,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('展示当前版本、最新版本、阶段与包验证结论', (tester) async {
    final controller = await buildController();
    await controller.checkNow();
    await pumpPage(tester, controller);

    expect(find.text('1.8.1.0'), findsOneWidget);
    expect(find.text('1.9.0.0'), findsWidgets);
    expect(find.text('更新已就绪'), findsWidgets);
    expect(find.text('已通过大小、SHA-256 与包身份验证'), findsOneWidget);
    expect(find.byKey(const Key('update-install')), findsOneWidget);
  });

  testWidgets('只有验证通过的清单才显示“最新稳定版本”', (tester) async {
    final settingsStore = JsonUpdateSettingsStore(settings: _MemorySettings());
    final orchestrator = UpdateOrchestrator(
      manifestSource: FakeManifestSource(networkFailureFixture()),
      stateStore: InMemoryStateStore(),
      installedPackages: FakeInstalledPackages(),
      downloader: FakeDownloader(),
      verifier: FakeVerifier(),
      layout: UpdateStorageLayout(root: directory),
      safety: safety,
      log: log,
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );
    final controller = UpdateController(
      orchestrator: orchestrator,
      settings: settingsStore,
      safety: safety,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.checkNow();
    await pumpPage(tester, controller);

    expect(find.text('尚未确认'), findsOneWidget);
    // 失败不等于"已是最新"：状态里也不会出现这一句。
    expect(find.text('已经是最新版'), findsNothing);
  });

  testWidgets('关闭自动更新立即生效并持久化', (tester) async {
    final controller = await buildController();
    await pumpPage(tester, controller);

    await tester.tap(find.byKey(const Key('update-auto-toggle')));
    await tester.pumpAndSettle();

    expect(controller.autoUpdateEnabled, isFalse);
  });

  testWidgets('关闭自动更新后，手动发现更新不会自动下载', (tester) async {
    final controller = await buildController(autoUpdateEnabled: false);
    await pumpPage(tester, controller);

    await controller.checkNow();
    await tester.pumpAndSettle();

    expect(controller.state.phase, UpdatePhase.updateAvailable);
    expect(
      find.byKey(const Key('update-download-now')),
      findsOneWidget,
    );
  });

  testWidgets('立即重新检查会再请求一次清单', (tester) async {
    final controller = await buildController();
    await controller.checkNow();
    await pumpPage(tester, controller);
    final callsBefore = source.calls;

    await tester.tap(find.byKey(const Key('update-check-now')));
    await tester.pumpAndSettle();

    expect(source.calls, callsBefore + 1);
  });

  testWidgets('更新说明入口只打开已验证清单里的地址', (tester) async {
    Uri? opened;
    final controller = await buildController();
    await controller.checkNow();
    await pumpPage(
      tester,
      controller,
      openUrl: (url) async {
        opened = url;
        return true;
      },
    );

    await tester.tap(find.byKey(const Key('update-release-notes')));
    await tester.pumpAndSettle();

    expect(
      opened.toString(),
      'https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.9.0',
    );
  });

  testWidgets('诊断面板可以读取日志且日志不含业务内容', (tester) async {
    // 面板在列表底部；给一个更高的测试视口，避免 tap 落在屏幕外。
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await buildController();
    await controller.checkNow();
    await pumpPage(tester, controller);

    await tester.ensureVisible(find.byKey(const Key('update-load-logs')));
    await tester.tap(find.byKey(const Key('update-load-logs')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('update-log-content')), findsOneWidget);
    final text = tester
        .widget<SelectableText>(find.byKey(const Key('update-log-content')))
        .data!;
    expect(text, contains('ready target=1.9.0.0'));
    expect(text, isNot(contains('任务标题')));
  });

  testWidgets('有未保存编辑时安装按钮禁用并显示原因', (tester) async {
    final controller = await buildController();
    await controller.checkNow();
    safety.setUnsavedChanges(true);
    await pumpPage(tester, controller);

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('update-install')),
    );
    expect(button.onPressed, isNull);
    expect(
      find.text('请先保存或取消当前编辑，再进行更新。'),
      findsWidgets,
    );
  });
}

final class _MemorySettings implements SettingsRepository {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}




