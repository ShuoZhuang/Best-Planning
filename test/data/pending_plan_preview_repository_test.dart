// 1.11.0（计划 Task 3 Step 3/6）：通用持久预览仓储。
//
// 两条关键不变量：
// 1. 不同操作各自的 active 预览**互不 supersede**（DFR-004）；
// 2. 完整提案 JSON 与哈希随预览持久化——确认阶段不再从块重建"看起来可用"的提案。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/repositories/drift_pending_plan_preview_repository.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftPendingPlanPreviewRepository repository;

  setUp(() async {
    harness = await ExecutionTestHarness.create(seedTask: false);
    repository = DriftPendingPlanPreviewRepository(
      harness.database,
      clock: harness.clock,
    );
  });

  tearDown(() => harness.close());

  PendingPreviewBundle bundle({
    String id = 'preview-1',
    String operationId = 'adj-1',
    PendingPreviewKind kind = PendingPreviewKind.deferAdjustment,
    Duration expiresIn = const Duration(hours: 12),
  }) {
    final start = harness.clock.nowUtc().add(const Duration(days: 1));
    return PendingPreviewBundle(
      preview: PendingPlanPreview(
        previewId: id,
        kind: kind,
        operationId: operationId,
        basePlanVersionId: 'plan-1',
        inputHash: 'hash-1',
        algorithmVersion: '20',
        windowStartUtc: start,
        windowEndUtc: start.add(const Duration(days: 2)),
        timeZoneId: 'Asia/Shanghai',
        status: PendingPreviewStatus.active,
        createdAtUtc: harness.clock.nowUtc(),
        expiresAtUtc: harness.clock.nowUtc().add(expiresIn),
        summaryJson: '{"scheduledMinutes":60}',
        diagnosticsJson: '{}',
        revision: 1,
        proposalJson: '{"formatVersion":1,"proposal":{}}',
        proposalSha256: 'sha-$id',
      ),
      blocks: [
        PendingPlanPreviewBlock(
          previewId: id,
          blockId: '$id-block-1',
          taskId: 'task-1',
          cycleId: null,
          title: '写周报',
          startUtc: start,
          endUtc: start.add(const Duration(minutes: 30)),
          explanationCode: 'deferAdjustment',
          minutes: 30,
        ),
      ],
    );
  }

  test('两个独立调整的 active 预览互不覆盖，各自可读回', () async {
    await repository.saveActive(bundle(id: 'preview-1', operationId: 'adj-1'));
    await repository.saveActive(bundle(id: 'preview-2', operationId: 'adj-2'));

    final first = await repository.active(
      PendingPreviewKind.deferAdjustment,
      operationId: 'adj-1',
    );
    final second = await repository.active(
      PendingPreviewKind.deferAdjustment,
      operationId: 'adj-2',
    );

    expect(first!.preview.previewId, 'preview-1');
    expect(first.preview.status, PendingPreviewStatus.active);
    expect(second!.preview.previewId, 'preview-2');
    expect(second.preview.status, PendingPreviewStatus.active);
  });

  test('同一操作重新生成时旧 active 变 superseded，只保留一条 active', () async {
    await repository.saveActive(bundle(id: 'preview-1', operationId: 'adj-1'));
    await repository.saveActive(bundle(id: 'preview-2', operationId: 'adj-1'));

    final active = await repository.active(
      PendingPreviewKind.deferAdjustment,
      operationId: 'adj-1',
    );
    final old = await repository.byId('preview-1');

    expect(active!.preview.previewId, 'preview-2');
    expect(old!.status, PendingPreviewStatus.superseded);
  });

  test('周期预排与调整预览共用表但按 operationId 隔离', () async {
    await repository.saveActive(
      bundle(
        id: 'recurring-1',
        operationId: recurringLookaheadOperationId,
        kind: PendingPreviewKind.recurringLookahead,
      ),
    );
    await repository.saveActive(bundle(id: 'preview-1', operationId: 'adj-1'));

    final recurring = await repository.active(
      PendingPreviewKind.recurringLookahead,
      operationId: recurringLookaheadOperationId,
    );
    final adjustment = await repository.active(
      PendingPreviewKind.deferAdjustment,
      operationId: 'adj-1',
    );

    expect(recurring, isNotNull);
    expect(adjustment, isNotNull);
    expect(recurring!.preview.kind, PendingPreviewKind.recurringLookahead);
  });

  test('完整提案 JSON 与哈希跨读回逐字保留', () async {
    await repository.saveActive(bundle());

    final loaded = await repository.byId('preview-1');

    expect(loaded!.proposalJson, '{"formatVersion":1,"proposal":{}}');
    expect(loaded.proposalSha256, 'sha-preview-1');
    expect(loaded.formatVersion, 1);
    expect(loaded.operationId, 'adj-1');
    expect((await repository.blocks('preview-1')).single.title, '写周报');
  });

  test('过期预览在 expireBefore 之后变 stale，不能再被当作 active', () async {
    await repository.saveActive(bundle(expiresIn: const Duration(minutes: 1)));

    await repository.expireBefore(
      harness.clock.nowUtc().add(const Duration(minutes: 2)),
    );

    expect(
      (await repository.byId('preview-1'))!.status,
      PendingPreviewStatus.stale,
    );
    expect(
      await repository.active(
        PendingPreviewKind.deferAdjustment,
        operationId: 'adj-1',
      ),
      isNull,
    );
  });

  test('cleanup 只清终态，不碰 active 预览', () async {
    await repository.saveActive(bundle(id: 'preview-1', operationId: 'adj-1'));
    await repository.saveActive(
      bundle(
        id: 'preview-2',
        operationId: 'adj-2',
        expiresIn: const Duration(minutes: 1),
      ),
    );
    await repository.expireBefore(
      harness.clock.nowUtc().add(const Duration(minutes: 2)),
    );

    await repository.cleanup(
      nowUtc: harness.clock.nowUtc().add(const Duration(days: 60)),
      retainDays: 30,
    );

    expect(await repository.byId('preview-1'), isNotNull);
    expect(await repository.byId('preview-2'), isNull);
  });

  test('延后调整预览缺少完整提案时构造即拒绝', () {
    final start = harness.clock.nowUtc();
    expect(
      () => PendingPlanPreview(
        previewId: 'preview-x',
        kind: PendingPreviewKind.deferAdjustment,
        operationId: 'adj-x',
        basePlanVersionId: 'plan-1',
        inputHash: 'hash',
        algorithmVersion: '20',
        windowStartUtc: start,
        windowEndUtc: start.add(const Duration(days: 1)),
        timeZoneId: 'Asia/Shanghai',
        status: PendingPreviewStatus.active,
        createdAtUtc: start,
        expiresAtUtc: start.add(const Duration(hours: 1)),
        summaryJson: '{}',
        diagnosticsJson: '{}',
        revision: 1,
      ),
      throwsArgumentError,
    );
  });
}
