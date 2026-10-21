// 1.11.0（计划 Task 9 Step 6、DFR-009/018）：启动恢复提示的两种处置。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/adjustment_preview_port.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';
import 'package:personal_planner/features/planning/adjustment_recovery_prompt.dart';

final class _FakePort implements AdjustmentPreviewPort {
  int cancelCalls = 0;

  @override
  Future<AdjustmentPreviewView?> loadPreview(String adjustmentId) async => null;

  @override
  Future<bool> cancel(String adjustmentId) async {
    cancelCalls++;
    return true;
  }

  @override
  Future<AdjustmentApplyReceipt> confirmAdjustment({
    required String adjustmentId,
    required String previewId,
  }) async =>
      const AdjustmentApplyReceipt(status: AdjustmentApplyStatus.applied);

  @override
  Future<PlanUndoResult> undoAdjustment(String adjustmentId) async =>
      const PlanUndoResult(status: PlanUndoStatus.undone);
}

void main() {
  final now = DateTime.utc(2026, 10, 19, 1);

  PlanAdjustment adjustment({
    String id = 'adj-1',
    String title = '写周报',
    PlanAdjustmentStatus status = PlanAdjustmentStatus.previewReady,
  }) => PlanAdjustment(
    adjustmentId: id,
    kind: PlanAdjustmentKind.defer,
    targetBlockId: 'block-1',
    targetTaskId: 'task-1',
    targetTitleSnapshot: title,
    basePlanVersionId: 'plan-1',
    sourceStartUtc: DateTime.utc(2026, 10, 19, 2),
    sourceEndUtc: DateTime.utc(2026, 10, 19, 3),
    notBeforeUtc: DateTime.utc(2026, 10, 19, 2, 30),
    timeZoneId: 'Asia/Shanghai',
    requestedAmount: 30,
    requestedUnit: DeferUnit.minutes,
    status: status,
    createdAtUtc: now,
    expiresAtUtc: now.add(const Duration(hours: 12)),
    revision: 1,
    previewId: status == PlanAdjustmentStatus.previewReady ? 'p-1' : null,
  );

  Future<void> pumpPrompt(
    WidgetTester tester, {
    required _FakePort port,
    required List<PlanAdjustment> items,
    required List<String> opened,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAdjustmentRecoveryPrompt(
                context,
                port: port,
                items: items,
                onOpen: opened.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('继续查看会带着 adjustmentId 回到预览，不取消调整', (tester) async {
    final port = _FakePort();
    final opened = <String>[];
    await pumpPrompt(tester, port: port, items: [adjustment()], opened: opened);

    expect(find.text('有一次延后还没完成'), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    expect(find.text('预览已就绪，尚未确认'), findsOneWidget);

    await tester.tap(find.byKey(const Key('adjustment-recovery-open-0')));
    await tester.pumpAndSettle();

    expect(opened, ['adj-1']);
    expect(port.cancelCalls, 0);
    expect(find.text('有一次延后还没完成'), findsNothing);
  });

  testWidgets('放弃会调用显式取消并关闭对话框', (tester) async {
    final port = _FakePort();
    final opened = <String>[];
    await pumpPrompt(tester, port: port, items: [adjustment()], opened: opened);

    await tester.tap(find.byKey(const Key('adjustment-recovery-discard-0')));
    await tester.pumpAndSettle();

    expect(port.cancelCalls, 1);
    expect(opened, isEmpty);
    expect(find.text('有一次延后还没完成'), findsNothing);
  });

  testWidgets('没有待恢复项时不显示对话框', (tester) async {
    final port = _FakePort();
    await pumpPrompt(tester, port: port, items: const [], opened: <String>[]);

    expect(find.text('有一次延后还没完成'), findsNothing);
  });
}
