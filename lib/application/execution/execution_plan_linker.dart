import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/repositories/drift_execution_repository.dart';
import 'package:personal_planner/data/repositories/drift_recurring_execution_repository.dart';
import 'package:personal_planner/domain/execution/execution_fragment.dart' as f;
import 'package:personal_planner/domain/execution/execution_models.dart' as d;
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 把**已提交**的计划块与执行实例关联起来（规范 §5.2、§19.5）。
///
/// **只使用显式来源**：`continuedFromId` 由 `linkBlockProvenance` 在生成后建立；没有来源
/// 的块生成新实例。绝不按标题、最近钟点或任务 id 猜测归属——猜错一次就会把启动率分母
/// 挪到另一段安排上，而用户看不到任何提示。
///
/// 本方法必须在计划应用的同一个数据库事务里调用（见 `PlanTransactionApplier`）。
final class ExecutionPlanLinker {
  ExecutionPlanLinker({
    required this.repository,
    required this.zones,
    required this.idGenerator,
    required this.clock,
    this.recurringRepository,
    this.cycleIdForTask,
  });

  final DriftExecutionRepository repository;
  final TimeZoneDatabase zones;
  final IdGenerator idGenerator;
  final Clock clock;

  /// 1.12.0：可见块片段与周实例身份；未接线时仍可只建立 occurrence 链接。
  final DriftRecurringExecutionRepository? recurringRepository;
  final Future<String?> Function(String taskId)? cycleIdForTask;

  Future<void> linkAppliedPlan({
    required ConfirmedPlan plan,
    required ScheduleProposal proposal,
    required String timeZoneId,
    Map<String, String> fallbackOccurrenceByTask = const {},
  }) async {
    final runtime = await repository.ensureRuntimeState();
    final existing = await repository.blockLinksForVersion(plan.id);
    final proposedById = <String, _ProposedBlock>{
      for (final block in proposal.blocks)
        block.id: _ProposedBlock(
          id: block.id,
          continuedFromId: block.continuedFromId,
        ),
    };
    final prefix = '${plan.id}:';

    for (final block in plan.blocks) {
      if (existing.containsKey(block.id)) continue;
      // §15：首次启用只接入启用时刻之后尚未开始的安排；过去安排保持历史数据。
      if (block.endUtc.isBefore(runtime.featureEnabledAtUtc)) continue;

      final proposedId = block.id.startsWith(prefix)
          ? block.id.substring(prefix.length)
          : block.id;
      final sourceBlockId = proposedById[proposedId]?.continuedFromId;
      var occurrenceId = sourceBlockId == null
          ? null
          : await repository.occurrenceForAnyBlock(sourceBlockId);
      // 恢复预览是"把这一实例的剩余工作重新放下"：来源块可能已不在确认计划里，
      // 因此由调用方显式给出任务到实例的映射，而不是按标题或时刻猜测（规范 §19.5）。
      occurrenceId ??= fallbackOccurrenceByTask[block.taskId];

      final durationMicros = block.range.duration.inMicroseconds;
      if (occurrenceId != null) {
        final occurrence = await repository.findOccurrence(occurrenceId);
        if (occurrence != null) {
          if (occurrence.currentPlanVersionId != plan.id) {
            await repository.updateOccurrence(
              occurrence.copyWith(
                currentPlanVersionId: plan.id,
                revision: occurrence.revision + 1,
              ),
            );
          }
        } else {
          occurrenceId = null;
        }
      }

      if (occurrenceId == null) {
        final localStart = zones.toLocal(block.startUtc, timeZoneId);
        final localDate = DateTime(
          localStart.year,
          localStart.month,
          localStart.day,
        );
        final occurrence = d.ExecutionOccurrence(
          id: idGenerator.next(),
          taskId: block.taskId,
          originPlanVersionId: plan.id,
          originBlockId: block.id,
          baselineStartUtc: block.startUtc,
          baselineEndUtc: block.endUtc,
          baselineTimeZoneId: timeZoneId,
          baselineLocalDate: d.executionLocalDateKey(localDate),
          baselinePlannedDurationMicros: durationMicros,
          currentPlanVersionId: plan.id,
          allocatedMicros: durationMicros,
          remainingAllocationMicros: durationMicros,
          firstStartEvidenceId: null,
          withdrawalReason: null,
          withdrawnAtUtc: null,
          lifecycleState: d.ExecutionLifecycleState.planned,
          privacyState: d.ExecutionPrivacyState.linked,
          createdAtUtc: clock.nowUtc(),
          revision: 1,
        );
        await repository.insertOccurrence(occurrence);
        occurrenceId = occurrence.id;
      }

      String? fragmentId;
      final fragments = recurringRepository;
      if (fragments != null) {
        final existingFragment = await fragments.findFragmentForBlock(
          planVersionId: plan.id,
          blockId: block.id,
        );
        if (existingFragment == null) {
          final fragment = f.ExecutionFragment(
            fragmentId: idGenerator.next(),
            dataEpoch: runtime.dataEpoch,
            occurrenceId: occurrenceId,
            cycleId: cycleIdForTask == null
                ? null
                : await cycleIdForTask!(block.taskId),
            rootFragmentId: f.rootFragmentIdFor(occurrenceId),
            sourceFragmentId: null,
            planVersionId: plan.id,
            blockId: block.id,
            plannedStartUtc: block.startUtc,
            plannedEndUtc: block.endUtc,
            plannedMinutes: (durationMicros + 59999999) ~/ 60000000,
            allocatedMicros: durationMicros,
            completedMicros: 0,
            state: f.ExecutionFragmentState.planned,
            createdAtUtc: clock.nowUtc(),
            completedAtUtc: null,
            revision: 1,
          );
          await fragments.insertFragment(fragment);
          fragmentId = fragment.fragmentId;
        } else {
          fragmentId = existingFragment.fragmentId;
        }
      }

      await repository.insertBlockLink(
        dataEpoch: runtime.dataEpoch,
        planVersionId: plan.id,
        blockId: block.id,
        occurrenceId: occurrenceId,
        sourceBlockId: sourceBlockId,
        reservedMicros: durationMicros,
        fragmentId: fragmentId,
      );
    }

    await _withdrawDroppedOccurrences(plan: plan, dataEpoch: runtime.dataEpoch);
  }

