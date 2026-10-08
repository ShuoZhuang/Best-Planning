// M7 补充（路线图 §11 第 5 条）：图表在**四档材质**下的对比度与明细替代。
//
// 规格：`docs/superpowers/specs/2026-10-07-m7-chart-contrast.md`
//
// **为什么这一条必须换呈现方式，而不是调颜色**（实测，不是猜）：
// 现有饼图把**白色标签直接画在切片上**，而同一张饼的八种颜色里只有三种能到 4.5:1
// （`#E39035` 上只有 2.53:1；「领域占比」用的领域调色板更糟，`#f2b35d` 上只有 1.85:1）。
// 逐色试过改成深色也不行——`#3567D4` 上深色 4.04、`#8B5CC7` 上 4.45，仍不达标。
// 因此口径是：**文字 ≥ 4.5:1、图形本身 ≥ 3:1**，并把切片上的文字挪到正常的表面上。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/features/analytics/chart_view.dart';

/// 四档材质。
const _modes = PlannerMaterialMode.values;

/// 用「领域占比」真实会用的那套颜色：领域调色板的前四色 + 一个自选色。
/// **刻意用这套而不是 `chartPalette`**：领域调色板更浅，白字在上面更差——
/// 只在深色上验证等于绕开了最容易失败的那种情况。
const _domainColors = <int>[0xff2f86ff, 0xff53c7a5, 0xfff2b35d, 0xfff06f7a];

const _labels = <String>['学业', '科研', '生活', '工作'];
const _values = <int>[120, 90, 60, 30];

List<ChartDatum> _data() => [
  for (var index = 0; index < _labels.length; index++)
    ChartDatum(
      label: _labels[index],
      value: _values[index],
      color: Color(_domainColors[index]),
    ),
];

