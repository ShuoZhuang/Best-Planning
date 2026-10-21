// 1.11.0（计划 Task 2）：不可变调整操作的值语义。
//
// 这一层钉住"一个调整对象本身不能是半成品"：身份、UTC 口径、目标快照、
// 修订号与过期时间在构造时就被校验，之后只能通过状态机产生新对象。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/defer_unit.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';

void main() {
  final created = DateTime.utc(2026, 10, 12, 1);
  final start = DateTime.utc(2026, 10, 12, 2);
  final end = DateTime.utc(2026, 10, 12, 3, 30);
  final notBefore = DateTime.utc(2026, 10, 12, 2, 30);

  PlanAdjustment build({
    String adjustmentId = 'adj-1',
    String targetBlockId = 'block-1',
    String targetTaskId = 'task-1',
    String title = '写周报',
    DateTime? sourceStartUtc,
    DateTime? sourceEndUtc,
    DateTime? notBeforeUtc,
    String timeZoneId = 'Asia/Shanghai',
    int amount = 30,
    DeferUnit unit = DeferUnit.minutes,
    PlanAdjustmentStatus status = PlanAdjustmentStatus.active,
    DateTime? createdAtUtc,
    DateTime? expiresAtUtc,
    int revision = 1,
    Iterable<String> siblingIds = const [],
    String? previewId,
    String? appliedPlanVersionId,
  }) => PlanAdjustment(
    adjustmentId: adjustmentId,
    kind: PlanAdjustmentKind.defer,
    targetBlockId: targetBlockId,
    targetTaskId: targetTaskId,
    targetTitleSnapshot: title,
    basePlanVersionId: 'plan-7',
    sourceStartUtc: sourceStartUtc ?? start,
    sourceEndUtc: sourceEndUtc ?? end,
    notBeforeUtc: notBeforeUtc ?? notBefore,
    timeZoneId: timeZoneId,
    requestedAmount: amount,
    requestedUnit: unit,
    status: status,
    createdAtUtc: createdAtUtc ?? created,
    expiresAtUtc: expiresAtUtc ?? created.add(const Duration(hours: 12)),
    revision: revision,
    targetSiblingBlockIds: siblingIds,
    previewId: previewId,
    appliedPlanVersionId: appliedPlanVersionId,
  );

  group('构造期校验', () {
    test('空 id、空时区、非法修订号被拒绝', () {
      expect(() => build(adjustmentId: '   '), throwsArgumentError);
      expect(() => build(targetBlockId: ''), throwsArgumentError);
      expect(() => build(targetTaskId: ' '), throwsArgumentError);
      expect(() => build(timeZoneId: ''), throwsArgumentError);
      expect(() => build(revision: 0), throwsArgumentError);
    });

    test('非 UTC 的时刻被拒绝', () {
      expect(
        () => build(sourceStartUtc: DateTime(2026, 10, 12, 2)),
        throwsArgumentError,
      );
      expect(
        () => build(sourceEndUtc: DateTime(2026, 10, 12, 3)),
        throwsArgumentError,
      );
      expect(
        () => build(notBeforeUtc: DateTime(2026, 10, 12, 2, 30)),
        throwsArgumentError,
      );
      expect(
        () => build(createdAtUtc: DateTime(2026, 10, 12, 1)),
        throwsArgumentError,
      );
    });

    test('源区间必须非空，下界必须严格晚于源开始', () {
      expect(
        () => build(sourceEndUtc: start),
        throwsArgumentError,
        reason: 'sourceEndUtc == sourceStartUtc 不是一次有意义的延后',
      );
      expect(
        () => build(notBeforeUtc: start),
        throwsArgumentError,
        reason: '下界不晚于原开始就等于没有延后',
      );
      expect(
        () => build(notBeforeUtc: start.subtract(const Duration(minutes: 1))),
        throwsArgumentError,
      );
    });

    test('过期时间必须晚于创建时间，延后量必须为正', () {
      expect(() => build(expiresAtUtc: created), throwsArgumentError);
      expect(() => build(amount: 0), throwsArgumentError);
      expect(() => build(amount: -5), throwsArgumentError);
    });

    test('previewReady 必须带 previewId，applied 必须带 appliedPlanVersionId', () {
      expect(
        () => build(status: PlanAdjustmentStatus.previewReady),
        throwsArgumentError,
      );
      expect(
        () => build(
          status: PlanAdjustmentStatus.applied,
          appliedPlanVersionId: 'plan-8',
        ),
        returnsNormally,
      );
      expect(
        () => build(status: PlanAdjustmentStatus.applied),
        throwsArgumentError,
      );
    });

    test('空标题规范化为“未命名任务”，有标题时原样保留并去掉首尾空白', () {
      expect(build(title: '  ').targetTitleSnapshot, unnamedTaskTitle);
      expect(build(title: '  写周报  ').targetTitleSnapshot, '写周报');
    });
  });

  group('不可变快照', () {
    test('传入的兄弟块集合之后被修改，不影响对象（DFR-030）', () {
      final mutable = <String>['block-2', 'block-3'];
      final adjustment = build(siblingIds: mutable);

      mutable.add('block-4');

      expect(adjustment.targetSiblingBlockIds, {'block-2', 'block-3'});
      expect(
        () => adjustment.targetSiblingBlockIds.add('block-5'),
        throwsUnsupportedError,
      );
    });

    test('copyWith 不改动原对象', () {
      final original = build();
      final renamed = original.copyWith(status: PlanAdjustmentStatus.cancelled);

      expect(original.status, PlanAdjustmentStatus.active);
      expect(renamed.status, PlanAdjustmentStatus.cancelled);
      expect(renamed.adjustmentId, original.adjustmentId);
    });

    test('可选 id 去掉首尾空白；空字符串按 null 处理会报错而不是静默吞掉', () {
      final adjustment = build(
        status: PlanAdjustmentStatus.previewReady,
        previewId: '  preview-1  ',
      );
      expect(adjustment.previewId, 'preview-1');
      expect(
        () =>
            build(status: PlanAdjustmentStatus.previewReady, previewId: '   '),
        throwsArgumentError,
      );
    });
  });

  group('派生值', () {
    test('源时长与源区间来自同一对时刻', () {
      final adjustment = build();

      expect(adjustment.sourceRange.startUtc, start);
      expect(adjustment.sourceRange.endUtc, end);
      expect(adjustment.sourceDurationMinutes, 90);
    });

    test('令牌绑定 id、修订号与基线版本', () {
      final token = build(
        revision: 3,
        status: PlanAdjustmentStatus.previewReady,
        previewId: 'p',
      ).token;

      expect(token.adjustmentId, 'adj-1');
      expect(token.revision, 3);
      expect(token.basePlanVersionId, 'plan-7');
      expect(
        token,
        const PlanAdjustmentToken(
          adjustmentId: 'adj-1',
          revision: 3,
          basePlanVersionId: 'plan-7',
        ),
      );
    });

    test('过期判定是半开区间：到期那一刻即过期', () {
      final adjustment = build();
      final expiresAt = created.add(const Duration(hours: 12));

      expect(
        adjustment.isExpiredAt(
          expiresAt.subtract(const Duration(microseconds: 1)),
        ),
        isFalse,
      );
      expect(adjustment.isExpiredAt(expiresAt), isTrue);
    });

    test('toString 不包含标题与实例 id（日志脱敏）', () {
      final text = build(title: '机密标题').toString();

      expect(text, isNot(contains('机密标题')));
      expect(text, isNot(contains('adj-1')));
      expect(text, isNot(contains('block-1')));
    });
  });
}
