import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final validator = PlanValidator(TimeZoneDatabase());
  final day = DateTime.utc(2026, 10, 2);
  TimeRange at(int startHour, int endHour) => TimeRange(
    startUtc: day.add(Duration(hours: startHour)),
    endUtc: day.add(Duration(hours: endHour)),
  );

  ScheduleProblem problem({
    List<SchedulableTask>? tasks,
    List<BusyInterval> fixed = const [],
    List<BusyInterval> protected = const [],
    List<PlannedBlock> locked = const [],
    int? dailyLimit,
  }) => ScheduleProblem(
    planningWindow: TimeRange(
      startUtc: day,
      endUtc: day.add(const Duration(days: 1)),
    ),
    timeZoneId: 'UTC',
    tasks:
        tasks ??
        [
          const SchedulableTask(
            id: 'task-1',
            requiredMinutes: 60,
            splitMode: TaskSplitMode.splittable,
            minChunkMinutes: 25,
            maxChunkMinutes: 90,
          ),
        ],
    fixedIntervals: fixed,
    protectedIntervals: protected,
    lockedBlocks: locked,
    rules: DefaultSettings.v1().copyWith(
      dailyMovableTaskLimitMinutes: dailyLimit ?? 360,
    ),
    preferences: const PreferenceProfile(),
    inputHash: 'hash-1',
  );

  test('报告固定日程和保护时间重叠', () {
    final blocks = [
      PlannedBlock(id: 'block-1', taskId: 'task-1', range: at(9, 10)),
    ];

    expect(
      validator
          .validate(
            problem(
              fixed: [BusyInterval(id: 'class', range: at(9, 11))],
              protected: [BusyInterval(id: 'sleep', range: at(8, 10))],
            ),
            blocks,
          )
          .map((conflict) => conflict.code),
      containsAll([
        ConflictCode.fixedEventOverlap,
        ConflictCode.protectedTimeOverlap,
      ]),
    );
  });

  test('报告锁定块被移动', () {
    final locked = PlannedBlock(
      id: 'locked-1',
      taskId: 'task-1',
      range: at(9, 10),
      locked: true,
    );
    final moved = PlannedBlock(
      id: 'locked-1',
      taskId: 'task-1',
      range: at(10, 11),
      locked: true,
    );

    final conflicts = validator.validate(problem(locked: [locked]), [moved]);

    expect(
      conflicts.map((item) => item.code),
      contains(ConflictCode.lockedBlockMoved),
    );
  });

  test('报告连续任务被拆分', () {
    final continuous = const SchedulableTask(
      id: 'task-1',
      requiredMinutes: 60,
      splitMode: TaskSplitMode.continuous,
      minChunkMinutes: 60,
      maxChunkMinutes: 60,
    );

    final conflicts = validator.validate(problem(tasks: [continuous]), [
      PlannedBlock(
        id: 'a',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 9)),
          endUtc: day.add(const Duration(hours: 9, minutes: 30)),
        ),
      ),
      PlannedBlock(
        id: 'b',
        taskId: 'task-1',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 10)),
          endUtc: day.add(const Duration(hours: 10, minutes: 30)),
        ),
      ),
    ]);

    expect(
      conflicts.map((item) => item.code),
      contains(ConflictCode.continuousBlockUnavailable),
    );
  });

  test('报告每日上限和任务片段总量超出', () {
    final blocks = [PlannedBlock(id: 'a', taskId: 'task-1', range: at(8, 10))];

    final conflicts = validator.validate(problem(dailyLimit: 60), blocks);

    expect(
      conflicts.map((item) => item.code),
      containsAll([
        ConflictCode.dailyLimitExceeded,
        ConflictCode.scheduledDurationExceeded,
      ]),
    );
  });

  test('已锁定块不计入每日可移动任务上限', () {
    const task = SchedulableTask(
      id: 'task-1',
      requiredMinutes: 480,
      splitMode: TaskSplitMode.splittable,
      minChunkMinutes: 25,
      maxChunkMinutes: 480,
    );
    final locked = PlannedBlock(
      id: 'locked-1',
      taskId: 'task-1',
      range: at(0, 6),
      locked: true,
    );

    // 锁定 360 分钟 + 新排 120 分钟：可移动部分未超过 180 分钟上限。
    // 锁定块必须被排除，否则同一段时长被重复计算并产生虚假冲突。
    expect(
      validator
          .validate(problem(tasks: [task], locked: [locked], dailyLimit: 180), [
            locked,
            PlannedBlock(id: 'movable-1', taskId: 'task-1', range: at(8, 10)),
          ])
          .map((conflict) => conflict.code),
      isNot(contains(ConflictCode.dailyLimitExceeded)),
    );

    // 可移动部分自身超过上限时仍必须报告。
    expect(
      validator
          .validate(problem(tasks: [task], locked: [locked], dailyLimit: 180), [
            locked,
            PlannedBlock(id: 'movable-2', taskId: 'task-1', range: at(8, 12)),
          ])
          .map((conflict) => conflict.code),
      contains(ConflictCode.dailyLimitExceeded),
    );
  });

  test('排程问题复制输入列表而不是保留可变引用', () {
    final tasks = <SchedulableTask>[];
    final value = problem(tasks: tasks);

    tasks.add(
      const SchedulableTask(
        id: 'late',
        requiredMinutes: 30,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 25,
        maxChunkMinutes: 90,
      ),
    );

    expect(value.tasks, isEmpty);
    expect(() => value.tasks.add(tasks.single), throwsUnsupportedError);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 计划 §2.2：**同任务片段集合**的唯一短尾判定。
  //
  // `isValidPlannedChunk` 只看一个块，因此它无法回答"这个低于最小片段的块是不是
  // 全任务唯一的最终短尾"。下面把 §2.2 的示例表**逐行**钉住（6 行）。
  // ───────────────────────────────────────────────────────────────────────────
  group('§2.2 示例表：同任务片段集合的唯一短尾判定', () {
    /// 把一串分钟数铺成连续块（每块首尾相接），并给出确定的 id 序号。
    List<PlannedBlock> chunks(
      List<int> minutes, {
      String taskId = 'set-task',
      int firstHour = 8,
    }) {
      final blocks = <PlannedBlock>[];
      var cursor = day.add(Duration(hours: firstHour));
      for (var index = 0; index < minutes.length; index++) {
        final end = cursor.add(Duration(minutes: minutes[index]));
        blocks.add(
          PlannedBlock(
            id: '$taskId-$index',
            taskId: taskId,
            range: TimeRange(startUtc: cursor, endUtc: end),
          ),
        );
        cursor = end;
      }
      return blocks;
    }

    SchedulableTask splittable({required int requiredMinutes}) =>
        SchedulableTask(
          id: 'set-task',
          requiredMinutes: requiredMinutes,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        );

    /// 一条断言把"violation"与"归因到哪一块"一起钉住：只断言 violation 会漏掉
    /// "报对了原因、指错了块"这种半对。
    void expectViolation(
      ChunkSetValidation result,
      ChunkSetViolation expected, {
      String? blockId,
      required String reason,
    }) {
      expect(result.violation, expected, reason: reason);
      expect(result.isValid, expected == ChunkSetViolation.none);
      if (blockId != null) {
        expect(result.blockId, blockId, reason: '$reason（归因块）');
      }
    }

    test('100 / 30 / 5，块 30,30,30,10 ⇒ 合法', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 100),
        blocks: chunks([30, 30, 30, 10]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.none,
        reason: '30+30+30=90，剩 10 < 30 ⇒ 10 分钟是唯一合法短尾',
      );
    });

    test('103 / 30 / 5，块 30,30,30,10 ⇒ 合法（真实缺口 3 分钟不伪造块）', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 103),
        blocks: chunks([30, 30, 30, 10]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.none,
        reason: 'regularTotal=90，remaining=13 < 30 ⇒ 宽免量 10；缺 3 分钟如实保留',
      );
    });

    test('100 / 30 / 5，块 30,30,20 ⇒ belowMinimumBeforeTail', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 100),
        blocks: chunks([30, 30, 20]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.belowMinimumBeforeTail,
        blockId: 'set-task-2',
        reason: 'remaining = 100 − 60 = 40 ≥ 30：任务还排得下一个常规片段，20 分钟用早了',
      );
    });

    test('12 / 30 / 5，块 10 ⇒ 合法（remaining = 12 < 30，tailBudget = 10）', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 12),
        blocks: chunks([10]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.none,
        reason: '整件事只有 12 分钟，短于最小片段 ⇒ 它自己就是最后一段',
      );
    });

    test('12 / 30 / 5，块 5 ⇒ shortTailMismatch（tailBudget = 10）', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 12),
        blocks: chunks([5]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.shortTailMismatch,
        blockId: 'set-task-0',
        reason: '宽免量是"粒度下的剩余量"=10，半截的 5 分钟不是它',
      );
    });

    test('100 / 30 / 5，块 30,30,5,5 ⇒ multipleShortTails（指向第二个短块）', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 100),
        blocks: chunks([30, 30, 5, 5]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.multipleShortTails,
        blockId: 'set-task-3',
        reason: '宽免只针对唯一最终短尾；第二个短块是违规者',
      );
    });

    test('总量超过 requiredMinutes ⇒ totalExceedsRequired', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 60),
        blocks: chunks([30, 30, 30]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.totalExceedsRequired,
        reason: '90 > 60：排多了，与片段形状无关',
      );
    });

    test('时长不在粒度网格上 ⇒ offGranularity', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 100),
        blocks: chunks([33, 30, 30]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.offGranularity,
        blockId: 'set-task-0',
        reason: '33 不是 5 的倍数',
      );
    });

    test('时长不为正 ⇒ nonPositiveDuration（守卫分支，公开构造路径不可达）', () {
      // `TimeRange` 本身拒绝零长度（`endUtc must be after startUtc`），因此
      // `nonPositiveDuration` **无法**通过任何公开构造路径触发。它是一条守卫：
      // 枚举与判定保留在契约里（外部注入的块、以及未来的模型变化都可能带来零长度），
      // 但按纪律"不为不可达分支编造夹具"，这里只记录事实，不伪造一个块去骗过它。
      expect(
        ChunkSetViolation.values,
        contains(ChunkSetViolation.nonPositiveDuration),
        reason: '枚举必须保留这一条：它是计划 §2.2 明列的判定之一',
      );
    });

    test('可拆分片段超过 maxChunkMinutes ⇒ aboveMaximum', () {
      final result = validatePlannedChunkSet(
        task: splittable(requiredMinutes: 200),
        blocks: chunks([95, 30]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.aboveMaximum,
        blockId: 'set-task-0',
        reason: '95 > max 90',
      );
    });

    test('连续任务被拆成两块 ⇒ continuousTaskSplit', () {
      const continuous = SchedulableTask(
        id: 'set-task',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.continuous,
        minChunkMinutes: 60,
        maxChunkMinutes: 60,
      );
      final result = validatePlannedChunkSet(
        task: continuous,
        blocks: chunks([30, 30]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.continuousTaskSplit,
        reason: '连续任务的语义是"一次做完"',
      );
      // **不检查 min/max**（既有冻结决定）：两个 30 分钟块本身落在网格上、也没超总量，
      // 因此这里报的必须是"被拆分"，而不是"片段太短"。
      expect(result.violation, isNot(ChunkSetViolation.belowMinimumBeforeTail));
    });

    test('连续任务一个 15 分钟块 ⇒ 合法（不受 min30 影响）', () {
      const continuous = SchedulableTask(
        id: 'set-task',
        requiredMinutes: 15,
        splitMode: TaskSplitMode.continuous,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      );
      final result = validatePlannedChunkSet(
        task: continuous,
        blocks: chunks([15]),
        granularityMinutes: 5,
      );
      expectViolation(
        result,
        ChunkSetViolation.none,
        reason: 'R5：连续任务不套用可拆分任务的片段上下限',
      );
    });
  });

  group('PlanValidator.validate 把集合 violation 翻成结构化 code', () {
    /// §2.2 表里每一行都必须经过**真正对外的那条路径**（`validate`）验证一次：
    /// 纯函数对了、转换错了，用户看到的仍然是错的。
    ScheduleProblem setProblem(SchedulableTask task) => problem(tasks: [task]);

    test('belowMinimumBeforeTail ⇒ invalidInput + chunkBelowMinimum，带完整数字', () {
      final task = const SchedulableTask(
        id: 'set-task',
        requiredMinutes: 100,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      );
      // 三个块：30 + 30 + 20。`regularTotal = 60`，`remaining = 100 − 60 = 40 ≥ 30`，
      // 因此那个 20 分钟块"过早"用了短尾宽免。
      final start = day.add(const Duration(hours: 8));
      TimeRange span(int fromMinute, int toMinute) => TimeRange(
        startUtc: start.add(Duration(minutes: fromMinute)),
        endUtc: start.add(Duration(minutes: toMinute)),
      );
      final conflicts = validator.validate(setProblem(task), [
        PlannedBlock(id: 'b0', taskId: 'set-task', range: span(0, 30)),
        PlannedBlock(id: 'b1', taskId: 'set-task', range: span(30, 60)),
        PlannedBlock(id: 'b2', taskId: 'set-task', range: span(60, 80)),
      ]);

      final invalid = conflicts
          .where((conflict) => conflict.code == ConflictCode.invalidInput)
          .toList();
      expect(invalid, hasLength(1), reason: '同一件事不得报两遍');
      expect(
        invalid.single.invalidInputReason,
        InvalidInputReason.chunkBelowMinimum,
      );
      expect(invalid.single.relatedEntityIds, ['b2']);
      expect(invalid.single.details['durationMinutes'], 20);
      expect(invalid.single.details['minChunkMinutes'], 30);
      expect(invalid.single.details['maxChunkMinutes'], 90);
      expect(invalid.single.details['requiredMinutes'], 100);
      expect(
        invalid.single.details['reason'],
        InvalidInputReason.chunkBelowMinimum.name,
        reason: '`details[reason]` 是既有调用方读的键，`_invalid` 必须继续补上它',
      );
    });

    test('offGranularity ⇒ invalidInput + offGranularity，details 带粒度', () {
      final task = const SchedulableTask(
        id: 'set-task',
        requiredMinutes: 100,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      );
      // 一个 33 分钟的块：不是 5 的倍数。
      final conflicts = validator.validate(setProblem(task), [
        PlannedBlock(
          id: 'b0',
          taskId: 'set-task',
          range: TimeRange(
            startUtc: day.add(const Duration(hours: 8)),
            endUtc: day.add(const Duration(hours: 8, minutes: 33)),
          ),
        ),
      ]);

      final invalid = conflicts
          .where((conflict) => conflict.code == ConflictCode.invalidInput)
          .toList();
      expect(invalid, hasLength(1));
      expect(
        invalid.single.invalidInputReason,
        InvalidInputReason.offGranularity,
      );
      expect(invalid.single.details['durationMinutes'], 33);
      expect(invalid.single.details['granularityMinutes'], 5);
    });

    test('总量超 required ⇒ scheduledDurationExceeded（带两个数字）', () {
      final task = const SchedulableTask(
        id: 'set-task',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      );
      // 两个 60 分钟块：总量 120 > 60。两块各自的形状都合法（60 在 [30, 90] 内），
      // 因此这条冲突只可能来自"总量"这一个事实。
      final conflicts = validator.validate(setProblem(task), [
        PlannedBlock(id: 'b0', taskId: 'set-task', range: at(8, 9)),
        PlannedBlock(id: 'b1', taskId: 'set-task', range: at(9, 10)),
      ]);

      final exceeded = conflicts
          .where(
            (conflict) =>
                conflict.code == ConflictCode.scheduledDurationExceeded,
          )
          .toList();
      expect(exceeded, hasLength(1));
      expect(exceeded.single.taskId, 'set-task');
      expect(exceeded.single.details['scheduledMinutes'], 120);
      expect(exceeded.single.details['requiredMinutes'], 60);
    });

    test('连续任务两块 ⇒ continuousBlockUnavailable，relatedEntityIds 按起点排序', () {
      const task = SchedulableTask(
        id: 'set-task',
        requiredMinutes: 60,
        splitMode: TaskSplitMode.continuous,
        minChunkMinutes: 60,
        maxChunkMinutes: 60,
      );
      // **刻意按倒序传入**：输出必须与输入顺序无关（归因列表按 startUtc 排序）。
      // 两个 30 分钟块合计 60 = requiredMinutes，因此不会被"总量超出"抢答；
      // 而连续任务不检查 min/max，所以这里唯一的违规就是"被拆分"。
      final half = day.add(const Duration(hours: 8));
      final conflicts = validator.validate(setProblem(task), [
        PlannedBlock(
          id: 'later',
          taskId: 'set-task',
          range: TimeRange(
            startUtc: half.add(const Duration(minutes: 30)),
            endUtc: half.add(const Duration(minutes: 60)),
          ),
        ),
        PlannedBlock(
          id: 'earlier',
          taskId: 'set-task',
          range: TimeRange(
            startUtc: half,
            endUtc: half.add(const Duration(minutes: 30)),
          ),
        ),
      ]);

      final split = conflicts
          .where(
            (conflict) =>
                conflict.code == ConflictCode.continuousBlockUnavailable,
          )
          .toList();
      expect(split, hasLength(1));
      expect(split.single.relatedEntityIds, ['earlier', 'later']);
      expect(
        conflicts.where((c) => c.code == ConflictCode.invalidInput),
        isEmpty,
        reason: '连续任务不检查 min/max：30 分钟块不因 min60 被报"片段太短"',
      );
    });

    test('片段集合校验对**单块**至少与 isValidPlannedChunk 一样严', () {
      // 计划要求："加一条测试钉住集合校验对单块至少与它一样严"。
      //
      // **方向的正确读法**：`isValidPlannedChunk` 是"单候选的快速前置检查"，它只看得见
      // 一个块；`validatePlannedChunkSet` 看得见整组块，因此它**可以更严**，但**不可以更宽**
      // ——否则引擎能生成、确认却必然失败的 R4 会以另一种形态回来。
      // 所以这里枚举单块形状，禁止的是"集合校验接受而快速检查拒绝"这一个方向。
      //
      // 反方向（快速检查接受、集合校验拒绝）**是计划明确要求的**，见下面单独那条
      // `12 / 30 / 粒度 5` 的用例——§2.2 的示例表把 5 分钟块判为非法，而
      // `isValidPlannedChunk` 只看"不超过宽免额度 10"，因此它接受 5。
      final tasks = [
        const SchedulableTask(
          id: 'set-task',
          requiredMinutes: 100,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
        const SchedulableTask(
          id: 'set-task',
          requiredMinutes: 12,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
        const SchedulableTask(
          id: 'set-task',
          requiredMinutes: 3,
          splitMode: TaskSplitMode.splittable,
          minChunkMinutes: 30,
          maxChunkMinutes: 90,
        ),
        const SchedulableTask(
          id: 'set-task',
          requiredMinutes: 60,
          splitMode: TaskSplitMode.continuous,
          minChunkMinutes: 60,
          maxChunkMinutes: 60,
        ),
      ];
      var checked = 0;
      for (final task in tasks) {
        for (final minutes in [1, 5, 10, 15, 30, 60, 95, 120]) {
          final block = PlannedBlock(
            id: 'single',
            taskId: 'set-task',
            range: TimeRange(
              startUtc: day.add(const Duration(hours: 8)),
              endUtc: day.add(Duration(hours: 8, minutes: minutes)),
            ),
          );
          final strict = isValidPlannedChunk(
            task: task,
            block: block,
            granularityMinutes: 5,
          );
          final set = validatePlannedChunkSet(
            task: task,
            blocks: [block],
            granularityMinutes: 5,
          ).isValid;
          checked++;
          expect(
            set && !strict,
            isFalse,
            reason:
                '单块 $minutes 分钟、required=${task.requiredMinutes}、'
                'min=${task.minChunkMinutes}、split=${task.splitMode.name}：'
                '集合校验接受而 `isValidPlannedChunk` 拒绝——集合校验必须**至少与它一样严**'
                '（快速前置检查只可能更宽，否则引擎能生成、确认却必然失败）',
          );
        }
      }
      expect(checked, greaterThan(0), reason: '前置条件：这条用例真的比较过若干形状');
    });

    test('集合校验可以比单块快速检查更严：12 / min30 / 粒度 5 的 5 分钟块', () {
      // 计划 §2.2 的示例表逐字规定：
      //   | 12 / 30 / 5 | 10 | 合法，缺口 2 |
      //   | 12 / 30 / 5 | 5  | **非法**；合法短尾预算是 10 |
      //
      // 而 `isValidPlannedChunk` 对短余量的判据是"不超过宽免额度"（`5 <= 10`），
      // 因此它**接受**这个 5 分钟块。两者方向不同不是规则漂移，而是计划明确的分工：
      // 唯一短尾的完整判定需要同任务的其它块，只有集合校验做得到。
      const task = SchedulableTask(
        id: 'tail',
        requiredMinutes: 12,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
      );
      PlannedBlock blockOf(int minutes) => PlannedBlock(
        id: 'b-$minutes',
        taskId: 'tail',
        range: TimeRange(
          startUtc: day.add(const Duration(hours: 8)),
          endUtc: day.add(Duration(hours: 8, minutes: minutes)),
        ),
      );

      expect(
        isValidPlannedChunk(
          task: task,
          block: blockOf(5),
          granularityMinutes: 5,
        ),
        isTrue,
        reason: '快速前置检查只看"不超过宽免额度 10"，因此它接受 5',
      );
      expect(
        validatePlannedChunkSet(
          task: task,
          blocks: [blockOf(5)],
          granularityMinutes: 5,
        ).violation,
        ChunkSetViolation.shortTailMismatch,
        reason: '§2.2 示例表：合法短尾预算是 10，5 是"半截短块"',
      );

      // 同一任务配 10 分钟块则两级都接受——差异只来自"是不是恰好那一份余量"。
      expect(
        validatePlannedChunkSet(
          task: task,
          blocks: [blockOf(10)],
          granularityMinutes: 5,
        ).isValid,
        isTrue,
        reason: '§2.2 示例表：12 / 30 / 5 配 10 分钟块合法，缺口 2',
      );
    });
  });
}
