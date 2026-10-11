import 'package:flutter/material.dart';

import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';

/// 课程管理页（1.8.0，设计规范 §10.1）。
///
/// **为什么需要它**：导入课程已经保存成带 `logicalCourseId` 的重复日程，日视图也能改某一次、
/// 此后或整个系列。但产品**没有按学期列出的课程管理页**（§2.4），于是"我的课表里那门课
/// 时间错了"只能靠翻到某一天再点卡片去改——用户得先知道那门课在哪一天。
///
/// 这一页按学期列出逻辑课程，每门一行，点进去是详情。**数据全部来自只读端口**
/// （`CourseManagementService` → `CourseSeriesRepository`）：页面不认识 Drift。
final class CourseManagementPage extends StatefulWidget {
  const CourseManagementPage({
    required this.service,
    this.onOpenCourse,
    this.onImportTimetable,
    super.key,
  });

  final CourseManagementService service;

  /// 打开某门课的详情。为空时不显示该入口——不给一个点了没反应的箭头。
  final void Function(String logicalCourseId)? onOpenCourse;

  /// 无课程时的"去导入课表"入口。为空时不显示。
  final VoidCallback? onImportTimetable;

  @override
  State<CourseManagementPage> createState() => _CourseManagementPageState();
}

final class _CourseManagementPageState extends State<CourseManagementPage> {
  List<CourseSeriesSummary>? _courses;
  List<_TermOption> _terms = const [];
  String? _selectedTermId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final current = await widget.service.currentTermId();
      final courses = await widget.service.listCourses(termId: current);
      if (!mounted) return;
      setState(() {
        _selectedTermId = current;
        _courses = courses;
        _error = null;
        // 学期下拉的选项来自**已经列出的课程**：不额外查一次学期表，
        // 因为本页只关心"哪些学期有课"。
        //
        // **必须按 id 去重**：一门课一行的数据源里，同一学期会出现 N 次；直接把每门课
        // 都变成一个 `DropdownMenuItem` 会让同一个 value 出现多次，而
        // `DropdownButton` 的断言要求 value 恰好命中一项——**同一学期有两门课就当场崩**
        // （这不是猜想：本文件的第二条用例就是这么发现它的）。
        final seenTerms = <String>{};
        _terms = [
          for (final course in courses)
            if (course.termId case final id?)
              if (seenTerms.add(id))
                _TermOption(id: id, label: id == current ? '当前学期' : id),
        ];
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '读取课程失败：$error');
    }
  }

  Future<void> _selectTerm(String? termId) async {
    setState(() => _selectedTermId = termId);
    final courses = await widget.service.listCourses(termId: termId);
    if (!mounted) return;
    setState(() => _courses = courses);
  }

  @override
  Widget build(BuildContext context) {
    final courses = _courses;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '管理课程',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (_terms.isNotEmpty)
                DropdownButton<String?>(
                  key: const Key('course-term'),
                  value: _selectedTermId,
                  onChanged: _selectTerm,
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('全部学期'),
                    ),
                    for (final term in _terms)
                      DropdownMenuItem<String?>(
                        value: term.id,
                        child: Text(term.label),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_error case final message?)
            Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else if (courses == null)
            const Center(child: CircularProgressIndicator())
          else if (courses.isEmpty)
            // 空状态要说清"空"是什么意思，并给出下一步。
            Column(
              key: const Key('course-empty'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('这个学期还没有课程。'),
                const SizedBox(height: 8),
                if (widget.onImportTimetable case final onImport?)
                  FilledButton.icon(
                    key: const Key('course-empty-import'),
                    onPressed: onImport,
                    icon: const Icon(Icons.upload_file_outlined),
                    label: const Text('导入课表'),
                  ),
              ],
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: courses.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) => _CourseTile(
                  course: courses[index],
                  onOpen: widget.onOpenCourse,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _TermOption {
  const _TermOption({required this.id, required this.label});
  final String id;
  final String label;
}

final class _CourseTile extends StatelessWidget {
  const _CourseTile({required this.course, this.onOpen});

  final CourseSeriesSummary course;
  final void Function(String logicalCourseId)? onOpen;

  /// 「周一 08:00–08:45 · 1-16 周单周 · D206 · 赵敏」这样的单行摘要。
  String get _summary {
    final weekday = const [
      '一',
      '二',
      '三',
      '四',
      '五',
      '六',
      '日',
    ][course.weekday - 1];
    final start = _hhmm(course.startMinute);
    final end = _hhmm(course.endMinute);
    final weeks = course.weekSpans
        .map(
          (span) =>
              '${span.startWeek}-${span.endWeek} 周${_parityLabel(span.parity)}',
        )
        .join('、');
    return [
      '周$weekday $start–$end',
      if (weeks.isNotEmpty) weeks,
      if (course.location.isNotEmpty) course.location,
      if (course.teacher.isNotEmpty) course.teacher,
    ].join(' · ');
  }

  static String _hhmm(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';

  static String _parityLabel(WeekParity parity) => switch (parity) {
    WeekParity.every => '',
    WeekParity.odd => '单',
    WeekParity.even => '双',
  };

  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('course-${course.logicalCourseId}'),
    title: Text(course.title),
    subtitle: Text(_summary),
    // **深链带的是 `logicalCourseId`，不是标题**：两个班的同名课因此不会打开错项。
    trailing: onOpen == null
        ? null
        : IconButton(
            key: Key('manage-course-${course.logicalCourseId}'),
            tooltip: '管理这门课',
            onPressed: () => onOpen!(course.logicalCourseId),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
    onTap: onOpen == null ? null : () => onOpen!(course.logicalCourseId),
  );
}
