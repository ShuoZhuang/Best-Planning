import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

void main() {
  testWidgets('preview groups every change and expands reasons', (
    tester,
  ) async {
    final model = PlanPreviewModel(
      proposalId: 'proposal-1',
      changes: const [
        PreviewChange(
          kind: PreviewChangeKind.added,
          title: '新增复习',
          reason: '临近截止时间',
        ),
        PreviewChange(
          kind: PreviewChangeKind.moved,
          title: '移动实验',
          reason: '匹配高精力时段',
        ),
        PreviewChange(
          kind: PreviewChangeKind.split,
          title: '拆分论文',
          reason: '分成两个专注片段',
        ),
        PreviewChange(
          kind: PreviewChangeKind.removed,
          title: '移除游戏',
          reason: '当天容量不足',
        ),
      ],
      conflicts: const ['周三缺少 30 分钟'],
      isStale: true,
    );
    final store = MemoryAutoAdjustStore();
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: store,
          onConfirm: () async {},
        ),
      ),
    );

    expect(find.text('新增'), findsOneWidget);
    expect(find.text('移动'), findsOneWidget);
    expect(find.text('拆分'), findsOneWidget);
    expect(find.text('移除'), findsOneWidget);
    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('周三缺少 30 分钟'), findsOneWidget);

    await tester.tap(find.text('移动实验'));
    await tester.pumpAndSettle();
    expect(find.text('匹配高精力时段'), findsOneWidget);

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '确认应用'),
    );
    expect(confirm.onPressed, isNull);
    expect(find.text('提案已过期，请重新计算'), findsOneWidget);
    expect(store.enabled, isFalse);
  });

  testWidgets('auto adjust defaults off but retains preview history', (
    tester,
  ) async {
    final store = MemoryAutoAdjustStore();
    var confirmations = 0;
    final model = PlanPreviewModel(
      proposalId: 'proposal-2',
      changes: const [
        PreviewChange(
          kind: PreviewChangeKind.added,
          title: '新增任务',
          reason: '优先级较高',
        ),
      ],
      conflicts: const [],
      isStale: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlanPreviewPage(
          model: model,
          autoAdjustStore: store,
          onConfirm: () async => confirmations++,
        ),
      ),
    );

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.ensureVisible(find.text('确认应用'));
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();

    expect(store.enabled, isTrue);
    expect(store.history, contains('proposal-2'));
    expect(confirmations, 1);
  });
}
