// W3/W6：数据导出页此前没有任何路由，而且 `ExportService` 在生产代码里从未被构造——
// 服务和文件适配器都写好并有测试，用户却完全够不到（FR-DATA-06）。
//
// 这里只验证可达性；导出内容本身的正确性由 export_service_test 覆盖，目录选择与写文件是
// 平台行为，本机只能经假端口验证。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/data/export_page.dart';

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 2);
}

final class _NoFacts implements ExportDataSource {
  const _NoFacts();
  @override
  Future<Map<String, List<Map<String, Object?>>>> loadAllFacts() async =>
      const {};
}

final class _NoFiles implements ExportFilePort {
  const _NoFiles();
  @override
  Future<String?> chooseDirectory() async => null;
  @override
  Future<String> writeNewFile({
    required String directory,
    required String preferredName,
    required Stream<List<int>> bytes,
  }) async => '';
}

ExportService _service() => ExportService(
  source: const _NoFacts(),
  files: const _NoFiles(),
  clock: const _FixedClock(),
);

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    ExportService? exportService,
  }) async {
    // 侧边导航已有 9 项，默认的 800x600 视口里最后几项不会建立 element，
    // 因此点击会找不到控件（Bad state: No element）。
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          settingsRepository: settings,
          exportService: exportService,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('侧边导航可以进入数据导出页', (tester) async {
    await pumpApp(tester, exportService: _service());

    // 数据导出不再是导航栏的一项，而是设置入口页下的一条（信息架构整理）。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-export')));
    await tester.pumpAndSettle();

    expect(find.byType(ExportPage), findsOneWidget);
    expect(find.text('导出服务未装配，暂无法导出数据。'), findsNothing);
  });

  testWidgets('导出服务未装配时设置入口页不列出该项', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 入口页只列出实际装配好的子页（见 app_lock_gate_test 的同类断言）。
    expect(find.byKey(const Key('settings-export')), findsNothing);
    expect(find.byKey(const Key('settings-rules')), findsOneWidget);
  });
}
