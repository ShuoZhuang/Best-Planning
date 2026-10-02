import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/features/focus/focus_recovery_dialog.dart';

void main() {
  testWidgets('恢复对话框允许修正结束时间、实际时长和备注', (tester) async {
    FocusRecoveryConfirmation? confirmation;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusRecoveryDialog(
            request: FocusRecoveryRequest(
              session: FocusSession(
                id: 'focus-1',
                taskId: 'task-1',
                startedAtUtc: DateTime.utc(2026, 10, 2, 9),
                lastWallAtUtc: DateTime.utc(2026, 10, 2, 9, 10),
                phase: FocusPhase.running,
                activeDuration: const Duration(minutes: 10),
                recoveryState: FocusRecoveryState.needsConfirmation,
              ),
              suggestedEndUtc: DateTime.utc(2026, 10, 2, 10),
              wallClockDriftDetected: true,
            ),
            onConfirm: (value) async => confirmation = value,
            onDiscard: () async {},
          ),
        ),
      ),
    );

    expect(find.text('需要确认本次专注'), findsOneWidget);
    expect(find.textContaining('系统时间可能发生跳变'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('recovery-end-time')), '09:50');
    await tester.enterText(
      find.byKey(const Key('recovery-actual-minutes')),
      '45',
    );
    await tester.enterText(find.byKey(const Key('recovery-note')), '完成了阅读');
    await tester.tap(find.text('确认并计入统计'));
    await tester.pumpAndSettle();

    expect(confirmation?.endedAtUtc, DateTime.utc(2026, 10, 2, 9, 50));
    expect(confirmation?.actualMinutes, 45);
    expect(confirmation?.note, '完成了阅读');
  });
}
