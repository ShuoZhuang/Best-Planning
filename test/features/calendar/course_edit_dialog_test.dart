// 1.8.0（设计规范 §10.2 末条／计划 Task 10 Step 3）：
//
// > **修改课程时间、周次、地点或归属后必须重新检测冲突并预览。**
// > 计划 Step 3：**修改时间后先显示冲突，再允许返回修改；硬冲突不能直接保存。**
//
// `CourseManagementService.previewTimeChange` 与 `detectCourseTimeConflicts` 已经具备，
// 但**页面上没有入口**：`course_edit_dialog.dart` 这个计划声明的文件此前不存在，
// 于是 §10.2 的这一条在界面上不成立（验收表 §3 第 4 行一直是「部分」）。
//
// 本文件先钉住**分类判据**（哪一类冲突属于硬冲突），再钉住对话框的交互。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';

void main() {
  CourseTimeConflict conflict(CourseTimeConflictKind kind) =>
      CourseTimeConflict(
        kind: kind,
        title: '${kind.name} 的标题',
        range: TimeRange(
          startUtc: DateTime.utc(2026, 10, 12, 1),
          endUtc: DateTime.utc(2026, 10, 12, 2),
        ),
        otherEventId: 'other-1',
        proposedEventId: 'proposed-1',
      );

  group('硬冲突与可确认冲突的划分（规范 §10.2／计划 Step 3）', () {
    test('**撞上保护时间是硬冲突**：它的语义就是"这段时间不许安排"', () {
      expect(
        isBlockingCourseTimeConflict(
          conflict(CourseTimeConflictKind.protectedTime),
        ),
        isTrue,
        reason: '保护时间是用户明确建立的不排事时段，改课不能"确认一次就覆盖"',
      );
    });

    test('**撞上固定日程是硬冲突**', () {
      expect(
        isBlockingCourseTimeConflict(
          conflict(CourseTimeConflictKind.fixedEvent),
        ),
        isTrue,
        reason: '固定日程是另一件已经确定的事，改课不能把它盖掉',
      );
    });

    test('撞上别的课程**不是**硬冲突：可以确认后保存（课表冲突是常见现实）', () {
      expect(
        isBlockingCourseTimeConflict(
          conflict(CourseTimeConflictKind.otherCourse),
        ),
        isFalse,
        reason:
            '两门课时间重叠在现实中是存在的（同一时段不同周次、或用户就是要这样排）；'
            '把它做成硬阻断会让用户**无法保存**自己的课表',
      );
    });

    test('撞上同一门课自己的另一片段**不是**硬冲突', () {
      expect(
        isBlockingCourseTimeConflict(
          conflict(CourseTimeConflictKind.sameCourse),
        ),
        isFalse,
        reason: '同一门课的两段相接或重叠由用户自己决定，只需提示',
      );
    });

    test('检测本身认得"提议时段压在保护时间上"', () {
      // 先把检测这一层单独钉住，再看界面。否则界面用例红了会分不清
      // 是"检测没做对"还是"界面没接上"。
      final found = detectCourseTimeConflicts(
        proposed: [
          (
            eventId: 'evt-a',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 1, 5),
              endUtc: DateTime.utc(2026, 1, 5, 1),
            ),
          ),
        ],
        existing: [
          CalendarOccurrence(
            eventId: 'evt-protected',
            title: '午休',
            range: TimeRange(
              startUtc: DateTime.utc(2026, 1, 5),
              endUtc: DateTime.utc(2026, 1, 5, 1),
            ),
            locked: true,
            kind: CalendarEventKind.protected,
          ),
        ],
        editingEventId: 'evt-a',
      );

      expect(found, hasLength(1));
      expect(found.single.kind, CourseTimeConflictKind.protectedTime);
      expect(found.single.title, '午休');
      expect(isBlockingCourseTimeConflict(found.single), isTrue);
    });
  });
}
