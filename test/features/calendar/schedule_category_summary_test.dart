import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/calendar/schedule_category_summary.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';

void main() {
  final day = DateTime.utc(2026, 10, 5);

  test('同一分类合并分钟数', () {
    final summaries = summarizeScheduleCategories([
      _item(
        id: 'a',
        key: 'area:study',
        label: '学业',
        color: 0xff2f86ff,
        order: 0,
        start: day,
        end: day.add(const Duration(minutes: 40)),
      ),
      _item(
        id: 'b',
        key: 'area:study',
        label: '学业',
        color: 0xff2f86ff,
        order: 0,
        start: day.add(const Duration(hours: 1)),
        end: day.add(const Duration(hours: 2)),
      ),
    ]);

    expect(summaries, hasLength(1));
    expect(summaries.single.minutes, 100);
  });

  test('不同分类即使颜色相同也不合并', () {
    final summaries = summarizeScheduleCategories([
      _item(
        id: 'a',
        key: 'area:study',
        label: '学业',
        color: 0xff2f86ff,
        order: 0,
        start: day,
        end: day.add(const Duration(minutes: 30)),
      ),
      _item(
        id: 'b',
        key: 'special:unassigned-task',
        label: '未分类任务',
        color: 0xff2f86ff,
        order: 10001,
        start: day.add(const Duration(hours: 1)),
        end: day.add(const Duration(hours: 2)),
      ),
    ]);

    expect(summaries.map((entry) => entry.categoryKey), [
      'area:study',
      'special:unassigned-task',
    ]);
  });

  test('先按分类顺序再按名称稳定排序', () {
    final summaries = summarizeScheduleCategories([
      _item(
        id: 'c',
        key: 'area:c',
        label: '科研',
        color: 0xff53c7a5,
        order: 1,
        start: day,
        end: day.add(const Duration(minutes: 10)),
      ),
      _item(
        id: 'b',
        key: 'area:b',
        label: '工作',
        color: 0xfff2b35d,
        order: 1,
        start: day,
        end: day.add(const Duration(minutes: 10)),
      ),
      _item(
        id: 'a',
        key: 'area:a',
        label: '学业',
        color: 0xff2f86ff,
        order: 0,
        start: day,
        end: day.add(const Duration(minutes: 10)),
      ),
    ]);

    expect(summaries.map((entry) => entry.categoryLabel), ['学业', '工作', '科研']);
  });

  test('空日程返回空汇总', () {
    expect(summarizeScheduleCategories(const []), isEmpty);
  });

  test('跨午夜项目按传入的当天裁剪片段累计', () {
    final summaries = summarizeScheduleCategories([
      _item(
        id: 'overnight',
        key: 'area:research',
        label: '科研',
        color: 0xff53c7a5,
        order: 1,
        start: day,
        end: day.add(const Duration(minutes: 45)),
      ),
    ]);

    expect(summaries.single.minutes, 45);
  });
}

ScheduleViewItem _item({
  required String id,
  required String key,
  required String label,
  required int color,
  required int order,
  required DateTime start,
  required DateTime end,
}) => ScheduleViewItem(
  id: id,
  title: id,
  kind: ScheduleItemKind.task,
  categoryKey: key,
  categoryLabel: label,
  categoryColorArgb: color,
  categorySortOrder: order,
  range: TimeRange(startUtc: start, endUtc: end),
);
