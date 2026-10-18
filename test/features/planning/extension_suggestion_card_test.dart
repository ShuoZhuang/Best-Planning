import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';

final _candidate = ExtensionDayCandidate(
  localDate: DateTime(2026, 10, 17),
  originalSleepStartOffsetMinutes: 1410,
  temporarySleepStartOffsetMinutes: 1500,
  fixedWakeOffsetMinutes: 1890,
  addedPlaceableMinutes: 60,
  sleepLossMinutes: 90,
  triggeringTaskIds: const ['task-1'],
  stableKey: '2026-10-17|1500|1890|task-1',
);

PlanPreviewModel _model() => PlanPreviewModel(
  proposalId: 'proposal-1',
  changes: const [],
  issues: const [],
  isStale: false,
  extensionCandidates: [_candidate],
);

void main() {
  testWidgets('延长建议卡提供自定义入口与拒绝入口，拒绝后立即隐藏', (tester) async {
    var rejected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: _model(),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
          onRejectExtension: () async => rejected++,
          onCustomExtension: (date, endMinute) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('可以临时延长'), findsOneWidget);
    expect(find.text('自定义日期和时间'), findsOneWidget);
    expect(find.text('本次不采用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reject-extension-day')));
    await tester.pumpAndSettle();

    expect(rejected, 1);
    expect(find.textContaining('可以临时延长'), findsNothing);
  });

  testWidgets('点击自定义入口打开日期选择器，取消零写入', (tester) async {
    var customCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: _model(),
          autoAdjustStore: MemoryAutoAdjustStore(),
          onConfirm: (mode) async => ApplyPlanResult.stale(),
          onCustomExtension: (date, endMinute) async => customCalls++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('custom-extension-day')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(customCalls, 0);
  });
}
