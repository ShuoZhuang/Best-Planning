import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftRecurringExecutionRepository repository;

  setUp(() async {
    harness = await ExecutionTestHarness.create();
    repository = DriftRecurringExecutionRepository(
      harness.database,
      clock: harness.clock,
      idGenerator: harness.ids,
    );
  });

  tearDown(() => harness.close());

  PendingPreviewBundle bundle({
    String id = 'preview-1',
    String blockId = 'preview-block-1',
    String status = 'active',
  }) {
    final start = harness.clock.nowUtc().add(const Duration(days: 7));
    final preview = PendingPlanPreview(
      previewId: id,
      kind: PendingPreviewKind.recurringLookahead,
      basePlanVersionId: 'plan-1',
      inputHash: 'hash-1',
      algorithmVersion: '20',
      windowStartUtc: start,
      windowEndUtc: start.add(const Duration(days: 7)),
      timeZoneId: 'Asia/Shanghai',
      status: PendingPreviewStatus.values.byName(status),
      createdAtUtc: harness.clock.nowUtc(),
      expiresAtUtc: harness.clock.nowUtc().add(const Duration(days: 1)),
      summaryJson: '{}',
      diagnosticsJson: '{}',
      revision: 1,
    );
    return PendingPreviewBundle(
      preview: preview,
      blocks: [
        PendingPlanPreviewBlock(
          previewId: id,
          blockId: blockId,
          taskId: 'task-1',
          cycleId: 'cycle-1',
          title: '每周阅读',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 45)),
          explanationCode: 'recurringLookahead',
          minutes: 45,
        ),
      ],
    );
  }

  test('预排持久化后可跨重启读取，块标题与周期身份保留', () async {
    await repository.replaceActivePreview(bundle());
    final active = await repository.activePreview(
      PendingPreviewKind.recurringLookahead,
    );
    expect(active, isNotNull);
    expect(active!.preview.previewId, 'preview-1');
    expect(active.blocks, hasLength(1));
    expect(active.blocks.single.cycleId, 'cycle-1');
    expect(active.blocks.single.title, '每周阅读');
  });

  test('新预排原子替换旧 active，旧版本保留为 superseded', () async {
    await repository.replaceActivePreview(bundle(id: 'preview-old'));
    await repository.replaceActivePreview(bundle(id: 'preview-new'));
    final active = await repository.activePreview(
      PendingPreviewKind.recurringLookahead,
    );
    expect(active!.preview.previewId, 'preview-new');
    final rows = await harness.database
        .customSelect('SELECT preview_id, status FROM pending_plan_previews')
        .get();
    expect(
      {
        for (final row in rows)
          row.read<String>('preview_id'): row.read<String>('status'),
      },
      {'preview-old': 'superseded', 'preview-new': 'active'},
    );
  });

  test('确认/拒绝改变状态但保留审计行', () async {
    await repository.replaceActivePreview(bundle());
    await repository.updatePreviewStatus(
      'preview-1',
      PendingPreviewStatus.rejected,
    );
    expect(
      await repository.activePreview(PendingPreviewKind.recurringLookahead),
      isNull,
    );
    final rows = await harness.database
        .customSelect('SELECT status FROM pending_plan_previews')
        .get();
    expect(rows.single.read<String>('status'), 'rejected');
  });
}
