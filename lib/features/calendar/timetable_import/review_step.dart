import 'package:flutter/material.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';

final class TimetableReviewStep extends StatelessWidget {
  const TimetableReviewStep({required this.controller, super.key});

  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) {
    final courses = controller.draft?.courses ?? const <CourseDraft>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('校对课程', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '请确认课程名、上课日、节次和教学周。领域决定统计归类，项目是领域下更具体的长期事项。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        for (final (index, course) in courses.indexed) ...[
          _CourseCard(
            key: ValueKey(course.id),
            index: index,
            course: course,
            controller: controller,
          ),
          const SizedBox(height: 16),
        ],
        OutlinedButton.icon(
          key: const Key('add-import-course'),
          onPressed: controller.addCourse,
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加一门课'),
        ),
      ],
    );
  }
}

final class _CourseCard extends StatelessWidget {
  const _CourseCard({
    required this.index,
    required this.course,
    required this.controller,
    super.key,
  });

  final int index;
  final CourseDraft course;
  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) {
    final projects = controller.projectsFor(course.areaId);
    final projectValue = projects.any((item) => item.id == course.projectId)
        ? course.projectId
        : null;
    final span =
        course.weekSpans.firstOrNull ??
        const WeekSpan(startWeek: 1, endWeek: 16);
    return Card(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '课程 ${index + 1}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: Key('remove-import-course-${course.id}'),
                  tooltip: '删除这门课',
                  onPressed: () => controller.removeCourse(course.id),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _responsiveFields(context, [
              TextFormField(
                key: Key('course-name-${course.id}'),
                initialValue: course.name,
                decoration: const InputDecoration(labelText: '课程名称'),
                onChanged: (value) =>
                    controller.updateCourse(course.copyWith(name: value)),
              ),
              TextFormField(
                initialValue: course.teacher,
                decoration: const InputDecoration(labelText: '任课教师（可选）'),
                onChanged: (value) =>
                    controller.updateCourse(course.copyWith(teacher: value)),
              ),
              TextFormField(
                initialValue: course.location,
                decoration: const InputDecoration(labelText: '上课地点（可选）'),
                onChanged: (value) =>
                    controller.updateCourse(course.copyWith(location: value)),
              ),
            ]),
            const SizedBox(height: 14),
            _responsiveFields(context, [
              DropdownButtonFormField<int>(
                key: Key('course-weekday-${course.id}'),
                initialValue: course.weekday,
                decoration: const InputDecoration(labelText: '星期'),
                items: [
                  for (var day = 1; day <= 7; day++)
                    DropdownMenuItem(value: day, child: Text(_weekday(day))),
                ],
                onChanged: (value) =>
                    controller.updateCourse(course.copyWith(weekday: value)),
              ),
              DropdownButtonFormField<int>(
                initialValue: course.startPeriod,
                decoration: const InputDecoration(labelText: '开始节次'),
                items: [
                  for (var period = 1; period <= 24; period++)
                    DropdownMenuItem(value: period, child: Text('第 $period 节')),
                ],
                onChanged: (value) => controller.updateCourse(
                  course.copyWith(startPeriod: value),
                ),
              ),
              DropdownButtonFormField<int>(
                initialValue: course.endPeriod,
                decoration: const InputDecoration(labelText: '结束节次'),
                items: [
                  for (var period = 1; period <= 24; period++)
                    DropdownMenuItem(value: period, child: Text('第 $period 节')),
                ],
                onChanged: (value) =>
                    controller.updateCourse(course.copyWith(endPeriod: value)),
              ),
            ]),
            const SizedBox(height: 14),
            _responsiveFields(context, [
              DropdownButtonFormField<String>(
                key: Key('course-area-${course.id}'),
                initialValue: course.areaId,
                decoration: const InputDecoration(labelText: '领域'),
                items: [
                  for (final area in controller.areas)
                    DropdownMenuItem(value: area.id, child: Text(area.name)),
                ],
                onChanged: (value) => controller.updateCourse(
                  course.copyWith(areaId: value, projectId: null),
                ),
              ),
              DropdownButtonFormField<String?>(
                key: Key('course-project-${course.id}'),
                initialValue: projectValue,
                decoration: const InputDecoration(labelText: '项目（可选）'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('不归属项目'),
                  ),
                  for (final project in projects)
                    DropdownMenuItem<String?>(
                      value: project.id,
                      child: Text(project.name),
                    ),
                ],
                onChanged: (value) =>
                    controller.updateCourse(course.copyWith(projectId: value)),
              ),
            ]),
            const SizedBox(height: 14),
            _responsiveFields(context, [
              DropdownButtonFormField<int>(
                initialValue: span.startWeek,
                decoration: const InputDecoration(labelText: '开始周'),
                items: [
                  for (var week = 1; week <= 30; week++)
                    DropdownMenuItem(value: week, child: Text('第 $week 周')),
                ],
                onChanged: (value) {
                  if (value == null || value > span.endWeek) return;
                  controller.updateCourse(
                    course.copyWith(
                      weekSpans: [
                        WeekSpan(
                          startWeek: value,
                          endWeek: span.endWeek,
                          parity: span.parity,
                        ),
                      ],
                    ),
                  );
                },
              ),
              DropdownButtonFormField<int>(
                initialValue: span.endWeek,
                decoration: const InputDecoration(labelText: '结束周'),
                items: [
                  for (var week = 1; week <= 30; week++)
                    DropdownMenuItem(value: week, child: Text('第 $week 周')),
                ],
                onChanged: (value) {
                  if (value == null || value < span.startWeek) return;
                  controller.updateCourse(
                    course.copyWith(
                      weekSpans: [
                        WeekSpan(
                          startWeek: span.startWeek,
                          endWeek: value,
                          parity: span.parity,
                        ),
                      ],
                    ),
                  );
                },
              ),
              DropdownButtonFormField<WeekParity>(
                initialValue: span.parity,
                decoration: const InputDecoration(labelText: '周次规则'),
                items: const [
                  DropdownMenuItem(value: WeekParity.every, child: Text('每周')),
                  DropdownMenuItem(value: WeekParity.odd, child: Text('单周')),
                  DropdownMenuItem(value: WeekParity.even, child: Text('双周')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  controller.updateCourse(
                    course.copyWith(
                      weekSpans: [
                        WeekSpan(
                          startWeek: span.startWeek,
                          endWeek: span.endWeek,
                          parity: value,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ]),
            if (course.reviewReasons.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '需要检查：${course.reviewReasons.map(_reason).join('、')}',
                key: Key('course-review-${course.id}'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _responsiveFields(BuildContext context, List<Widget> fields) =>
      LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              children: [
                for (final field in fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: field,
                  ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final field in fields)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: field,
                  ),
                ),
            ],
          );
        },
      );

  static String _weekday(int day) =>
      const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][day - 1];

  static String _reason(TimetableReviewReason reason) => switch (reason) {
    TimetableReviewReason.missingName => '缺少课程名',
    TimetableReviewReason.missingWeeks => '缺少教学周',
    TimetableReviewReason.ambiguousWeekday => '上课日不确定',
    TimetableReviewReason.ambiguousPeriods => '节次不确定',
    TimetableReviewReason.invalidRange => '范围无效',
    TimetableReviewReason.unparsedText => '有文字未能解析',
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
