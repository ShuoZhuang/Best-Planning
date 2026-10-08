// M7（路线图 §3.1 最后一条、§11 Task 9）：周期目标在统计页上的独立摘要。
//
// 两条要求：
// 1. 摘要**只**包含目标数量、达标、进行中、未达标、连续达标周数（§11 Task 9 的接口）。
// 2. **不把完成分钟混进领域计划时长**（§3.1 最后一条：周期目标进度单独展示，不混入领域时间
//    分配，也不冒充完整的实际投入统计）。
//
// 第 2 条是这一节存在的全部理由。周期目标的"已完成 80 分钟"来自专注记录与手动补记，
// 而领域时间分配统计的是**计划块**——两者是不同的事实。把它们加在一起，用户看到的那个
// "学业 12 小时"就不再是任何一个真实口径。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/features/analytics/recurring_goal_summary.dart';

RecurringGoalWeek _week({
  required DateTime start,
  int met = 0,
  int inProgress = 0,
  int missed = 0,
  int skipped = 0,
}) => RecurringGoalWeek(
  periodStartLocalDate: start,
  metCount: met,
  inProgressCount: inProgress,
  missedCount: missed,
  skippedCount: skipped,
);

void main() {
  group('汇总口径（§11 Task 9 的接口只允许这几项）', () {
    test('目标数量 = 各状态之和（跳过的不算"未达标"）', () {
      final summary = summarizeRecurringGoals([
        _week(
          start: DateTime(2026, 10, 5),
          met: 2,
          inProgress: 1,
          missed: 1,
          skipped: 1,
        ),
      ]);

      expect(summary.goalCount, 4, reason: '跳过的不计入四个状态里的任何一个');
      expect(summary.metCount, 2);
      expect(summary.inProgressCount, 1);
      expect(summary.missedCount, 1);
      expect(summary.skippedCount, 1);
    });

    test('连续达标周数：从最近一周往回数，遇到第一个未达标就停', () {
      final summary = summarizeRecurringGoals([
        _week(start: DateTime(2026, 10, 5), met: 1), // 本周
        _week(start: DateTime(2026, 9, 28), met: 1), // 上周
        _week(start: DateTime(2026, 9, 21), met: 1), // 上上周
        _week(start: DateTime(2026, 9, 14), met: 0, missed: 1), // 断在这里
        _week(start: DateTime(2026, 9, 7), met: 1),
      ]);

      expect(
        summary.consecutiveMetWeeks,
        3,
        reason: '连续周数必须被"断点"截住，否则它只是一个"达标过几周"的计数',
      );
    });

    test('最近一周就未达标 ⇒ 连续周数为 0', () {
      final summary = summarizeRecurringGoals([
        _week(start: DateTime(2026, 10, 5), met: 0, missed: 1),
        _week(start: DateTime(2026, 9, 28), met: 1),
      ]);

      expect(summary.consecutiveMetWeeks, 0);
    });

    test('最近一周还在进行中 ⇒ 连续周数为 0（它不是达标）', () {
      final summary = summarizeRecurringGoals([
        _week(start: DateTime(2026, 10, 5), inProgress: 1),
        _week(start: DateTime(2026, 9, 28), met: 1),
        _week(start: DateTime(2026, 9, 21), met: 1),
      ]);

      expect(
        summary.consecutiveMetWeeks,
        0,
        reason:
            '这一周还没达标，所以"连续达标周数"是 0。把进行中当成"不算断点"，用户会在周一早上'
            '看到一个上周攒下来的连胜数字，而这一周其实一分钟都还没做',
      );
    });

    test('空输入 ⇒ 全是 0，而不是抛异常', () {
      final summary = summarizeRecurringGoals(const []);

      expect(summary.goalCount, 0);
      expect(summary.metCount, 0);
      expect(summary.inProgressCount, 0);
      expect(summary.missedCount, 0);
      expect(summary.consecutiveMetWeeks, 0);
      expect(summary.isEmpty, isTrue);
    });

    test('周次顺序打乱也得到同样的连续周数（按日期排序，不依赖输入顺序）', () {
      final summary = summarizeRecurringGoals([
        _week(start: DateTime(2026, 9, 21), met: 1),
        _week(start: DateTime(2026, 10, 5), met: 1),
        _week(start: DateTime(2026, 9, 28), met: 1),
      ]);

      expect(summary.consecutiveMetWeeks, 3);
    });

    test('跳过的周**算**断点（跳过不是失败，但也不是达标）', () {
      final summary = summarizeRecurringGoals([
        _week(start: DateTime(2026, 10, 5), met: 1),
        _week(start: DateTime(2026, 9, 28), met: 0, skipped: 1),
        _week(start: DateTime(2026, 9, 21), met: 1),
      ]);

      expect(
        summary.consecutiveMetWeeks,
        1,
        reason:
            '"连续达标周数"数的是连续的**达标**。把跳过算成不断，用户会看到一个比事实更长的'
            '连胜数字——第一版正是那么写的，这条断言当场把它抓了出来',
      );
      // 跳过本身仍要如实计数，只是不参与连续周数。
      expect(summary.skippedCount, 1);
    });

    test('没有任何目标被判定过的一周同样算断点（它不是达标）', () {
      final summary = summarizeRecurringGoals([
        // 本周有实例在跑。
        _week(start: DateTime(2026, 10, 5), inProgress: 1),
        // 上周完全没有实例：这一周边界上模板是暂停的，没有任何目标被判定过。
        _week(start: DateTime(2026, 9, 28)),
        _week(start: DateTime(2026, 9, 21), met: 1),
      ]);

      expect(
        summary.consecutiveMetWeeks,
        0,
        reason: '口径只有一条：连续达标；最早那一周达标，但更近的都没有，因此是 0',
      );
    });
  });

  group('组件（§7.1 第 3、6 条）', () {
    Future<void> pump(
      WidgetTester tester,
      RecurringGoalSummaryData data,
    ) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AnalyticsRecurringGoalSummary(data: data)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('五项都渲染出来，且带 key（供来源明细与测试定位）', (tester) async {
      await pump(
        tester,
        summarizeRecurringGoals([
          _week(start: DateTime(2026, 10, 5), met: 1, inProgress: 1, missed: 1),
        ]),
      );

      expect(
        find.byKey(const Key('analytics-recurring-goals')),
        findsOneWidget,
      );
      expect(find.textContaining('周期目标'), findsWidgets);
      for (final key in [
        'recurring-goal-count',
        'recurring-goal-met',
        'recurring-goal-in-progress',
        'recurring-goal-missed',
        'recurring-goal-streak',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '缺少 $key');
      }
    });

    testWidgets('明说"这是目标进度，不是计划时长"（§3.1 最后一条）', (tester) async {
      await pump(
        tester,
        summarizeRecurringGoals([_week(start: DateTime(2026, 10, 5), met: 1)]),
      );

      // 这句说明是刻意的：不写的话，用户会把这里的分钟/个数与上面的"计划总时长"混为一谈。
      expect(
        find.textContaining('不计入上面的计划时长'),
        findsOneWidget,
        reason: '§3.1 要求周期目标进度单独展示，必须有一句话说明口径',
      );
    });

    testWidgets('没有周期目标时说明原因并给下一步，而不是留一张空卡', (tester) async {
      await pump(tester, summarizeRecurringGoals(const []));

      expect(find.textContaining('还没有周期目标'), findsOneWidget);
      expect(
        find.textContaining('新建'),
        findsOneWidget,
        reason: '空状态要给出下一步（§11 Task 12 Step 3 同一口径）',
      );
    });

    testWidgets('有目标时**不**显示空状态文案', (tester) async {
      await pump(
        tester,
        summarizeRecurringGoals([_week(start: DateTime(2026, 10, 5), met: 1)]),
      );

      expect(find.textContaining('还没有周期目标'), findsNothing);
    });
  });
}
