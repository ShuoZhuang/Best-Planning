// 自动重排（FR-REPLAN-01/03/04/05）**对用户可见**的那一半。
//
// 协调器"算完就完了"是不够的：不开"信任自动调整"时按 FR-REPLAN-03 必须由用户确认，
// 而用户只有在**被告知**有一份新计划时才可能去确认。本文件钉住的因此不是"服务被调用了"
// （那由 `test/application/replanning_coordinator_test.dart` 覆盖），而是三件界面事实：
// 1. 未自动应用时**出现提示**，并且带一个**可点击**的去处；
// 2. 自动应用成功时提示如实说"已自动应用"，且**不给**一个没用的"查看调整"；
// 3. 同一个提案**只提示一次**——连续改动会连发结果，重复提示会把真正新的那条淹没。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester,
    ValueNotifier<ReplanOutcome?> outcome,
  ) async {
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
          replanOutcome: outcome,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('等待确认时弹出提示，并给出"查看调整"入口', (tester) async {
    final outcome = ValueNotifier<ReplanOutcome?>(null);
    addTearDown(outcome.dispose);
    await pumpApp(tester, outcome);

    outcome.value = const ReplanOutcome.pending('p-1');
    await tester.pumpAndSettle();

    expect(find.text('计划已按最近的改动重算，等待你确认'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '查看调整'), findsOneWidget);
  });

  testWidgets('点"查看调整"跳到该提案的预览页', (tester) async {
    final outcome = ValueNotifier<ReplanOutcome?>(null);
    addTearDown(outcome.dispose);
    await pumpApp(tester, outcome);

    outcome.value = const ReplanOutcome.pending('p-1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看调整'));
    await tester.pumpAndSettle();

    // 未装配排程服务时预览页如实说明，而不是白屏——这同时证明**导航真的发生了**。
    expect(find.textContaining('未装配'), findsWidgets);
  });

  testWidgets('自动应用成功时如实说明，且不给"查看调整"', (tester) async {
    final outcome = ValueNotifier<ReplanOutcome?>(null);
    addTearDown(outcome.dispose);
    await pumpApp(tester, outcome);

    outcome.value = const ReplanOutcome(
      proposalId: 'p-2',
      applied: true,
      message: '已自动应用调整',
    );
    await tester.pumpAndSettle();

    expect(find.text('已自动应用调整'), findsOneWidget);
    expect(find.text('查看调整'), findsNothing);
  });

  testWidgets('同一个提案只提示一次', (tester) async {
    final outcome = ValueNotifier<ReplanOutcome?>(null);
    addTearDown(outcome.dispose);
    await pumpApp(tester, outcome);

    outcome.value = const ReplanOutcome.pending('p-1');
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);

    // 同一个提案再推一次（协调器在去抖窗口边界上可能重复回报）。
    outcome.value = const ReplanOutcome.pending('p-1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SnackBar), findsOneWidget);
  });
}
