// 左下角更新入口在主导航的每个页面都保持同一位置与状态（UPD-022 / 规格 §11.1）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/application/update/update_orchestrator.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_settings.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

import '../support/update_doubles.dart';

void main() {
  late Directory directory;
  late InMemoryUpdateSafetyCoordinator safety;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('update_shell_test_');
    safety = InMemoryUpdateSafetyCoordinator();
  });

  tearDown(() {
    safety.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets('六个主页面都显示同一个更新入口', (tester) async {
    final verified = await verifiedManifestFixture();
    final orchestrator = UpdateOrchestrator(
      manifestSource: FakeManifestSource(ManifestFetchResult.verified(verified)),
      stateStore: InMemoryStateStore(),
      installedPackages: FakeInstalledPackages(),
      downloader: FakeDownloader(),
      verifier: FakeVerifier(),
      layout: UpdateStorageLayout(root: directory),
      safety: safety,
      log: MemoryLogSink(),
      clock: FakeClock(),
      diskSpace: FakeDiskSpace(50 * 1024 * 1024 * 1024),
    );
    final controller = UpdateController(
      orchestrator: orchestrator,
      settings: JsonUpdateSettingsStore(settings: MemorySettingsRepository()),
      safety: safety,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.checkNow();

    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          updateController: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['任务', '领域', '日历', '统计', '设置', '今日']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('update-indicator')),
        findsOneWidget,
        reason: '在 $label 页应仍然显示更新入口',
      );
    }
  });
}