  /// v11→v12 回填：给缺少 fragment 的已确认块补链（Task 2/6）。
  ///
  /// 只处理能唯一映射到块与 occurrence 的行；无法映射时跳过并返回计数，绝不链接到
  /// “任务的第一条 occurrence”。可重复调用，已有 fragment 的块不重复创建。
  Future<int> backfillFragments(String planVersionId) async {
    final fragments = recurringRepository;
    if (fragments == null) return 0;
    final links = await repository.blockLinksForVersion(planVersionId);
    final timings = {
      for (final timing in await repository.blockTimingsForVersion(
        planVersionId,
      ))
        timing.blockId: timing,
    };
    final runtime = await repository.ensureRuntimeState();
    var created = 0;
    for (final link in links.entries) {
      final existing = await fragments.findFragmentForBlock(
        planVersionId: planVersionId,
        blockId: link.key,
      );
      if (existing != null) continue;
      final timing = timings[link.key];
      if (timing == null) {
        await _recordBackfillAmbiguity(
          runtime.dataEpoch,
          planVersionId,
          link.key,
          link.value,
          'missingTiming',
        );
        continue;
      }
      final durationMicros = timing.endUtc
          .difference(timing.startUtc)
          .inMicroseconds;
      if (durationMicros <= 0) {
        await _recordBackfillAmbiguity(
          runtime.dataEpoch,
          planVersionId,
          link.key,
          link.value,
          'nonPositiveDuration',
        );
        continue;
      }
      final fragment = f.ExecutionFragment(
        fragmentId: idGenerator.next(),
        dataEpoch: runtime.dataEpoch,
        occurrenceId: link.value,
        cycleId: cycleIdForTask == null
            ? null
            : await cycleIdForTask!(timing.taskId),
        rootFragmentId: f.rootFragmentIdFor(link.value),
        sourceFragmentId: null,
        planVersionId: planVersionId,
        blockId: link.key,
        plannedStartUtc: timing.startUtc,
        plannedEndUtc: timing.endUtc,
        plannedMinutes: (durationMicros + 59999999) ~/ 60000000,
        allocatedMicros: durationMicros,
        completedMicros: 0,
        state: f.ExecutionFragmentState.planned,
        createdAtUtc: clock.nowUtc(),
        completedAtUtc: null,
        revision: 1,
      );
      await fragments.insertFragment(fragment);
      await repository.setBlockLinkFragment(
        planVersionId: planVersionId,
        blockId: link.key,
        fragmentId: fragment.fragmentId,
      );
      created++;
    }
    return created;
  }

