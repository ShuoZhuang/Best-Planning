// 更新设置入口的可达性（路线图 §9「Router」/ §11 Task 11）。
//
// 与 `export_route_test`、`preferences_route_test` 同一套路：这里只验证**入口与路由**，
// 更新本身的语义由 `update_service_test`、`update_page_test` 覆盖。
//
// 两条相反方向的断言合起来才是"接好了"：
//   · 装配了更新服务 → 设置入口页列出「检查更新」，点进去是真正的更新页；
//   · 未装配 → **不列出该入口**（本仓库的既有约定：不给一个点了才知道没装的入口）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/app_version_provider.dart';
import 'package:personal_planner/application/update_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/settings/update/update_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/platform/update/github_release_client.dart';

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 8, 2);
}

/// **一次请求都不发**的客户端：路由用例不应该依赖任何网络实现。
final class _SilentClient implements GithubReleaseClient {
  int calls = 0;

  @override
  Future<GithubReleasesResponse> fetchReleases({String? etag}) async {
    calls++;
    return const GithubReleasesResponse(releases: []);
  }
}

UpdateService _service(
  SettingsRepository settings,
  GithubReleaseClient client,
) => UpdateService(
  client: client,
  clock: const _FixedClock(),
  settings: settings,
  versions: const FixedAppVersionProvider(AppVersion(1, 6, 2, build: 37)),
);

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    UpdateService? updateService,
  }) async {
    // 设置入口页在默认 800×600 里最后几条不会建立 element，点击会找不到控件。
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    // 首次教程闸门与首次引导是同一条套路（设置键 + 版本比较）。不喂这一条，
    // 整应用 pump 出来的会是教程页而不是主界面。
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          updateService: updateService,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置入口页可以进入更新设置页', (tester) async {
    final settings = MemorySettingsRepository();
    await pumpApp(tester, updateService: _service(settings, _SilentClient()));

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-update')));
    await tester.pumpAndSettle();

    expect(find.byType(UpdatePage), findsOneWidget);
    // 页面自带返回入口（壳层统一提供），子页面必须能回设置首页。
    expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
  });

  testWidgets('更新页在没有任何请求的情况下也能打开（离线不影响启动）', (tester) async {
    final settings = MemorySettingsRepository();
    final client = _SilentClient();
    await pumpApp(tester, updateService: _service(settings, client));

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-update')));
    await tester.pumpAndSettle();

    // **打开页面本身不发请求**：自动检查由调度器在启动约 10 秒后负责，页面只显示现状。
    expect(client.calls, 0);
    expect(find.byKey(const Key('update-check-now')), findsOneWidget);
  });

  testWidgets('更新设置入口显示当前版本与自动检查状态', (tester) async {
    final settings = MemorySettingsRepository();
    await pumpApp(tester, updateService: _service(settings, _SilentClient()));

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 入口右侧展示一项当前关键值：用户不点进去也能看出自动检查是开还是关。
    expect(find.byKey(const Key('settings-update-current')), findsOneWidget);
    expect(find.textContaining('自动检查已开启'), findsOneWidget);
  });

  testWidgets('未装配更新服务时设置入口页不列出该项', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-update')), findsNothing);
    expect(find.byKey(const Key('settings-rules')), findsOneWidget);
  });

  testWidgets('更新服务未装配时直达该路由会给出说明，而不是空白页', (tester) async {
    // 深链接（例如通知 payload 或用户手改地址）可能直接落在这一页。未装配时它必须说明
    // "服务未装配"，而不是渲染一个空白 Scaffold——那会让人以为程序卡住了。
    await pumpApp(tester);
    final context = tester.element(find.byType(Scaffold).first);
    GoRouter.of(context).go('/settings/update');
    await tester.pumpAndSettle();

    expect(find.text('检查更新'), findsWidgets);
    expect(find.textContaining('未装配'), findsOneWidget);
  });
}
