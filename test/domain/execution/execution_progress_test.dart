import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/execution/execution_models.dart';
import 'package:personal_planner/domain/execution/execution_progress.dart';

ExecutionProgressCredit credit(int sequence, int micros) =>
    ExecutionProgressCredit(
      firstAcceptedSequence: sequence,
      durationMicros: micros,
      targetKind: ExecutionTargetKind.task,
      targetId: 'task-1',
    );

void main() {
  group('精确剩余与调度分钟（规范 §10.2、§22.2）', () {
    test('初始剩余45分钟，本轮新增5分钟 -> 剩余40分钟', () {
      const remaining = 45 * 60 * 1000000;
      const added = 5 * 60 * 1000000;
      expect(
        executionRemainingMicros(
          anchorRemainingMicros: remaining,
          anchorSequence: 0,
          credits: [credit(1, added)],
        ),
        remaining - added,
      );
    });

    test('30秒两次累计1分钟，不因单条取整丢失', () {
      const half = 30 * 1000000;
      final projection = executionProjectProgress(
        anchorRemainingMicros: 45 * 60 * 1000000,
        anchorSequence: 0,
        credits: [credit(1, half), credit(2, half)],
      );
      expect(projection.remainingMicros, 44 * 60 * 1000000);
      expect(projection.schedulingMinutes, 44);
    });

    test('剩余1分钟再减30秒：精确30秒，调度向上取整为1分钟', () {
      final projection = executionProjectProgress(
        anchorRemainingMicros: 60 * 1000000,
        anchorSequence: 0,
        credits: [credit(1, 30 * 1000000)],
      );
      expect(projection.remainingMicros, 30 * 1000000);
      expect(projection.schedulingMinutes, 1);
    });

    test('新人工检查点剩余30分钟，随后新增5分钟 -> 剩余25分钟', () {
      const anchorMicros = 30 * 60 * 1000000;
      final projection = executionProjectProgress(
        anchorRemainingMicros: anchorMicros,
        anchorSequence: 10,
        credits: [credit(11, 5 * 60 * 1000000)],
      );
      expect(projection.remainingMicros, 25 * 60 * 1000000);
      expect(projection.schedulingMinutes, 25);
    });

    test('检查点之前的记录更正不影响较新的人工剩余', () {
      // 检查点在序号 10；旧记录序号 3 即使被更正为 0 分钟，也不参与当前剩余。
      final projection = executionProjectProgress(
        anchorRemainingMicros: 25 * 60 * 1000000,
        anchorSequence: 10,
        credits: [credit(3, 5 * 60 * 1000000)],
      );
      expect(projection.remainingMicros, 25 * 60 * 1000000);
    });

    test('检查点之后的5分钟改成3分钟 -> 剩余27分钟', () {
      final projection = executionProjectProgress(
        anchorRemainingMicros: 30 * 60 * 1000000,
        anchorSequence: 10,
        credits: [credit(11, 3 * 60 * 1000000)],
      );
      expect(projection.schedulingMinutes, 27);
    });
  });

  group('实例份额与任务剩余（规范 §9.3、§22.3）', () {
    test('90分钟任务两段各45分钟：本次做5分钟后只恢复本次40分钟', () {
      const occurrence = 45 * 60 * 1000000;
      const taskRemaining = 85 * 60 * 1000000;
      expect(
        executionRecoveryTargetMicros(
          occurrenceRemainingMicros: occurrence - 5 * 60 * 1000000,
          taskRemainingMicros: taskRemaining,
        ),
        40 * 60 * 1000000,
      );
    });

    test('目标份额不能超过任务总剩余', () {
      expect(
        executionRecoveryTargetMicros(
          occurrenceRemainingMicros: 60 * 60 * 1000000,
          taskRemainingMicros: 20 * 60 * 1000000,
        ),
        20 * 60 * 1000000,
      );
    });

    test('份额守恒：已入账 + 未完成 + 明确减少 = 原始分配', () {
      expect(
        executionShareIsConserved(
          allocatedMicros: 45 * 60 * 1000000,
          creditedMicros: 5 * 60 * 1000000,
          remainingAllocationMicros: 40 * 60 * 1000000,
          explicitlyReducedMicros: 0,
        ),
        isTrue,
      );
      expect(
        executionShareIsConserved(
          allocatedMicros: 45 * 60 * 1000000,
          creditedMicros: 5 * 60 * 1000000,
          remainingAllocationMicros: 30 * 60 * 1000000,
          explicitlyReducedMicros: 0,
        ),
        isFalse,
      );
    });

    test('超额投入不产生负剩余，只报告超出量', () {
      expect(
        executionOverdrawnMicros(
          allocatedMicros: 5 * 60 * 1000000,
          creditedMicros: 7 * 60 * 1000000,
        ),
        2 * 60 * 1000000,
      );
      expect(
        executionOverdrawnMicros(
          allocatedMicros: 7 * 60 * 1000000,
          creditedMicros: 7 * 60 * 1000000,
        ),
        0,
      );
    });

    test('交叠微秒最多入账一次', () {
      final start = DateTime.utc(2026, 10, 19, 5);
      final segment = ExecutionActivitySegment(
        segmentId: 'segment-1',
        dataEpoch: 'epoch',
        sessionId: 'session-1',
        sequence: 1,
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 10)),
        source: ExecutionActivitySource.realtime,
        invalidatedReason: null,
        createdAtUtc: start,
      );
      final allocation = ExecutionCreditAllocation(
        dataEpoch: 'epoch',
        segmentId: 'segment-1',
        targetKind: ExecutionTargetKind.task,
        targetId: 'task-1',
        allocationIndex: 0,
        recordRevision: 1,
        amountMicros: 10 * 60 * 1000000,
        firstAcceptedSequence: 1,
        createdAtUtc: start,
      );
      expect(
        executionAllocationOverflowMicros(
          segments: [segment],
          allocations: [allocation],
        ),
        0,
      );
      expect(
        executionAllocationOverflowMicros(
          segments: [segment],
          allocations: [
            allocation,
            ExecutionCreditAllocation(
              dataEpoch: 'epoch',
              segmentId: 'segment-1',
              targetKind: ExecutionTargetKind.task,
              targetId: 'task-1',
              allocationIndex: 1,
              recordRevision: 1,
              amountMicros: 1000000,
              firstAcceptedSequence: 2,
              createdAtUtc: start,
            ),
          ],
        ),
        1000000,
      );
    });

    test('距保护时间只剩3分钟：短会话上限是真实可用时间', () {
      final now = DateTime.utc(2026, 10, 19, 5);
      expect(
        executionRealShortSessionMicros(
          nowUtc: now,
          hardBoundaryUtc: now.add(const Duration(minutes: 3)),
          requestedMicros: 5 * 60 * 1000000,
        ),
        3 * 60 * 1000000,
      );
    });
  });

  group('跨周分配（规范 §10.3、EXE-24/47）', () {
    test('两周各有30秒活动：每周各保留30秒，不跨周凑成1分钟', () {
      // 固定 UTC+8：本地周一 00:00 = UTC 周日 16:00。
      final weekStartUtc = DateTime.utc(2026, 10, 18, 16);
      DateTime localWeekStartOf(DateTime instantUtc) {
        final local = instantUtc.add(const Duration(hours: 8));
        return DateTime(
          local.year,
          local.month,
          local.day - (local.weekday - DateTime.monday),
        );
      }

      DateTime localWeekStartUtc(DateTime localWeekStart) => DateTime.utc(
        localWeekStart.year,
        localWeekStart.month,
        localWeekStart.day,
      ).subtract(const Duration(hours: 8));

      final slices = splitActivityAcrossWeeks(
        startUtc: weekStartUtc.subtract(const Duration(seconds: 30)),
        endUtc: weekStartUtc.add(const Duration(seconds: 30)),
        localWeekStartOf: localWeekStartOf,
        localWeekStartUtc: localWeekStartUtc,
      );
      expect(
        slices,
        hasLength(2),
        reason: slices
            .map((slice) => '${slice.localWeekStart} ${slice.micros}')
            .join(' | '),
      );
      expect(slices.map((slice) => slice.micros), [30000000, 30000000]);
      expect(
        slices.fold<int>(0, (sum, slice) => sum + slice.micros),
        60 * 1000000,
      );
    });

    test('同一周内的活动只有一个切片', () {
      final start = DateTime.utc(2026, 10, 19, 1);
      DateTime localWeekStartOf(DateTime instantUtc) {
        final local = instantUtc.add(const Duration(hours: 8));
        return DateTime(
          local.year,
          local.month,
          local.day - (local.weekday - DateTime.monday),
        );
      }

      DateTime localWeekStartUtc(DateTime localWeekStart) => DateTime.utc(
        localWeekStart.year,
        localWeekStart.month,
        localWeekStart.day,
      ).subtract(const Duration(hours: 8));

      final slices = splitActivityAcrossWeeks(
        startUtc: start,
        endUtc: start.add(const Duration(minutes: 5)),
        localWeekStartOf: localWeekStartOf,
        localWeekStartUtc: localWeekStartUtc,
      );
      expect(slices, hasLength(1));
      expect(slices.single.micros, 5 * 60 * 1000000);
    });
  });

  group('备注约束（规范 §19.1）', () {
    test('500 个码点允许，501 个拒绝', () {
      expect(executionNoteError('a' * 500), isNull);
      expect(executionNoteError('a' * 501), 'noteTooLong');
    });

    test('换行与制表符允许，其他控制字符拒绝', () {
      expect(executionNoteError('第一行\n第二行\t正文'), isNull);
      expect(executionNoteError('坏\u0007字符'), 'noteControlCharacter');
    });
  });
}