  Future<void> _recordBackfillAmbiguity(
    String dataEpoch,
    String planVersionId,
    String blockId,
    String occurrenceId,
    String reason,
  ) async {
    final now = clock.nowUtc();
    await repository.insertOutbox(
      d.ExecutionOutboxEntry(
        effectId: idGenerator.next(),
        dataEpoch: dataEpoch,
        sourceTransaction: 'executionPlanLinkerBackfill',
        targetRevision: 1,
        effectType: 'recurringBackfillAmbiguous',
        payload: {
          'planVersionId': planVersionId,
          'blockId': blockId,
          'occurrenceId': occurrenceId,
          'reason': reason,
        },
        attempts: 0,
        createdAtUtc: now,
        nextAttemptAtUtc: now,
        processedAtUtc: null,
      ),
    );
  }

  /// 到点前被改期/取消的实例记为提前撤回；到点后或已有实际启动的实例保留承诺（规范 §5.2）。
  Future<void> _withdrawDroppedOccurrences({
    required ConfirmedPlan plan,
    required String dataEpoch,
  }) async {
    final previous = await repository.previousPlanVersionId();
    if (previous == null) return;
    final newLinks = await repository.blockLinksForVersion(plan.id);
    final previousLinks = await repository.blockLinksForVersion(previous);
    final kept = newLinks.values.toSet();
    final now = clock.nowUtc();
    for (final occurrenceId in previousLinks.values.toSet()) {
      if (kept.contains(occurrenceId)) continue;
      final occurrence = await repository.findOccurrence(occurrenceId);
      if (occurrence == null ||
          occurrence.isTerminal ||
          occurrence.firstStartEvidenceId != null) {
        continue;
      }
      // 到点之后消失的安排不是"提前调整"：旧承诺必须保留在启动率分母里。
      if (!now.isBefore(occurrence.baselineStartUtc)) continue;
      final reduced = occurrence.remainingAllocationMicros;
      await repository.updateOccurrence(
        occurrence.copyWith(
          lifecycleState: d.ExecutionLifecycleState.withdrawn,
          withdrawalReason: 'rescheduledBeforeStart',
          withdrawnAtUtc: now,
          remainingAllocationMicros: 0,
          revision: occurrence.revision + 1,
        ),
      );
      final sequence = await repository.allocateSequence();
      await repository.insertEvent(
        d.ExecutionEvent(
          eventId: idGenerator.next(),
          dataEpoch: dataEpoch,
          operationId: 'plan-link:${plan.id}:${occurrence.id}',
          subEventIndex: 0,
          occurrenceId: occurrence.id,
          eventType: d.ExecutionEventType.withdrawn,
          occurredAtUtc: now,
          recordedAtUtc: now,
          source: d.ExecutionActivitySource.realtime,
          payload: {
            'reason': 'rescheduledBeforeStart',
            'reducedMicros': reduced,
          },
          correctedEventId: null,
          sequence: sequence,
          revision: 1,
        ),
      );
    }
  }

  /// 新实例的基线来源：用于恢复预览判断"来源块是否仍属于同一实例"。
  Future<String?> occurrenceForBlock(String blockId) =>
      repository.occurrenceForAnyBlock(blockId);
}

final class _ProposedBlock {
  const _ProposedBlock({required this.id, required this.continuedFromId});

  final String id;
  final String? continuedFromId;
}
