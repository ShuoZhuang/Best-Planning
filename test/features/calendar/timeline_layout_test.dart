// M5（路线图 §9）周时间轴的几何：高度比例、极短任务下限、并排不重叠、可见范围。
//
// **为什么这一组要穷举**：这些规则错了画面**看起来仍然整齐**——
// 两块各占一半宽却仍左右重叠、30 分钟与 60 分钟高度差不多、极短任务小到点不中，
// 都不是一眼能看出来的。做成纯逻辑之后就能把边界一个个钉死。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/timeline_layout.dart';

/// 造一条当天 [startMinute]–[endMinute] 的条目。
///
/// **必须用 UTC 构造**：`TimeRange` 强制要求 UTC（它会 assert），而这一组用例只关心几何、
/// 不关心时区，因此用 `DateTime.utc` 让"当天第几分钟"与墙钟时间逐分对应，
/// 不给换算留任何歧义。
ScheduleViewItem _item(String id, int startMinute, int endMinute) {
  final base = DateTime.utc(2026, 10, 7);
  return ScheduleViewItem(
    id: id,
    title: id,
    kind: ScheduleItemKind.task,
    range: TimeRange(
      startUtc: base.add(Duration(minutes: startMinute)),
      endUtc: base.add(Duration(minutes: endMinute)),
    ),
    categoryKey: 'test',
    categoryLabel: '测试',
    categoryColorArgb: 0xff456789,
    categorySortOrder: 0,
  );
}

int _startOf(ScheduleViewItem item) => minuteOfDay(item.range.startUtc);
int _endOf(ScheduleViewItem item) => minuteOfDay(item.range.endUtc);

/// 10 分钟 = 10 像素，最小高度 18 像素。
const _metrics = TimelineMetrics(
  windowStartMinute: 0,
  windowEndMinute: 24 * 60,
  pixelsPerMinute: 1,
  minimumBlockHeight: 18,
);

List<TimelineBlock> _layout(List<ScheduleViewItem> items) => layoutTimelineDay(
  items: items,
  metrics: _metrics,
  startMinuteOf: _startOf,
  endMinuteOf: _endOf,
);

/// 两块在像素上是否重叠（同列才算重叠；不同列是"并排"，正是我们要的）。
bool _overlapsOnScreen(TimelineBlock a, TimelineBlock b) {
  if (a.lane == b.lane && a.laneCount == b.laneCount) {
    // 同一列、同一团：比较纵向区间。
    return a.top < b.top + b.height && b.top < a.top + a.height;
  }
  // 不同列 → 横向分开，不算重叠。
  return false;
}

