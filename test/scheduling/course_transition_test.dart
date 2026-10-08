// 用户 2026-10-08 需求："课表课程后十分钟不安排计划，我上完课要离开教室，肯定不可能直接接续啊。"
//
// 用户同时定了范围（两轮问答）：
//  · **全局规则**（一处设置，不必逐个日程去填）；
//  · 但**只对课表导入的课生效**，自己建的会议不受影响；
//  · **只加在结束后**，不加在开始前（"课与课之间不需要考虑，因为课表本身就会留出时间"）。
//
// 数据里本来就有区分二者的字段：`CalendarEventSourceKind.timetableImport`
// （`CalendarOccurrence.sourceKind`）。因此不需要新增字段，也不必让用户逐个日程填。
//
// **为什么单独抽成一个纯函数**：这条规则会直接影响"哪些时段可排"，而它的边界情况不少——
// 缓冲为 0、课程紧挨着下一节课、缓冲跨过午夜、事件本身在窗口之外。把判定放在
// `load()` 的循环里就只能靠集成测试去碰，而这里可以逐条钉。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/course_transition.dart';

CalendarOccurrence _occurrence({
  required DateTime startUtc,
  required DateTime endUtc,
  CalendarEventSourceKind kind = CalendarEventSourceKind.timetableImport,
  String id = 'evt-1',
}) => CalendarOccurrence(
  eventId: id,
  title: '数据结构课',
  range: TimeRange(startUtc: startUtc, endUtc: endUtc),
  locked: true,
  sourceKind: kind,
);

final _t0 = DateTime.utc(2026, 10, 8, 1); // 东八区 09:00

void main() {
  group('课表课程结束后留缓冲', () {
    test('课表导入的课 ⇒ 结束时间往后推 10 分钟', () {
      final result = applyCourseTransition([
        _occurrence(startUtc: _t0, endUtc: _t0.add(const Duration(hours: 2))),
      ], transitionMinutes: 10);

      expect(result, hasLength(1));
      expect(result.single.range.startUtc, _t0, reason: '开始时间不动');
      expect(
        result.single.range.endUtc,
        _t0.add(const Duration(hours: 2, minutes: 10)),
        reason: '结束时间往后推，于是那 10 分钟变成"被占用"',
      );
    });

    test('**自己建的会议不受影响**（用户明确划的范围）', () {
      final result = applyCourseTransition([
        _occurrence(
          startUtc: _t0,
          endUtc: _t0.add(const Duration(hours: 2)),
          kind: CalendarEventSourceKind.manual,
        ),
      ], transitionMinutes: 10);

      expect(
        result.single.range.endUtc,
        _t0.add(const Duration(hours: 2)),
        reason: '会议不需要"离开教室"的时间；用户选的是只对课表生效',
      );
    });

    test('缓冲为 0 ⇒ 原样返回（等于关闭这条规则）', () {
      final input = [
        _occurrence(startUtc: _t0, endUtc: _t0.add(const Duration(hours: 1))),
      ];
      final result = applyCourseTransition(input, transitionMinutes: 0);

      expect(result.single.range.endUtc, input.single.range.endUtc);
    });

    test('**不往前加**：开始时间从不改变（课与课之间不叠加成 20 分钟）', () {
      final result = applyCourseTransition([
        _occurrence(startUtc: _t0, endUtc: _t0.add(const Duration(hours: 1))),
      ], transitionMinutes: 10);

      expect(
        result.single.range.startUtc,
        _t0,
        reason: '用户明确说课与课之间不用管，课表本身就留了时间；两侧都加会变成 2N',
      );
    });

    test('课与课紧挨着时，缓冲只由**前一段**产生，不与后一段的开始叠加', () {
      // 09:00–11:00 与 11:00–12:00 两节课紧挨（课表没留时间，这是构造出来的边界）。
      final first = _occurrence(
        id: 'a',
        startUtc: _t0,
        endUtc: _t0.add(const Duration(hours: 2)),
      );
      final second = _occurrence(
        id: 'b',
        startUtc: _t0.add(const Duration(hours: 2)),
        endUtc: _t0.add(const Duration(hours: 3)),
      );
      final result = applyCourseTransition([
        first,
        second,
      ], transitionMinutes: 10);

      final byId = {for (final item in result) item.eventId: item};
      expect(
        byId['a']!.range.endUtc,
        _t0.add(const Duration(hours: 2, minutes: 10)),
      );
      expect(
        byId['b']!.range.startUtc,
        _t0.add(const Duration(hours: 2)),
        reason: '后一段的开始不动，因此重叠区只有 10 分钟而不是 20 分钟',
      );
    });

    test('混合输入：只动课表那一条，会议逐值不变', () {
      final course = _occurrence(
        id: 'course',
        startUtc: _t0,
        endUtc: _t0.add(const Duration(hours: 2)),
      );
      final meeting = _occurrence(
        id: 'meeting',
        startUtc: _t0.add(const Duration(hours: 3)),
        endUtc: _t0.add(const Duration(hours: 4)),
        kind: CalendarEventSourceKind.manual,
      );
      final result = applyCourseTransition([
        course,
        meeting,
      ], transitionMinutes: 10);

      final byId = {for (final item in result) item.eventId: item};
      expect(
        byId['course']!.range.endUtc,
        _t0.add(const Duration(hours: 2, minutes: 10)),
      );
      expect(
        byId['meeting']!.range,
        meeting.range,
        reason: '会议整段（含开始与结束）必须逐值不变',
      );
    });

    test('其它字段一律保留（标题、location、importBatchId、logicalCourseId）', () {
      final course = CalendarOccurrence(
        eventId: 'evt-9',
        title: '高等数学',
        range: TimeRange(
          startUtc: _t0,
          endUtc: _t0.add(const Duration(hours: 2)),
        ),
        locked: true,
        location: '三教 305',
        notes: '带教材',
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: 'batch-1',
        logicalCourseId: 'course-7',
      );

      final result = applyCourseTransition([course], transitionMinutes: 10);
      final only = result.single;

      expect(only.title, '高等数学');
      expect(only.location, '三教 305');
      expect(only.notes, '带教材');
      expect(only.importBatchId, 'batch-1');
      expect(only.logicalCourseId, 'course-7');
      expect(only.locked, isTrue);
      expect(
        only.range.startUtc,
        course.range.startUtc,
        reason: '只改结束时间，其余逐值保留',
      );
    });

    test('空输入 ⇒ 空输出', () {
      expect(applyCourseTransition(const [], transitionMinutes: 10), isEmpty);
    });

    test('顺序保持不变（下游按时间排序，但输入顺序不该被这条规则打乱）', () {
      final events = [
        _occurrence(
          id: 'a',
          startUtc: _t0,
          endUtc: _t0.add(const Duration(hours: 1)),
        ),
        _occurrence(
          id: 'b',
          startUtc: _t0.add(const Duration(hours: 2)),
          endUtc: _t0.add(const Duration(hours: 3)),
        ),
      ];
      final result = applyCourseTransition(events, transitionMinutes: 10);

      expect(result.map((item) => item.eventId).toList(), ['a', 'b']);
    });
  });
}
