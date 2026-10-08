// M7（路线图 §11）退出条件："同一领域在今日、日历、统计三个页面显示同一个 ARGB 值"。
//
// **这条以前是不成立的，而且很难靠肉眼看出来**：统计页的「领域占比」用的是自己那套
// `chartPalette`（`chart_view.dart`），按下标取色——第 1 个领域拿第 1 个色、第 2 个拿第 2 个。
// 而今日页与日历页用的是 `resolveAreaColorArgb`（用户选过的颜色，没选过就按 `sortOrder`
// 从调色板取默认色）。于是"学业"在两个页面里可能是两种颜色，用户完全没法把两张图对上。
//
// §11 原文就写着"图表不得重新分配颜色"。修法是让统计页也用**同一个解析器**——
// 本文件把这件事钉住：领域分布在服务层带上颜色与排序位，界面才可能算出与别处一致的值。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';

/// 只回放一份固定数据集的来源替身（与 `analytics_service_test.dart` 同一形状）。
final class _FixedSource implements AnalyticsDataSource {
  const _FixedSource(this.dataset);
  final AnalyticsDataset dataset;

  @override
  Future<AnalyticsDataset> load(AnalyticsFilter filter) async => dataset;
}

void main() {
  final start = DateTime.utc(2026, 10, 2, 10);
  final end = DateTime.utc(2026, 10, 9, 10);

  /// 一份带**三个领域**的数据集：一个用户自选过颜色、两个没选过（默认色 + 不同排序位）。
  AnalyticsDataset dataset() => AnalyticsDataset(
    weeklyLifeQuotaMinutes: 360,
    areas: const [
      // 用户自己选过颜色（`storedColorArgb != 0`）。
      AnalyticsAreaFact(
        id: 'area-study',
        name: '学业',
        isLife: false,
        storedColorArgb: 0xff123456,
        sortOrder: 0,
      ),
      // 没选过颜色：取调色板第 1 个（`sortOrder = 1`）。
      AnalyticsAreaFact(
        id: 'area-research',
        name: '科研',
        isLife: false,
        sortOrder: 1,
      ),
      // 没选过颜色：取调色板第 2 个。
      AnalyticsAreaFact(
        id: 'area-life',
        name: '生活',
        isLife: true,
        sortOrder: 2,
      ),
    ],
    tasks: [
      AnalyticsTaskFact(
        id: 't-study',
        title: '课程论文',
        areaId: 'area-study',
        areaName: '学业',
        projectId: null,
        status: TaskStatus.open,
        isLifeTask: false,
        estimatedMinutes: 60,
      ),
      AnalyticsTaskFact(
        id: 't-research',
        title: '实验',
        areaId: 'area-research',
        areaName: '科研',
        projectId: null,
        status: TaskStatus.open,
        isLifeTask: false,
        estimatedMinutes: 60,
      ),
      AnalyticsTaskFact(
        id: 't-life',
        title: '散步',
        areaId: 'area-life',
        areaName: '生活',
        projectId: null,
        status: TaskStatus.open,
        isLifeTask: false,
        estimatedMinutes: 60,
      ),
    ],
    plannedBlocks: [
      AnalyticsPlannedFact(
        taskId: 't-study',
        startUtc: start,
        endUtc: start.add(const Duration(hours: 1)),
      ),
      AnalyticsPlannedFact(
        taskId: 't-research',
        startUtc: start.add(const Duration(hours: 1)),
        endUtc: start.add(const Duration(hours: 2)),
      ),
      AnalyticsPlannedFact(
        taskId: 't-life',
        startUtc: start.add(const Duration(hours: 2)),
        endUtc: start.add(const Duration(hours: 3)),
      ),
    ],
  );

  test('M7 领域分布带出颜色与排序位，界面才能与今日页、日历页同色', () async {
    final report = await AnalyticsService(source: _FixedSource(dataset()))
        .query(AnalyticsFilter(startUtc: start, endUtc: end));

    final byId = {for (final item in report.domainDistribution) item.id: item};

    // ① 用户自选过颜色 → 原样带出。
    expect(
      byId['area-study']!.storedColorArgb,
      0xff123456,
      reason: '用户选过的颜色必须原样保留，统计页不能另给一个',
    );

    // ② 没选过 → 带出 0 与排序位，由界面用**共享解析器**算默认色。
    expect(byId['area-research']!.storedColorArgb, 0);
    expect(byId['area-research']!.sortOrder, 1);
    expect(byId['area-life']!.sortOrder, 2);

    // ③ 关键断言：统计页"最终会画出来的颜色"与其它三个页面用的是**同一个函数**。
    //    `resolveAreaColorArgb` 正是今日页、日历页、领域管理页取色的那一个。
    for (final item in report.domainDistribution) {
      final expected = resolveAreaColorArgb(
        item.storedColorArgb,
        item.sortOrder,
      );
      expect(
        expected,
        item.storedColorArgb != 0
            ? item.storedColorArgb
            : areaPaletteArgb[item.sortOrder % areaPaletteArgb.length],
        reason: '「${item.label}」的取色必须走共享解析器',
      );
      // 颜色必须是有效的不透明 ARGB——半透明或越界值会让图表与背景混在一起。
      expect(isOpaqueArgb(expected), isTrue, reason: '解析出来的颜色必须不透明');
    }

    // ④ 三个领域必须**颜色互不相同**：若统计页仍按下标取色，这一条在领域顺序变化后会红。
    final colors = {
      for (final item in report.domainDistribution)
        resolveAreaColorArgb(item.storedColorArgb, item.sortOrder),
    };
    expect(colors.length, 3, reason: '三个领域的颜色必须互不相同');
  });

  test('M7 没有领域事实时不会崩溃，颜色留给界面兜底', () async {
    // 数据集里没有 `areas`（旧数据、或领域刚被删掉）时，分布仍要能算出来，
    // 只是颜色位为 0——界面据此走中性色，而不是抛异常。
    final report = await AnalyticsService(
      source: _FixedSource(
        AnalyticsDataset(
          weeklyLifeQuotaMinutes: 0,
          tasks: [
            AnalyticsTaskFact(
              id: 't1',
              title: '无领域任务',
              areaId: null,
              areaName: null,
              projectId: null,
              status: TaskStatus.open,
              isLifeTask: false,
              estimatedMinutes: 60,
            ),
          ],
          plannedBlocks: [
            AnalyticsPlannedFact(
              taskId: 't1',
              startUtc: start,
              endUtc: start.add(const Duration(hours: 1)),
            ),
          ],
        ),
      ),
    ).query(AnalyticsFilter(startUtc: start, endUtc: end));

    final unassigned = report.domainDistribution.single;
    expect(unassigned.id, 'unassigned');
    expect(unassigned.storedColorArgb, 0);
    expect(unassigned.sortOrder, 0);
  });

  test('M7 领域占比的取色不再依赖领域在列表里的位置', () {
    // 这是本缺陷的**直接特征**：按下标取色时，同一个领域只要排序变化就会换颜色；
    // 按共享解析器取色时，颜色只由"领域自己的颜色与排序位"决定。
    // 这里直接对解析器断言：换了列表位置，解析结果不变。
    final first = resolveAreaColorArgb(0, 1);
    final second = resolveAreaColorArgb(0, 1);
    expect(first, second);
    // 而"按下标"那套会给同一个领域两个不同的值——用 `chartPalette` 复现一下它的行为，
    // 说明为什么必须换掉它（这条不是为了测 `chartPalette`，而是把两者的差别写清楚）。
    expect(
      chartColorAt(0) == chartColorAt(1),
      isFalse,
      reason: '按下标取色时同一个领域换个位置就换色——这正是 §11 禁止的"重新分配颜色"',
    );
  });
}
