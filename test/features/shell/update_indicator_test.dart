// 左下角入口的组件行为（UPD-022 / UPD-023 / UPD-024 / UPD-025）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_settings.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/shell/update_indicator.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../../support/update_doubles.dart';

void main() {
  late Directory directory;
  late InMemoryStateStore store;
  late InMemoryUpdateSafetyCoordinator safety;
  late FakeInstalledPackages installed;
  late FakeDownloader downloader;
  late FakeVerifier verifier;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_indicator_test_');
    store = InMemoryStateStore();
    safety = InMemoryUpdateSafetyCoordinator();
    installed = FakeInstalledPackages();
    downloader = FakeDownloader();
    verifier = FakeVerifier();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<UpdateController> buildController({
    ManifestFetchResult? fetchResult,
    UpdatePackageDownloader? packageDownloader,
  }) async {
    final verified = await verifiedManifestFixture();
    final orchestrator = UpdateOrchestrator(
      manifestSource: FakeManifestSource(
        fetchResult ?? ManifestFetchResult.verified(verified),
      ),
      stateStore: store,
      installedPackages: installed,
      downloader: packageDownloader ?? downloader,
      verifier: verifier,
      layout: UpdateStorageLayout(root: directory),
      safety: safety,
      log: MemoryLogSink(),
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );
    final controller = UpdateController(
      orchestrator: orchestrator,
      settings: JsonUpdateSettingsStoreFixture().store,
      safety: safety,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpIndicator(
    WidgetTester tester,
    UpdateController controller, {
    VoidCallback? onOpenDetails,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 620,
            child: UpdateIndicator(
              controller: controller,
              onOpenDetails: onOpenDetails,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空闲/已是最新时不显示入口', (tester) async {
    final controller = await buildController();
    await pumpIndicator(tester, controller);

    expect(find.byKey(const Key('update-indicator')), findsNothing);
  });

  testWidgets('发现更新并下载完成后显示就绪入口', (tester) async {
    final controller = await buildController();
    await controller.checkNow();
    await pumpIndicator(tester, controller);

    expect(controller.state.phase, UpdatePhase.ready);
    expect(find.byKey(const Key('update-indicator')), findsOneWidget);
    expect(find.text('更新已就绪'), findsOneWidget);
  });

  testWidgets('点击就绪入口立即安装，不出现任何对话框（UPD-024）', (tester) async {
    final controller = await buildController();
    await controller.checkNow();
    await pumpIndicator(tester, controller);

    await tester.tap(find.byKey(const Key('update-indicator-button')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    // 没有装配原生安装链时，状态给出明确原因，而不是 pretended success。
    expect(controller.state.phase, UpdatePhase.failed);
  });

  testWidgets('有未保存编辑时就绪入口禁用安装并展开原因', (tester) async {
    final controller = await buildController();
    await controller.checkNow();
    safety.setUnsavedChanges(true);
    await pumpIndicator(tester, controller);

    expect(find.text('更新已就绪（暂时不可用）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-indicator-button')));
    await tester.pumpAndSettle();

    expect(find.text('请先保存或取消当前编辑，再进行更新。'), findsOneWidget);
    expect(
      find.byKey(const Key('update-indicator-card-install')),
      findsNothing,
    );
  });

  testWidgets('下载中点击展开非模态状态卡，不抢焦点不遮挡', (tester) async {
    final blocking = BlockingDownloader();
    final controller = await buildController(packageDownloader: blocking);
    await pumpIndicator(tester, controller);

    final check = controller.checkNow();
    await blocking.started.future;
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('正在下载更新'), findsOneWidget);
    await tester.tap(find.byKey(const Key('update-indicator-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('update-indicator-status-card')),
      findsOneWidget,
    );
    expect(find.byType(Dialog), findsNothing);

    blocking.complete(
      DownloadOutcome.success(
        path: '${directory.path}${Platform.pathSeparator}package.msix.ready',
        sizeBytes: 2048,
        sha256:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ),
    );
    await check;
    await tester.pumpAndSettle();
    expect(controller.state.phase, UpdatePhase.ready);
  });

  testWidgets('详情按钮回到设置页', (tester) async {
    var opened = false;
    final controller = await buildController();
    await controller.checkNow();
    safety.setUnsavedChanges(true);
    await pumpIndicator(tester, controller, onOpenDetails: () => opened = true);

    await tester.tap(find.byKey(const Key('update-indicator-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('update-indicator-card-details')));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });
}

/// 用内存设置仓库构造真实的 `JsonUpdateSettingsStore`。
final class JsonUpdateSettingsStoreFixture {
  JsonUpdateSettingsStoreFixture();

  final store = JsonUpdateSettingsStore(settings: _MemorySettings());
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
