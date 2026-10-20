// 1.11.0（计划 Task 9 Step 3/7）：持久预览页的单飞、错误收口与无裸 UUID。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/adjustment_preview_port.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';
import 'package:personal_planner/features/planning/adjustment_preview_page.dart';

final class _FakePort implements AdjustmentPreviewPort {
  _FakePort({this.view});

  AdjustmentPreviewView? view;
  AdjustmentApplyReceipt? confirmResult;
  Completer<AdjustmentApplyReceipt>? pendingConfirm;
  Completer<bool>? pendingCancel;
  int confirmCalls = 0;
  int cancelCalls = 0;

  @override
  Future<AdjustmentPreviewView?> loadPreview(String adjustmentId) async => view;

  @override
  Future<bool> cancel(String adjustmentId) async {
    cancelCalls++;
    if (pendingCancel != null) return pendingCancel!.future;
    return true;
  }

  @override
  Future<AdjustmentApplyReceipt> confirmAdjustment({
    required String adjustmentId,
    required String previewId,
  }) {
    confirmCalls++;
    if (pendingConfirm != null) return pendingConfirm!.future;
    return Future.value(
      confirmResult ??
          const AdjustmentApplyReceipt(
            status: AdjustmentApplyStatus.applied,
            planVersionId: 'plan-2',
          ),
    );
  }

  @override
  Future<PlanUndoResult> undoAdjustment(String adjustmentId) async =>
      const PlanUndoResult(status: PlanUndoStatus.undone);
}

void main() {
  final zones = TimeZoneDatabase();
  final now = DateTime.utc(2026, 10, 19, 1);

  AdjustmentPreviewView view({
    PlanAdjustmentStatus status = PlanAdjustmentStatus.previewReady,
    bool withPreview = true,
    String title = '写周报',
  }) {
    final value = PlanAdjustment(
      adjustmentId: 'adj-1',
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
      previewId: withPreview ? 'preview-1' : null,
    );
    return AdjustmentPreviewView(
      adjustment: value,
      preview: withPreview
          ? PendingPreviewBundle(
              preview: PendingPlanPreview(
                previewId: 'preview-1',
                kind: PendingPreviewKind.deferAdjustment,
                operationId: 'adj-1',
                basePlanVersionId: 'plan-1',
                inputHash: 'hash',
                algorithmVersion: '20',
                windowStartUtc: DateTime.utc(2026, 10, 19),
                windowEndUtc: DateTime.utc(2026, 10, 26),
                timeZoneId: 'Asia/Shanghai',
                status: PendingPreviewStatus.active,
                createdAtUtc: now,
                expiresAtUtc: now.add(const Duration(hours: 12)),
                summaryJson: '{"targetStartUtc":1792379400000000}',
                diagnosticsJson: '{}',
                revision: 1,
                proposalJson: '{"formatVersion":1,"proposal":{}}',
                proposalSha256: List.filled(64, 'a').join(),
              ),
              blocks: [
                PendingPlanPreviewBlock(
                  previewId: 'preview-1',
                  blockId: 'block-1',
                  taskId: 'task-1',
                  cycleId: null,
                  title: title,
                  startUtc: DateTime.utc(2026, 10, 19, 2, 30),
                  endUtc: DateTime.utc(2026, 10, 19, 3, 30),
                  explanationCode: 'deferAdjustment',
                  minutes: 60,
                ),
              ],
            )
          : null,
    );
  }

  Widget host(AdjustmentPreviewPort port) => MaterialApp(
    home: AdjustmentPreviewPage(
      adjustmentId: 'adj-1',
      port: port,
      zones: zones,
      timeZoneId: 'Asia/Shanghai',
    ),
  );

  testWidgets('预览页显示标题、原时间与最早可开始，且不出现内部 ID', (tester) async {
    final port = _FakePort(view: view());
    await tester.pumpWidget(host(port));
    await tester.pumpAndSettle();

    expect(find.text('写周报'), findsWidgets);
    expect(find.textContaining('原时间'), findsOneWidget);
    expect(find.textContaining('最早可开始'), findsOneWidget);
    expect(find.textContaining('实际位置可能更晚'), findsOneWidget);
    expect(find.byKey(const Key('adjustment-confirm')), findsOneWidget);
    expect(find.textContaining('adj-1'), findsNothing);
    expect(find.textContaining('block-1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认期间按钮禁用，双击只提交一次', (tester) async {
    final port = _FakePort(view: view());
    port.pendingConfirm = Completer<AdjustmentApplyReceipt>();
    await tester.pumpWidget(host(port));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('adjustment-confirm')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('adjustment-confirm')));
    await tester.pump();

    expect(port.confirmCalls, 1);
    expect(find.text('处理中…'), findsOneWidget);

    port.pendingConfirm!.complete(
      const AdjustmentApplyReceipt(
        status: AdjustmentApplyStatus.applied,
        planVersionId: 'plan-2',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('计划已更新。'), findsOneWidget);
  });

  testWidgets('stale 预览禁用确认并给出可理解原因', (tester) async {
    final port = _FakePort(
      view: view(status: PlanAdjustmentStatus.stale, withPreview: false),
    );
    await tester.pumpWidget(host(port));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adjustment-confirm')), findsNothing);
    expect(find.textContaining('预览已过期'), findsOneWidget);
    expect(find.byKey(const Key('adjustment-cancel')), findsNothing);
  });

  testWidgets('取消失败时保留页面并提示', (tester) async {
    final port = _FakePort(view: view());
    port.pendingCancel = Completer<bool>();
    await tester.pumpWidget(host(port));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('adjustment-cancel')));
    await tester.pump();
    port.pendingCancel!.complete(false);
    await tester.pumpAndSettle();

    expect(port.cancelCalls, 1);
    expect(find.text('这次调整已经结束，无法取消。'), findsOneWidget);
    expect(find.byKey(const Key('adjustment-confirm')), findsOneWidget);
  });
}