void main() {
  // ── 高度与时长成比例（§9 退出条件第一条）────────────────────────────────────

  test('M5 同样时长 ⇒ 同样高度', () {
    final blocks = _layout([
      _item('a', 9 * 60, 10 * 60),
      _item('b', 14 * 60, 15 * 60),
    ]);
    expect(blocks, hasLength(2));
    expect(blocks[0].height, blocks[1].height);
    expect(blocks[0].height, 60);
  });

  test('M5 不同时长 ⇒ 有可观察的比例差异', () {
    final blocks = _layout([
      _item('half', 9 * 60, 9 * 60 + 30),
      _item('full', 14 * 60, 15 * 60),
    ]);
    final half = blocks.firstWhere((block) => block.itemId == 'half');
    final full = blocks.firstWhere((block) => block.itemId == 'full');
    // 30 分钟应当恰好是 60 分钟的一半——"可观察的比例差异"在这里是精确的。
    expect(half.height, closeTo(full.height / 2, 0.001));
  });

  test('M5 极短任务被抬到最小可点击高度，且不会小到点不中', () {
    final blocks = _layout([_item('tiny', 9 * 60, 9 * 60 + 5)]);
    expect(blocks.single.height, _metrics.minimumBlockHeight);
    // 按比例算只有 5 像素——确实是被下限抬起来的，而不是碰巧。
    expect(_metrics.isClampedFor(5), isTrue);
    expect(blocks.single.height, greaterThan(5 * _metrics.pixelsPerMinute));
  });

  test('M5 刚好处在下限边界上的时长不被抬高', () {
    // 18 分钟 × 1 像素/分 = 18，正好等于下限。
    expect(_metrics.isClampedFor(18), isFalse);
    expect(_metrics.heightFor(18), 18);
  });

  // ── 并排：重叠的块绝不能互相盖住（§9 退出条件：重叠、极短）──────────────────

  test('M5 完全同时发生的两块并排，各占一半宽', () {
    final blocks = _layout([
      _item('a', 9 * 60, 10 * 60),
      _item('b', 9 * 60, 10 * 60),
    ]);
    expect(blocks, hasLength(2));
    for (final block in blocks) {
      expect(block.laneCount, 2, reason: '两块同时，必须两列');
    }
    expect(blocks.map((block) => block.lane).toSet(), {
      0,
      1,
    }, reason: '两块必须在不同的列，否则会互相盖住');
    for (final block in blocks) {
      expect(block.widthFraction, closeTo(0.5, 0.001));
    }
  });

  test('M5 **交叉区间**也必须并排（这是贪心最容易算错的一种）', () {
    // A 09:00–11:00、B 09:30–10:00、C 10:30–11:30：**三者两两重叠**（A 与 C 也重叠），
    // 因此必须三列。若按"找第一个空位"的贪心，很容易只给出两列，
    // 于是 A 与 C 各占一半宽却仍然左右重叠——那正是 §9 禁止的"互相覆盖"。
    final blocks = _layout([
      _item('a', 9 * 60, 11 * 60),
      _item('b', 9 * 60 + 30, 10 * 60),
      _item('c', 10 * 60 + 30, 11 * 60 + 30),
    ]);
    expect(blocks, hasLength(3));
    for (final block in blocks) {
      expect(block.laneCount, 3, reason: '${block.itemId} 所在团有三块，必须三列');
      expect(block.widthFraction, closeTo(1 / 3, 0.001));
    }
    expect(blocks.map((block) => block.lane).toSet(), {0, 1, 2});
  });

  test('M5 嵌套区间算作一团', () {
    // A 09:00–12:00、B 10:00–11:00、C 10:30–11:30：三者两两重叠。
    final blocks = _layout([
      _item('a', 9 * 60, 12 * 60),
      _item('b', 10 * 60, 11 * 60),
      _item('c', 10 * 60 + 30, 11 * 60 + 30),
    ]);
    for (final block in blocks) {
      expect(block.laneCount, 3);
    }
  });

  test('M5 相邻但不相交的两块**都占满整宽**，不得并排', () {
    // 09:00–10:00 与 10:00–11:00 首尾相接但**不重叠**（半开区间）。
    // 若把它们并排，用户会以为两件事同时进行——这是语义错误，不只是排版问题。
    final blocks = _layout([
      _item('a', 9 * 60, 10 * 60),
      _item('b', 10 * 60, 11 * 60),
    ]);
    for (final block in blocks) {
      expect(block.laneCount, 1, reason: '不重叠就不该并排');
      expect(block.widthFraction, 1.0);
      expect(block.lane, 0);
    }
  });

  test('M5 同一时刻可见的块**没有任何两块在屏幕上重叠**', () {
    // 这是本里程碑的硬要求（§9："不允许相互覆盖后只剩一个可见"）。
    // 直接对"任意两块"做像素级检查，而不是只检查我列出的那几种形状。
    final blocks = _layout([
      _item('a', 9 * 60, 11 * 60),
      _item('b', 9 * 60 + 30, 10 * 60),
      _item('c', 10 * 60 + 30, 11 * 60 + 30),
      _item('d', 14 * 60, 15 * 60),
      _item('e', 14 * 60, 14 * 60 + 30),
    ]);
    for (var i = 0; i < blocks.length; i++) {
      for (var j = i + 1; j < blocks.length; j++) {
        expect(
          _overlapsOnScreen(blocks[i], blocks[j]),
          isFalse,
          reason:
              '「${blocks[i].itemId}」与「${blocks[j].itemId}」在屏幕上重叠了：'
              '${blocks[i].top}..${blocks[i].top + blocks[i].height} lane=${blocks[i].lane}/${blocks[i].laneCount} '
              'vs ${blocks[j].top}..${blocks[j].top + blocks[j].height} lane=${blocks[j].lane}/${blocks[j].laneCount}',
        );
      }
    }
  });

  test('M5 每个团独立算列数：拥挤的上午不把下午也压窄', () {
    final blocks = _layout([
      _item('am1', 9 * 60, 10 * 60),
      _item('am2', 9 * 60, 10 * 60),
      _item('pm', 14 * 60, 15 * 60),
    ]);
    final pm = blocks.firstWhere((block) => block.itemId == 'pm');
    expect(pm.laneCount, 1, reason: '下午只有一件事，应当占满整宽');
    final am = blocks.where((block) => block.itemId.startsWith('am'));
    for (final block in am) {
      expect(block.laneCount, 2);
    }
  });

  test('M5 结果对同样输入稳定（不因排序不稳而抖动）', () {
    final items = [
      _item('a', 9 * 60, 11 * 60),
      _item('b', 9 * 60 + 30, 10 * 60),
      _item('c', 10 * 60 + 30, 11 * 60 + 30),
    ];
    final first = _layout(items);
    final second = _layout(items.reversed.toList());
    String digest(List<TimelineBlock> blocks) =>
        (blocks.toList()..sort((x, y) => x.itemId.compareTo(y.itemId)))
            .map((block) => '${block.itemId}:${block.lane}/${block.laneCount}')
            .join(',');
    expect(digest(second), digest(first), reason: '输入顺序不该改变布局结果');
  });

  // ── 可见时间范围（"默认显示有效时间范围"）──────────────────────────────────

  test('M5 全天无安排 ⇒ 回落到 08:00–22:00', () {
    final window = timelineWindowFor(const []);
    expect(window.start, 8 * 60);
    expect(window.end, 22 * 60);
  });

  test('M5 有效范围向内取整到半小时，并留出最小视野', () {
    // 09:10–09:40 → 起点往下取到 09:00、终点往上取到 09:30；
    // 但只有 30 分钟，必须被撑到至少 2 小时。
    final window = timelineWindowFor([(start: 9 * 60 + 10, end: 9 * 60 + 40)]);
    expect(window.start, 9 * 60);
    expect(
      window.end - window.start,
      greaterThanOrEqualTo(120),
      reason: '只安排一件事时不该得到一条极扁的带子',
    );
    expect(window.end, greaterThanOrEqualTo(9 * 60 + 40));
  });
  test('M5 有安排时范围覆盖全部安排', () {
    final window = timelineWindowFor([
      (start: 7 * 60 + 20, end: 8 * 60),
      (start: 19 * 60 + 40, end: 21 * 60 + 10),
    ]);
    expect(window.start, lessThanOrEqualTo(7 * 60 + 20));
    expect(window.end, greaterThanOrEqualTo(21 * 60 + 10));
  });

  test('M5 范围不会超出一整天', () {
    final window = timelineWindowFor([
      (start: 0, end: 5),
      (start: 23 * 60 + 55, end: 24 * 60),
    ]);
    expect(window.start, greaterThanOrEqualTo(0));
    expect(window.end, lessThanOrEqualTo(24 * 60));
  });

  // ── 跨午夜 / 边界 ──────────────────────────────────────────────────────────

  test('M5 跨午夜：结束落在次日 00:00 时画到列底，而不是负高度', () {
    // 数据源会把 23:00–01:00 按当天裁剪成 23:00–次日 00:00。
    final range = minuteRangeInDay(
      DateTime(2026, 10, 7, 23),
      DateTime(2026, 10, 8), // 次日 00:00
    );
    expect(range.start, 23 * 60);
    expect(range.end, 24 * 60, reason: '结束早于开始 ⇒ 视为当天 24:00，否则高度会是负数');
    expect(range.end - range.start, 60);
  });

  test('M5 普通区间不受跨午夜兜底影响', () {
    final range = minuteRangeInDay(
      DateTime(2026, 10, 7, 9, 30),
      DateTime(2026, 10, 7, 11),
    );
    expect(range.start, 9 * 60 + 30);
    expect(range.end, 11 * 60);
  });

  test('M5 零长度区间走跨午夜兜底（虽然 TimeRange 本身不允许零长度）', () {
    // `TimeRange` 会 assert `endUtc > startUtc`，因此**零长度的块根本进不来**——
    // 这一点是我先前猜错的（我以为"被删除的那一次"的零长度标记会流到这里）。
    // 这个用例因此退化成验证兜底判据本身：`end <= start` 时按当天 24:00 处理。
    final range = minuteRangeInDay(
      DateTime(2026, 10, 7, 9),
      DateTime(2026, 10, 7, 9),
    );
    expect(range.end, 24 * 60, reason: 'end <= start 走兜底，不会得到负高度');
    expect(range.end - range.start, greaterThan(0));
  });

  // ── 空与几何换算 ───────────────────────────────────────────────────────────

  test('M5 没有任何条目 ⇒ 空列表（不是一堆零高度的块）', () {
    expect(_layout(const []), isEmpty);
  });

  test('M5 纵坐标按可见范围偏移', () {
    const metrics = TimelineMetrics(
      windowStartMinute: 8 * 60,
      windowEndMinute: 22 * 60,
      pixelsPerMinute: 2,
      minimumBlockHeight: 18,
    );
    expect(metrics.topFor(8 * 60), 0, reason: '可见范围起点应当贴顶');
    expect(metrics.topFor(9 * 60), 120, reason: '9:00 距 8:00 一小时 × 2 像素/分');
    expect(metrics.contentHeight, (22 - 8) * 60 * 2);
  });
}
