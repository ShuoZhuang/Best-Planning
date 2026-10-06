// R2/W3：领域与项目的管理界面此前完全不存在，因此也没有任何路由。
//
// 与 preferences_route_test 一样只验证"可达性"：管理界面本身的行为由
// workspace_management_page_test 覆盖，领域与项目的语义由 workspace_service_test 覆盖。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/workspace/workspace_management_page.dart';

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5, 2);
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'id-${++_value}';
}

final class _EmptyWorkspace implements WorkspaceRepository {
  @override
  Future<List<PlannerArea>> listAreas() async => const [];

  @override
  Future<List<PlannerProject>> listProjects() async => const [];

  @override
  Future<void> saveArea(PlannerArea area) async {}

  @override
  Future<void> saveProject(PlannerProject project) async {}
}

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    WorkspaceService? workspace,
  }) async {
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          workspaceService: workspace,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('侧边导航可以进入领域与项目管理页', (tester) async {
    await pumpApp(
      tester,
      workspace: WorkspaceService(
        repository: _EmptyWorkspace(),
        clock: const _Clock(),
        idGenerator: _Ids(),
      ),
    );

    await tester.tap(find.text('领域'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(WorkspaceManagementPage), findsOneWidget);
    expect(find.text('领域服务未装配，暂无法管理领域与项目。'), findsNothing);
  });

  testWidgets('领域服务未装配时说明原因而不是空白页', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('领域'));
    await tester.pump();
    await tester.pump();

    expect(find.text('领域服务未装配，暂无法管理领域与项目。'), findsOneWidget);
    expect(find.byType(WorkspaceManagementPage), findsNothing);
  });
}
