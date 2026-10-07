import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/area_period_matrix.dart';

/// 只关心 `domainDistribution` 的报告：矩阵只读那一项。
AnalyticsReport _report(
  List<(String label, int planned, int actual)> domains,
) => _reportOf([
  for (final (label, planned, actual) in domains)
    (label: label, planned: planned, actual: actual, fixed: 0),
]);

/// 带固定日程分钟数的报告。
AnalyticsReport _reportWithFixed(
  List<({String label, int planned, int actual, int fixed})> domains,
) => _reportOf(domains);

AnalyticsReport _reportOf(
  List<({String label, int planned, int actual, int fixed})> domains,
) => AnalyticsReport(
  filter: AnalyticsFilter(
    startUtc: DateTime.utc(2026, 10, 5),
    endUtc: DateTime.utc(2026, 10, 12),
  ),
  plannedMinutes: 0,
  actualMinutes: 0,
  completionRate: const RatioMetric(numerator: 0, denominator: 0),
  onTimeCompletionRate: const RatioMetric(numerator: 0, denominator: 0),
  overdueRate: const RatioMetric(numerator: 0, denominator: 0),
  estimateVariance: const RatioMetric(numerator: 0, denominator: 0),
  lifeQuota: const LifeQuotaMetric(
    targetMinutes: 0,
    plannedMinutes: 0,
    actualMinutes: 0,
  ),
  domainDistribution: [
    for (final domain in domains)
      DomainTimeMetric(
        id: domain.label,
        label: domain.label,
        plannedMinutes: domain.planned,
        actualMinutes: domain.actual,
        fixedMinutes: domain.fixed,
      ),
  ],
  trend: const [],
  commonInterruptions: const [],
  replanReasons: const [],
  energyPeriods: const [],
  suggestionBehavior: const SuggestionBehaviorMetric(
    accepted: 0,
    modified: 0,
    rejected: 0,
  ),
);

void main() {
  test('按合计降序排列，同名领域跨周期对齐', () {
    final matrix = buildAreaPeriodMatrix([
      (label: '上周', report: _report([('学业', 120, 999), ('生活', 60, 999)])),
      (label: '本周', report: _report([('生活', 90, 999), ('学业', 30, 999)])),
    ]);

    expect(matrix.periods, ['上周', '本周']);
    // 学业合计 150 > 生活 150? 不等：学业 120+30=150，生活 60+90=150——故意让合计相同，
    // 此时按名称升序，顺序必须可复现。
    expect(matrix.rows.map((row) => row.label), ['学业', '生活']);
    expect(matrix.rows.first.minutes, [120, 30]);
    expect(matrix.rows.last.minutes, [60, 90]);
    expect(matrix.totalMinutes, 300);
  });

  test('只在一个周期出现过的领域也成行，缺失的周期补 0', () {
    // "上周做了、这周没做"正是纵向对比最该看见的那一格，不能因为本周没有就整行消失。
    final matrix = buildAreaPeriodMatrix([
      (label: '上周', report: _report([('学业', 120, 0), ('竞赛', 45, 0)])),
      (label: '本周', report: _report([('学业', 30, 0)])),
    ]);

    expect(matrix.rows.map((row) => row.label), ['学业', '竞赛']);
    expect(matrix.rows.firstWhere((row) => row.label == '竞赛').minutes, [45, 0]);
    expect(matrix.rows.firstWhere((row) => row.label == '竞赛').totalMinutes, 45);
  });

  test('口径是计划块 + 固定日程，仍不掺实际投入', () {
    // 实际投入给一个远大于计划的数：一旦实现里误用了 actualMinutes，这里立刻会红。
    final matrix = buildAreaPeriodMatrix([
      (label: '本周', report: _report([('学业', 120, 9000)])),
    ]);

    expect(matrix.rows.single.minutes, [120]);
    expect(matrix.totalMinutes, 120);
  });

  test('占比按该周期自己的合计算，空周期返回 0 而不是崩', () {
    final matrix = buildAreaPeriodMatrix([
      (label: '上周', report: _report([('学业', 75, 0), ('生活', 25, 0)])),
      // 本周完全没有计划块。
      (label: '本周', report: _report(const [])),
    ]);

    expect(matrix.periodTotal(0), 100);
    expect(matrix.periodTotal(1), 0);
    expect(matrix.sharePercent(75, 0), 75);
    expect(matrix.sharePercent(25, 0), 25);
    // 空周期：不能除零。
    expect(matrix.sharePercent(0, 1), 0);
  });

  test('完全没有数据时是空矩阵', () {
    final matrix = buildAreaPeriodMatrix([
      (label: '本周', report: _report(const [])),
    ]);

    expect(matrix.isEmpty, isTrue);
    expect(matrix.totalMinutes, 0);
    expect(matrix.periods, ['本周']);
  });

  test('同一领域在同一周期出现多项时累加而不是丢数', () {
    final matrix = buildAreaPeriodMatrix([
      (label: '本周', report: _report([('学业', 40, 0), ('学业', 60, 0)])),
    ]);

    expect(matrix.rows.single.minutes, [100]);
  });

  test('固定日程计入领域时间分配（课表本来就是有领域的时间）', () {
    // 2026-10-06 的反馈："领域时间分配为什么不把固定日程统计进去，有的固定日程不是也有领域的吗"。
    // 此前数据集里根本没有日历事件，于是用户的 19 场固定日程（16 场带领域）全部漏掉，
    // 只统计了 6 个任务计划块——占比因此严重失真。
    final matrix = buildAreaPeriodMatrix([
      (
        label: '本周',
        report: _reportWithFixed([
          (label: '学业', planned: 30, actual: 0, fixed: 600),
          (label: '生活', planned: 0, actual: 0, fixed: 60),
        ]),
      ),
    ]);

    final study = matrix.rows.firstWhere((row) => row.label == '学业');
    expect(study.minutes, [630], reason: '计划块 30 + 固定日程 600');
    expect(matrix.periodTotal(0), 690);
    // 占比按总占用算：学业 630/690 ≈ 91%。
    expect(matrix.sharePercent(630, 0), 91);
  });

  test('固定日程能决定排序：只有课表的领域排在只有零散计划的前面', () {
    // 排序用总占用而不是实际投入——用户库里"学业"每周 20+ 小时课表、实际投入只有 1 条，
    // 按实际投入排会让它沉到底部。
    final matrix = buildAreaPeriodMatrix([
      (
        label: '本周',
        report: _reportWithFixed([
          (label: '学业', planned: 0, actual: 0, fixed: 600),
          (label: '科研', planned: 120, actual: 0, fixed: 0),
        ]),
      ),
    ]);

    expect(matrix.rows.map((row) => row.label), ['学业', '科研']);
  });
}
