// 1.8.0（设计规范 §10.2 最后一条，计划 Task 10）：**改课程时间前必须先检测冲突并预览**。
//
// 规范原文："修改课程时间、周次、地点或归属后必须重新检测冲突并预览。"
//
// 这一条此前**完全没有实现**：`CourseDetailPage` 有范围选择、暂停、删除（带影响预览），
// 但**没有"改时间"这条路径**，因此也就没有冲突预览。它是 §3 矩阵第 4 行
// （"保存前看到冲突预览"）判为「部分」的原因。
//
// 用**纯函数**测：冲突检测是"给定一批新时段，找出与既有占用重叠的那些"，
// 与界面无关。界面只负责把它显示出来。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  final day = DateTime.utc(2026, 10, 12);
  DateTime at(int hour, [int minute = 0]) =>
      day.add(Duration(hours: hour, minutes: minute));

  CalendarOccurrence occurrence({
    required String id,
    required int startHour,
    required int endHour,
    String title = '已有安排',
    CalendarEventKind kind = CalendarEventKind.fixed,
    String? logicalCourseId,
  }) => CalendarOccurrence(
    eventId: id,
    title: title,
    range: TimeRange(startUtc: at(startHour), endUtc: at(endHour)),
    locked: true,
    kind: kind,
    logicalCourseId: logicalCourseId,
  );

  /// 一门课改到 [newStartHour]–[newEndHour] 之后的冲突检测。
  List<CourseTimeConflict> conflicts({
    required List<CalendarOccurrence> existing,
    required int newStartHour,
    required int newEndHour,
    String editingEventId = 'evt-own',
    Set<String> sameCourseEventIds = const {},
  }) => detectCourseTimeConflicts(
    // 只给一段：冲突检测与"几个片段"无关，多段只是把同一段逻辑跑多遍。
    proposed: [
      (
        eventId: 'evt-own',
        range: TimeRange(startUtc: at(newStartHour), endUtc: at(newEndHour)),
      ),
    ],
    existing: existing,
    editingEventId: editingEventId,
    sameCourseEventIds: sameCourseEventIds,
  );

  test('新时段与固定日程重叠时报冲突，并带上对方的标题', () {
    final found = conflicts(
      existing: [
        occurrence(id: 'evt-fixed', startHour: 10, endHour: 11, title: '线性代数'),
      ],
      newStartHour: 10,
      newEndHour: 11,
    );

    expect(found, hasLength(1));
    expect(found.single.title, '线性代数');
    expect(
      found.single.kind,
      CourseTimeConflictKind.fixedEvent,
      reason: '固定日程与保护时间要分开报——它们的处置方式不同',
    );
  });

  test('新时段与**保护时间**重叠时报成不同的一类', () {
    final found = conflicts(
      existing: [
        occurrence(
          id: 'evt-protected',
          startHour: 10,
          endHour: 11,
          title: '午餐',
          kind: CalendarEventKind.protected,
        ),
      ],
      newStartHour: 10,
      newEndHour: 11,
    );

    expect(found.single.kind, CourseTimeConflictKind.protectedTime);
    expect(found.single.title, '午餐');
  });

  test('与**同一门课自己的**其它片段重叠时报成"课程自身冲突"', () {
    final found = conflicts(
      existing: [
        occurrence(
          id: 'evt-own-other',
          startHour: 10,
          endHour: 11,
          title: '高等数学(上)',
          logicalCourseId: 'course-calc',
        ),
      ],
      newStartHour: 10,
      newEndHour: 11,
      sameCourseEventIds: const {'evt-own-other'},
    );

    expect(
      found.single.kind,
      CourseTimeConflictKind.sameCourse,
      reason: '同一门课的两个片段撞在一起是最该拦下的一种改动',
    );
  });

  test('与**别的课**重叠时报成"其它课程冲突"', () {
    final found = conflicts(
      existing: [
        occurrence(
          id: 'evt-other-course',
          startHour: 10,
          endHour: 11,
          title: '大学物理',
          logicalCourseId: 'course-physics',
        ),
      ],
      newStartHour: 10,
      newEndHour: 11,
    );

    expect(found.single.kind, CourseTimeConflictKind.otherCourse);
    expect(found.single.title, '大学物理');
  });

  test('**改到的位置空着时不报冲突**（否则每次改都会吓用户一跳）', () {
    final found = conflicts(
      existing: [
        occurrence(id: 'evt-fixed', startHour: 8, endHour: 9),
        occurrence(id: 'evt-protected', startHour: 12, endHour: 13),
      ],
      newStartHour: 10,
      newEndHour: 11,
    );

    expect(found, isEmpty);
  });

  test('首尾相接不算冲突（半开区间）', () {
    final found = conflicts(
      existing: [occurrence(id: 'evt-fixed', startHour: 11, endHour: 12)],
      newStartHour: 10,
      newEndHour: 11,
    );

    expect(
      found,
      isEmpty,
      reason: '10:00–11:00 与 11:00–12:00 不重叠；把它算冲突会让相邻课无法保存',
    );
  });

  test('自己的锚点**不算**与自己的冲突（否则改自己永远失败）', () {
    final found = conflicts(
      existing: [
        occurrence(
          id: 'evt-own',
          startHour: 9,
          endHour: 10,
          title: '高等数学(上)',
          logicalCourseId: 'course-calc',
        ),
      ],
      newStartHour: 10,
      newEndHour: 11,
    );

    expect(found, isEmpty, reason: '把"这一门课自己的旧位置"当成障碍，等于任何时间改动都不可能通过');
  });

  test('冲突按开始时刻排序，且**顺序确定**', () {
    final input = [
      occurrence(id: 'late', startHour: 15, endHour: 16, title: '乙'),
      occurrence(id: 'early', startHour: 10, endHour: 11, title: '甲'),
    ];

    List<String> run() => [
      for (final conflict in conflicts(
        existing: input,
        newStartHour: 10,
        newEndHour: 16,
      ))
        conflict.title,
    ];

    expect(run(), ['甲', '乙']);
    expect(run(), run(), reason: '顺序不确定会让预览两次显示不同的清单');
  });

  test('同一对方块的多次重叠只报一条（按对方 id 去重）', () {
    // 新时段横跨两个小时，而对方是一个两小时的块：不能报成两条。
    final found = conflicts(
      existing: [occurrence(id: 'evt-long', startHour: 10, endHour: 12)],
      newStartHour: 10,
      newEndHour: 12,
    );

    expect(found, hasLength(1), reason: '同一条既有占用只该提醒一次，重复行会让用户以为有两处冲突');
  });
}
