import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/scheduling/pressure_calculator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// T3：这个文件原先的断言把实现里的算式**重算了一遍**——120 和 252 都是公式的输出，
/// 却没有说明它们为什么该是这些数，因此读者无法判断"正确"与"恰好当前如此"。
///
/// 改法有两条：① 每个具体数字当场推出来（分母是总容量、分子是截止前可见的容量）；② 补上
/// **不依赖该算式**的性质——上界、零容量、单调性。性质不会被"公式写错了但自洽"骗过。
void main() {
  const calculator = PressureCalculator();

  SchedulableTask task({DateTime? dueAtUtc, int requiredMinutes = 360}) =>
      SchedulableTask(
        id: 'thesis',
        requiredMinutes: requiredMinutes,
        splitMode: TaskSplitMode.splittable,
        minChunkMinutes: 30,
        maxChunkMinutes: 90,
        dueAtUtc: dueAtUtc,
      );

  final due = DateTime.utc(2026, 10, 22);

  test('后期容量足以覆盖时，当下只按可见容量比例推进', () {
    // 总容量 = 420 + 840 = 1260，其中截止前可见的只有 420（1/3）。
    // 因此"按比例推进"= 360 × 420 / 1260 = 120；而后期 840 已超过全部 360，所以当下不必
    // 额外补（requiredNow = 0）。
    final result = calculator.calculate(
      task(dueAtUtc: due),
      const CapacityModel(
        horizonCapacityMinutes: 420,
        capacityAfterHorizonBeforeDueMinutes: 840,
      ),
    );

    expect(result.requiredNowMinutes, 0);
    expect(result.pacedNowMinutes, 360 * 420 ~/ 1260);
    expect(result.targetMinutes, 120);
  });

  test('后期容量不足时，缺口由当下补上', () {
    // 后期只有 180，任务需要 360，缺口 180 必须在当下安排；
    // 按比例推进 = 360 × 420 / 600 = 252，比缺口更大，因此目标取 252。
    final result = calculator.calculate(
      task(dueAtUtc: due),
      const CapacityModel(
        horizonCapacityMinutes: 420,
        capacityAfterHorizonBeforeDueMinutes: 180,
      ),
    );

    expect(result.requiredNowMinutes, 360 - 180);
    expect(result.pacedNowMinutes, 252);
    expect(result.targetMinutes, 252);
  });

  test('目标永远不超过任务本身', () {
    // 性质：再宽裕的容量也只说明"可以慢些做"，不会让目标超过要做的量。
    final result = calculator.calculate(
      task(dueAtUtc: due),
      const CapacityModel(
        horizonCapacityMinutes: 100000,
        capacityAfterHorizonBeforeDueMinutes: 0,
      ),
    );

    expect(result.targetMinutes, lessThanOrEqualTo(360));
    expect(result.targetMinutes, lessThanOrEqualTo(result.pacedNowMinutes));
  });

  test('总容量为零时按比例推进退化为整份任务，而不是零', () {
    // 性质：没有任何可见容量时，正确的答案是"整份都得排"，而不是"按比例得到 0"——
    // 后者会让一份有截止日期、却一时看不到容量的任务被排成什么都不做。
    final result = calculator.calculate(
      task(dueAtUtc: due),
      const CapacityModel(
        horizonCapacityMinutes: 0,
        capacityAfterHorizonBeforeDueMinutes: 0,
      ),
    );

    expect(result.pacedNowMinutes, 360);
    expect(result.targetMinutes, 360);
  });

  test('削减后期容量不会让当下该做的量变少', () {
    // 性质（单调性）：这是一个**不依赖具体算式**的断言。后期容量减少只可能让当下更紧，
    // 绝不会更松；若把算式里的 max/min 写反，这条会失败而具体数值用例反而不一定失败。
    var previousRequired = 0;
    var previousTarget = 0;
    for (final laterCapacity in [1000, 840, 400, 180, 0]) {
      final result = calculator.calculate(
        task(dueAtUtc: due),
        CapacityModel(
          horizonCapacityMinutes: 420,
          capacityAfterHorizonBeforeDueMinutes: laterCapacity,
        ),
      );
      expect(result.requiredNowMinutes, greaterThanOrEqualTo(previousRequired));
      expect(result.targetMinutes, greaterThanOrEqualTo(previousTarget));
      previousRequired = result.requiredNowMinutes;
      previousTarget = result.targetMinutes;
    }
  });

  test('没有截止日期就不制造截止压力', () {
    final result = calculator.calculate(
      task(),
      const CapacityModel(
        horizonCapacityMinutes: 420,
        capacityAfterHorizonBeforeDueMinutes: 0,
      ),
    );

    expect(result.hasDeadlinePressure, isFalse);
    expect(result.targetMinutes, 0);
  });

  test('容量估计不会往前推超过 180 天', () {
    final now = DateTime.utc(2026, 10, 1);
    final model = CapacityModel.estimate(
      nowUtc: now,
      horizonEndUtc: now.add(const Duration(days: 7)),
      dueAtUtc: now.add(const Duration(days: 365)),
      // 每天 60 分钟：视界内 7 天 = 420；之后到 180 天上限还有 173 天 = 10380。
      capacityForRange: (start, end) => end.difference(start).inDays * 60,
    );

    expect(model.evaluatedUntilUtc, now.add(const Duration(days: 180)));
    expect(model.horizonCapacityMinutes, 7 * 60);
    expect(model.capacityAfterHorizonBeforeDueMinutes, 173 * 60);
  });
}
