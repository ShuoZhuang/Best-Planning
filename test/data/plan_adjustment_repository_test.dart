// 1.11.0（计划 Task 3 Step 1）：调整仓储的 round-trip、CAS 与审计事件。
//
// 这一层钉住事务化修复的地基：**每次状态转换都必须是一条带修订号的条件更新**，
// 零行更新返回 null（正常并发），并且必然留下连续事件——否则 DFR-036 的
// "结果可复算"就无从谈起。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/repositories/drift_plan_adjustment_repository.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  late ExecutionTestHarness harness;
  late DriftPlanAdjustmentRepository repository;

  setUp(() async {
    harness = await ExecutionTestHarness.create(seedTask: false);
    repository = DriftPlanAdjustmentRepository(
      harness.database,
      clock: harness.clock,
    );
  });

  tearDown(() => harness.close());

  PlanAdjustment adjustment({
    String id = 'adj-1',
    String blockId = 'block-1',
    PlanAdjustmentStatus status = PlanAdjustmentStatus.active,
    int revision = 1,
    String? previewId,
    String? appliedPlanVersionId,
    Duration expiresIn = const Duration(hours: 12),
    String title = '写周报',
  }) {
    final now = harness.clock.nowUtc();
    return PlanAdjustment(
      adjustmentId: id,
      kind: PlanAdjustmentKind.defer,
      targetBlockId: blockId,
      targetTaskId: 'task-1',
      targetTitleSnapshot: title,
      basePlanVersionId: 'plan-1',
      sourceStartUtc: now.add(const Duration(hours: 1)),
      sourceEndUtc: now.add(const Duration(hours: 2)),
      notBeforeUtc: now.add(const Duration(hours: 2)),
      timeZoneId: 'Asia/Shanghai',
      requestedAmount: 30,
      requestedUnit: DeferUnit.minutes,
      status: status,
      createdAtUtc: now,
      expiresAtUtc: now.add(expiresIn),
      revision: revision,
      targetSiblingBlockIds: const ['block-2', 'block-3'],
      previewId: previewId,
      appliedPlanVersionId: appliedPlanVersionId,
    );
  }

  test('创建后可逐值读回，兄弟块快照与标题原样保留', () async {
    await repository.create(adjustment());

    final loaded = await repository.byId('adj-1');

    expect(loaded, isNotNull);
    expect(loaded!.adjustmentId, 'adj-1');
    expect(loaded.targetTitleSnapshot, '写周报');
    expect(loaded.targetSiblingBlockIds, {'block-2', 'block-3'});
    expect(loaded.requestedUnit, DeferUnit.minutes);
    expect(loaded.requestedAmount, 30);
    expect(loaded.status, PlanAdjustmentStatus.active);
    expect(loaded.revision, 1);
    expect(await repository.byId('missing'), isNull);
  });

  test('创建即写一条 from==to 的初始事件，后续 CAS 事件序号连续', () async {
    await repository.create(adjustment());

    await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.active},
      to: PlanAdjustmentStatus.generating,
    );
    await repository.compareAndSet(
      expected: PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.generating},
      to: PlanAdjustmentStatus.previewReady,
      previewId: 'preview-1',
    );

    final events = await repository.events('adj-1');
    expect(events.map((e) => e.sequence), [1, 2, 3]);
    expect(events[1].fromStatus, PlanAdjustmentStatus.active);
    expect(events[1].toStatus, PlanAdjustmentStatus.generating);
    expect(events[2].toStatus, PlanAdjustmentStatus.previewReady);
  });

  test('revision 或基线不匹配时 CAS 返回 null 且不写事件（正常并发）', () async {
    await repository.create(adjustment());

    final wrongRevision = await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 9,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.active},
      to: PlanAdjustmentStatus.generating,
    );
    final wrongBase = await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-other',
      ),
      from: {PlanAdjustmentStatus.active},
      to: PlanAdjustmentStatus.generating,
    );

    expect(wrongRevision, isNull);
    expect(wrongBase, isNull);
    expect(
      (await repository.byId('adj-1'))!.status,
      PlanAdjustmentStatus.active,
    );
    expect(await repository.events('adj-1'), hasLength(1));
  });

  test('状态不在 from 集合时 CAS 不写库（旧预览不能二次确认）', () async {
    await repository.create(
      adjustment(
        status: PlanAdjustmentStatus.applied,
        appliedPlanVersionId: 'plan-8',
      ),
    );

    final result = await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.previewReady},
      to: PlanAdjustmentStatus.applying,
    );

    expect(result, isNull);
    expect(
      (await repository.byId('adj-1'))!.status,
      PlanAdjustmentStatus.applied,
    );
  });

  test('重生 CAS 递增 revision 并清掉旧 preview', () async {
    await repository.create(adjustment());
    await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.active},
      to: PlanAdjustmentStatus.generating,
    );
    await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.generating},
      to: PlanAdjustmentStatus.previewReady,
      previewId: 'preview-1',
    );

    final regenerated = await repository.compareAndSet(
      expected: const PlanAdjustmentToken(
        adjustmentId: 'adj-1',
        revision: 1,
        basePlanVersionId: 'plan-1',
      ),
      from: {PlanAdjustmentStatus.previewReady},
      to: PlanAdjustmentStatus.generating,
      incrementRevision: true,
    );

    expect(regenerated, isNotNull);
    expect(regenerated!.revision, 2);
    expect(regenerated.previewId, isNull);
    expect(regenerated.requestedAmount, 30, reason: '重生不得丢失原意');
    expect(regenerated.requestedUnit, DeferUnit.minutes);
  });

  test('同一个 preview 不能被两个调整认领（跨行唯一约束）', () async {
    await repository.create(
      adjustment(
        id: 'adj-1',
        status: PlanAdjustmentStatus.previewReady,
        previewId: 'preview-1',
      ),
    );

    await expectLater(
      repository.create(
        adjustment(
          id: 'adj-2',
          blockId: 'block-2',
          status: PlanAdjustmentStatus.previewReady,
          previewId: 'preview-1',
        ),
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('同一个 applied 计划版本不能被两个调整认领', () async {
    await repository.create(
      adjustment(
        id: 'adj-1',
        status: PlanAdjustmentStatus.applied,
        appliedPlanVersionId: 'plan-8',
      ),
    );

    await expectLater(
      repository.create(
        adjustment(
          id: 'adj-2',
          blockId: 'block-2',
          status: PlanAdjustmentStatus.applied,
          appliedPlanVersionId: 'plan-8',
        ),
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('openForTargetBlock 只返回未终结的调整（两个调整互不覆盖）', () async {
    await repository.create(adjustment(id: 'adj-1'));
    await repository.create(
      adjustment(id: 'adj-2', status: PlanAdjustmentStatus.cancelled),
    );

    final open = await repository.openForTargetBlock('block-1');

    expect(open.map((a) => a.adjustmentId), ['adj-1']);
  });

  test('recoverable 排除终态，按过期时间升序', () async {
    await repository.create(adjustment(id: 'adj-1'));
    await repository.create(
      adjustment(
        id: 'adj-2',
        blockId: 'block-2',
        status: PlanAdjustmentStatus.cancelled,
      ),
    );
    await repository.create(
      adjustment(
        id: 'adj-3',
        blockId: 'block-3',
        expiresIn: const Duration(hours: 1),
      ),
    );

    final recoverable = await repository.recoverable(harness.clock.nowUtc());

    expect(recoverable.map((a) => a.adjustmentId), ['adj-3', 'adj-1']);
  });

  test('expireBefore 只把过期的活状态标成 expired 并写事件', () async {
    await repository.create(
      adjustment(id: 'adj-1', expiresIn: const Duration(minutes: 1)),
    );
    await repository.create(
      adjustment(
        id: 'adj-2',
        blockId: 'block-2',
        expiresIn: const Duration(hours: 5),
      ),
    );

    final now = harness.clock.nowUtc().add(const Duration(minutes: 2));
    await repository.expireBefore(now);

    expect(
      (await repository.byId('adj-1'))!.status,
      PlanAdjustmentStatus.expired,
    );
    expect(
      (await repository.byId('adj-2'))!.status,
      PlanAdjustmentStatus.active,
    );
    final expiredEvents = await repository.events('adj-1');
    expect(expiredEvents.last.toStatus, PlanAdjustmentStatus.expired);
    expect(
      expiredEvents.last.reasonCode,
      PlanAdjustmentFailureCode.previewExpired,
    );
  });

  test('basePlanVersion 查询覆盖该基线上的全部调整（撤销与审计用）', () async {
    await repository.create(adjustment(id: 'adj-1'));
    await repository.create(
      adjustment(
        id: 'adj-2',
        blockId: 'block-2',
        status: PlanAdjustmentStatus.applied,
        appliedPlanVersionId: 'plan-8',
      ),
    );

    final onBase = await repository.byBasePlanVersion('plan-1');

    expect(onBase.map((a) => a.adjustmentId), ['adj-1', 'adj-2']);
  });
}
