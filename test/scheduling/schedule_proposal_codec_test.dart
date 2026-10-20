// 1.11.0（计划 Task 3 Step 4）：完整提案 codec。
//
// 三条要求：round-trip 不丢字段、同一语义得到同一个哈希、未知格式版本拒绝解码。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';
import 'package:personal_planner/scheduling/schedule_proposal_codec.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';

void main() {
  const codec = ScheduleProposalCodec();
  final window = TimeRange(
    startUtc: DateTime.utc(2026, 10, 19),
    endUtc: DateTime.utc(2026, 10, 26),
  );

  ScheduleProposal proposal({DateTime? blockStart}) => ScheduleProposal(
    proposalId: 'proposal-1',
    inputHash: 'hash-1',
    algorithmVersion: '20',
    planningWindow: window,
    blocks: [
      PlannedBlock(
        id: 'block-1',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: blockStart ?? DateTime.utc(2026, 10, 19, 2),
          endUtc: (blockStart ?? DateTime.utc(2026, 10, 19, 2)).add(
            const Duration(minutes: 60),
          ),
        ),
        locked: true,
        explanationCode: 'energyMatch',
        continuedFromId: 'block-old',
      ),
    ],
    unscheduled: [
      UnscheduledTask(
        taskId: 'task-2',
        shortageMinutes: 45,
        primaryReason: const UnscheduledReason(
          code: UnscheduledReasonCode.deadlineWindowTooShort,
          placementRemainingMinutes: 45,
          constraintRequiredMinutes: 60,
          constraintAvailableMinutes: 30,
          constraintLabel: '连续空档',
        ),
        reasons: const [
          UnscheduledReason(
            code: UnscheduledReasonCode.deadlineWindowTooShort,
            placementRemainingMinutes: 45,
          ),
        ],
      ),
    ],
    conflicts: [
      PlanningConflict(
        code: ConflictCode.insufficientCapacity,
        taskId: 'task-2',
        shortageMinutes: 45,
        relatedEntityIds: const ['block-9'],
        details: const {'requiredMinutes': 60, 'availableMinutes': 30},
      ),
    ],
    explanations: [
      PlanExplanation(
        code: 'energyMatch',
        parameters: const {'minutes': 60, 'usedSoftWindow': false},
      ),
    ],
    metrics: const ProposalMetrics(
      isFullyFeasible: false,
      scheduledMinutes: 60,
      unscheduledMinutes: 45,
    ),
    adjustmentRequirement: AdjustmentRequirement(
      targetBlockId: 'block-1',
      notBeforeUtc: DateTime.utc(2026, 10, 19, 3),
      requiredMinutes: 60,
      originalStartUtc: DateTime.utc(2026, 10, 19, 2),
    ),
    outcome: SearchOutcomeKind.hardInfeasible,
  );

  test('round-trip 逐字段保留，再次编码得到同一字节', () {
    final original = proposal();
    final encoded = codec.encodeCanonical(original);
    final decoded = codec.decode(encoded);

    expect(decoded.proposalId, original.proposalId);
    expect(decoded.inputHash, original.inputHash);
    expect(decoded.algorithmVersion, '20');
    expect(decoded.planningWindow, original.planningWindow);
    expect(decoded.outcome, SearchOutcomeKind.hardInfeasible);
    expect(decoded.blocks.single.id, 'block-1');
    expect(decoded.blocks.single.locked, isTrue);
    expect(decoded.blocks.single.explanationCode, 'energyMatch');
    expect(decoded.blocks.single.continuedFromId, 'block-old');
    expect(decoded.unscheduled.single.shortageMinutes, 45);
    expect(
      decoded.unscheduled.single.primaryReason.code,
      UnscheduledReasonCode.deadlineWindowTooShort,
    );
    expect(
      decoded.unscheduled.single.primaryReason.constraintRequiredMinutes,
      60,
    );
    expect(decoded.conflicts.single.code, ConflictCode.insufficientCapacity);
    expect(decoded.conflicts.single.relatedEntityIds, ['block-9']);
    expect(decoded.conflicts.single.details['requiredMinutes'], 60);
    expect(decoded.explanations.single.parameters['minutes'], 60);
    expect(decoded.metrics.scheduledMinutes, 60);
    expect(decoded.metrics.isFullyFeasible, isFalse);
    expect(decoded.adjustmentRequirement!.targetBlockId, 'block-1');
    expect(
      decoded.adjustmentRequirement!.notBeforeUtc,
      DateTime.utc(2026, 10, 19, 3),
    );
    expect(codec.encodeCanonical(decoded), encoded);
  });

  test('同一提案的哈希稳定；块位置变化则哈希变化', () {
    final first = codec.sha256OfCanonical(proposal());
    final second = codec.sha256OfCanonical(proposal());

    expect(first, second);
    expect(
      codec.sha256OfCanonical(
        proposal(blockStart: DateTime.utc(2026, 10, 19, 2, 10)),
      ),
      isNot(first),
    );
  });

  test('canonical JSON 的 key 有序且列表按 id 排序，不受构造顺序影响', () {
    final encoded = codec.encodeCanonical(proposal());
    final decoded = jsonDecode(encoded) as Map<String, Object?>;
    final proposalJson = decoded['proposal'] as Map<String, Object?>;

    final keys = (proposalJson.keys.toList());
    expect(keys, [...keys]..sort());
    final block = (proposalJson['blocks'] as List).single as Map<String, Object?>;
    final blockKeys = block.keys.toList();
    expect(blockKeys, [...blockKeys]..sort());
  });

  test('未知 formatVersion 拒绝解码，不按残缺字段重建', () {
    final encoded = codec.encodeCanonical(proposal());
    final tampered = encoded.replaceFirst('"formatVersion":1', '"formatVersion":2');

    expect(
      () => codec.decode(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('非对象根与缺失 proposal 都拒绝', () {
    expect(() => codec.decode('[]'), throwsA(isA<FormatException>()));
    expect(
      () => codec.decode('{"formatVersion":1}'),
      throwsA(isA<FormatException>()),
    );
  });
}
