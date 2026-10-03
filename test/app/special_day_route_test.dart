// W3/Task 11：特殊日与恢复保护的路由、入口，以及"生成后能去确认"。
//
// C8 之后恢复例外是**提案输入**而不是持久设置，因此这条链路必须真正可达：页面早已存在，
// 却从来没有路由，也没有任何界面指向它；而且生成的提案没有地方确认——本文件验证的正是
// 最后这一步：外壳入口 → 装配当日规则与日程 → 生成方案 → 调整预览。
//
// 这里用假的 `ProposalCreator` 而不是真实 `PlanningService`：后者在 `Isolate.run` 里排程，
// widget 测试的时钟不会等它，因此那条路径应在 `integration_test` 里跑（Task 20）。
// 本文件关心的是我新增的接线，不是排程本身。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/special_day/special_day_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

final class _NoEvents implements CalendarRepository {
  const _NoEvents();

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

/// 立即返回一份空提案，不带 isolate，因此 widget 测试能确定地走完流程。
final class _ImmediateCreator implements ProposalCreator {
  int calls = 0;

  @override
  Future<ScheduleProposal> createProposal({ScheduleRuleOverride? override}) async {
    calls++;
    return ScheduleProposal(
      proposalId: 'recovery-proposal',
      inputHash: 'hash',
      algorithmVersion: '1',
      blocks: const [],
      unscheduled: const [],
      conflicts: const [],
      explanations: const [],
      metrics: const ProposalMetrics(
        isFullyFeasible: true,
        scheduledMinutes: 0,
        unscheduledMinutes: 0,
      ),
      ruleOverride: override,
    );
  }
}

void main() {
  late _ImmediateCreator creator;
  late RecoveryPlanningService recovery;

  setUp(() {
    creator = _ImmediateCreator();
    recovery = RecoveryPlanningService(
      planning: creator,
      zones: TimeZoneDatabase(),
    );
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    bool withRecovery = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(timeZoneId: 'Asia/Shanghai', 
          settingsRepository: settings,
          recovery: withRecovery ? recovery : null,
          calendar: withRecovery ? const _NoEvents() : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('外壳入口进入特殊日页，并带上当日规则与固定日程', (tester) async {
    await pumpApp(tester);

    final entry = find.byKey(const Key('open-special-day'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(SpecialDayPage), findsOneWidget);
    expect(find.text('特殊日与恢复保护'), findsOneWidget);
    // 缺少装配时这一页根本渲染不出来（它会要求必填的规则与事件），因此走到这里
    // 就说明"当日规则 + 当日固定日程"确实被装上了。
    expect(find.text('生成恢复方案'), findsOneWidget);
  });

  testWidgets('生成恢复方案后可从页面走到调整预览', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open-special-day')));
    await tester.pumpAndSettle();

    // 生成按钮没有 Key（页面用文案），因此按文案点。
    final generate = find.text('生成恢复方案');
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pumpAndSettle();

    // 提案真的被生成了：服务被调用，且页面给出了通往确认的入口。
    expect(creator.calls, 1);
    final openPreview = find.byKey(const Key('open-recovery-preview'));
    expect(openPreview, findsOneWidget);

    await tester.ensureVisible(openPreview);
    await tester.tap(openPreview);
    await tester.pumpAndSettle();

    // 恢复方案只是一份提案；此前用户拿到它却无处确认。能走到预览即闭环。
    expect(find.byType(PlanPreviewPage), findsOneWidget);
  });

  testWidgets('未装配恢复服务时外壳不显示该入口', (tester) async {
    await pumpApp(tester, withRecovery: false);

    // 宁可没有按钮，也不要一个点了没反应的控件。
    expect(find.byKey(const Key('open-special-day')), findsNothing);
  });
}
