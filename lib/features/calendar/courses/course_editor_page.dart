import 'package:flutter/material.dart';

import 'package:personal_planner/application/course_management_service.dart';

/// 整门课程资料的编辑页（课程与保护时间管理修复计划 Task 5）。
///
/// **为什么单独一页，而不是在详情页加几个输入框**：详情页要同时承担"看这门课"
/// 与"改这门课"，而两者的作用范围根本不同——
///
/// - 名称、教师、地点、领域、项目、星期、周次是**整门课的属性**，
///   "只改这一次的名称"在数据上根本没有对应物；
/// - "这次／此次及以后／整个上课序列"说的是**改多少次**，它必须知道一次课的真实
///   发生时间，因此只能从日历上的那一节进入（计划 §2.2）。
///
/// 把两者塞进同一页就会出现"选了『仅本次』却改了整门课"这种说了但没做的状态
/// （计划 §1.1 记录的实际偏差）。这一页只做前一半。
///
/// **当前状态：Task 1 的占位**。Task 5 会把它补成完整表单（资料区 + 安排区 +
/// 冲突预览）。这里先保证路由与深链存在，好让 Task 1 的失败测试**因为行为缺失**
/// 而红，而不是因为编译不过。
final class CourseEditorPage extends StatelessWidget {
  const CourseEditorPage({
    required this.service,
    required this.logicalCourseId,
    this.onSaved,
    this.onCancel,
    super.key,
  });

  final CourseManagementService service;
  final String logicalCourseId;
  final VoidCallback? onSaved;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: service.findCourse(logicalCourseId),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final detail = snapshot.data;
      if (detail == null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '课程已删除或链接过期，找不到这门课程。',
                key: Key('course-editor-missing'),
                textAlign: TextAlign.center,
              ),
              if (onCancel != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('course-editor-back'),
                  onPressed: onCancel,
                  child: const Text('返回课程列表'),
                ),
              ],
            ],
          ),
        );
      }
      return Padding(
        key: const Key('course-editor-page'),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '编辑「${detail.summary.title}」',
              key: const Key('course-editor-title'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      );
    },
  );
}