/// WCAG 相对亮度（sRGB），与 M2 的对比度测试同一套算法。
double _luminance(Color color) {
  double channel(double value) => value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

Future<void> _pump(
  WidgetTester tester,
  PlannerMaterialMode mode,
  Widget child,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: PlannerTheme.dark(glassMode: mode),
      home: PlannerBackdrop(
        child: Builder(
          builder: (context) => Scaffold(
            body: PlannerGlassSurface(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ── 四档材质下的文字对比度（规格 §2：文字 ≥ 4.5:1）─────────────────────────

  for (final mode in _modes) {
    testWidgets('M7 ${mode.name}：饼图在四档材质下通过文字对比度检查', (tester) async {
      await _pump(
        tester,
        mode,
        AnalyticsChart(kind: ChartKind.pie, data: _data()),
      );

      // **这一条在修复前是红的**：切片上的白色标签画在浅色切片上，
      // `#f2b35d` 上只有 1.85:1。把文字挪到图例（正常表面）之后才可能通过。
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }

  for (final mode in _modes) {
    testWidgets('M7 ${mode.name}：条形图在四档材质下通过文字对比度检查', (tester) async {
      await _pump(
        tester,
        mode,
        AnalyticsChart(kind: ChartKind.horizontalBar, data: _data()),
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });
  }

  // ── 明细替代（规格 §2：不能只靠颜色区分）──────────────────────────────────

  testWidgets('M7 饼图的名称与数值以文字出现在图例里，不只靠颜色', (tester) async {
    await _pump(
      tester,
      PlannerMaterialMode.off,
      AnalyticsChart(kind: ChartKind.pie, data: _data()),
    );

    for (var index = 0; index < _labels.length; index++) {
      // 名称与数值合在一行文字里（形如「学业 120」）。**这里用 `textContaining`
      // 而不是 `find.text`**：图例刻意把两者放在同一个 `Text` 里，
      // 既省一次布局，也让"名称—数值"在语义树上是**一个**节点（屏幕阅读器一次念完）。
      expect(
        find.textContaining(_labels[index]),
        findsWidgets,
        reason: '「${_labels[index]}」必须以文字出现，否则只能靠颜色分辨',
      );
      expect(
        find.textContaining('${_values[index]}'),
        findsWidgets,
        reason: '「${_labels[index]}」的数值必须以文字出现',
      );
    }
  });

  testWidgets('M7 图形本身对表面至少 3:1（非文本阈值）', (tester) async {
    await _pump(
      tester,
      PlannerMaterialMode.off,
      AnalyticsChart(kind: ChartKind.pie, data: _data()),
    );

    // 图形不是文字，套 4.5:1 会得出"所有浅色都不能用"的结论；WCAG 对图形对象的
    // 阈值是 3:1。这里对**每个数据点的颜色**与它所在表面求比值。
    final surface = PlannerPalette.surface;
    for (var index = 0; index < _domainColors.length; index++) {
      final color = Color(_domainColors[index]);
      final measured = _contrast(color, surface);
      expect(
        measured,
        greaterThanOrEqualTo(3.0),
        reason:
            '「${_labels[index]}」的图形色 ${color.toARGB32().toRadixString(16)} '
            '对表面对比度只有 ${measured.toStringAsFixed(2)}:1，低于 3:1',
      );
    }
  });

  // ── 直接量"白字画在切片上"这件事（`textContrastGuideline` 看不见它）─────────

  test('M7 记录：白字画在领域色切片上是不达标的（这是**改呈现方式**的依据）', () {
    // **这条测试曾经会红，现在不会**——因为它量的是 `Colors.white` 与领域色之间
    // 的理论对比度，而修复的方式是**不再把文字画在切片上**，不是把白字改掉。
    //
    // 它留在这里有两个用处：
    // ① 把"为什么必须改呈现方式"固化成可复算的数字，而不是一句"试过了"；
    // ② 万一有人把切片上的文字加回来，它能立刻指出那是不达标的。
    //
    // **一个反直觉的事实**：`meetsGuideline(textContrastGuideline)` 在上面的
    // "四档材质"用例里**对着旧代码也是通过的**。原因是 fl_chart 把切片标题画在
    // `CustomPaint` 的画布上，而不是作为 `Text` 控件——而 `textContrastGuideline`
    // 遍历的是**语义树上的文字控件**，看不见画布里的字。
    // 所以"整页通过对比度检查"**不等于**"图里的字看得清"。
    const white = Colors.white;
    final measured = [
      for (final argb in _domainColors) _contrast(white, Color(argb)),
    ];
    // 至少有一个领域色上的白字明显不达标（最低的那个只有 1.85:1）。
    expect(
      measured.any((value) => value < 4.5),
      isTrue,
      reason: '领域调色板上至少有一种颜色放白字不达标——这正是要改呈现方式的原因',
    );
    expect(
      measured.reduce(math.min),
      lessThan(3.0),
      reason:
          '最差的那个连图形阈值 3:1 都不到，实际=${measured.map((v) => v.toStringAsFixed(2)).join(", ")}',
    );
  });

  // ── 空数据与单点数据（§11：「空数据与单点数据使用专门状态」）──────────────

  testWidgets('M7 全部为零时显示空状态文案，而不是空白图', (tester) async {
    await _pump(
      tester,
      PlannerMaterialMode.off,
      AnalyticsChart(
        kind: ChartKind.pie,
        data: const [
          ChartDatum(label: '学业', value: 0),
          ChartDatum(label: '科研', value: 0),
        ],
        emptyLabel: '所选范围里还没有数据。',
      ),
    );
    expect(find.text('所选范围里还没有数据。'), findsOneWidget);
  });

  testWidgets('M7 只有一个数据点时不崩，且名称与数值仍可读', (tester) async {
    await _pump(
      tester,
      PlannerMaterialMode.off,
      AnalyticsChart(
        kind: ChartKind.pie,
        data: const [
          ChartDatum(label: '学业', value: 120, color: Color(0xff2f86ff)),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('学业'), findsWidgets);
    expect(find.textContaining('120'), findsWidgets);
  });

  testWidgets('M7 值为 0 的项不画进图里，但其余项照常显示', (tester) async {
    await _pump(
      tester,
      PlannerMaterialMode.off,
      AnalyticsChart(
        kind: ChartKind.pie,
        data: const [
          ChartDatum(label: '学业', value: 120, color: Color(0xff2f86ff)),
          ChartDatum(label: '空领域', value: 0, color: Color(0xff53c7a5)),
        ],
      ),
    );
    expect(find.textContaining('学业'), findsWidgets);
    expect(find.text('空领域'), findsNothing, reason: '值为 0 的项不该占一个图例项——它没有可比的量');
  });
}
