import 'package:flutter/material.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';

final class TimetablePreviewStep extends StatelessWidget {
  const TimetablePreviewStep({required this.controller, super.key});

  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) {
    final preview = controller.preview;
    if (controller.buildingPreview || preview == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(48),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final courseCount = preview.series
        .map((item) => item.courseId)
        .toSet()
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('预览并确认', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '尚未写入日历。请先查看数量、冲突和重复项，确认后将一次性导入。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Metric(label: '课程', value: '$courseCount 门'),
            _Metric(label: '重复系列', value: '${preview.series.length} 组'),
            _Metric(label: '具体课次', value: '${preview.occurrences.length} 次'),
            _Metric(
              label: '时间冲突',
              value: '${preview.conflicts.length} 项',
              warning: preview.conflicts.isNotEmpty,
            ),
            _Metric(
              label: '可能重复',
              value: '${preview.duplicates.length} 项',
              warning: preview.duplicates.isNotEmpty,
            ),
          ],
        ),
        if (preview.reviewReasons.isNotEmpty) ...[
          const SizedBox(height: 18),
          _Notice(
            title: '还有 ${preview.reviewReasons.length} 门课需要检查',
            detail: '请返回“校对课程”补全红色提示项，完成前不会写入日历。',
            error: true,
          ),
        ],
        if (preview.conflicts.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('时间冲突', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          for (final (index, conflict) in preview.conflicts.indexed)
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: ListTile(
                title: Text(
                  '第 ${conflict.imported.weekNumber} 周与「${conflict.existing.title}」冲突',
                ),
                subtitle: const Text('保留待处理，或跳过这门课的整个导入。'),
                trailing: DropdownButton<TimetableConflictChoice>(
                  value:
                      controller.conflictChoices[index] ??
                      TimetableConflictChoice.keepPending,
                  items: const [
                    DropdownMenuItem(
                      value: TimetableConflictChoice.keepPending,
                      child: Text('保留待处理'),
                    ),
                    DropdownMenuItem(
                      value: TimetableConflictChoice.excludeOccurrence,
                      child: Text('仅排除这次'),
                    ),
                    DropdownMenuItem(
                      value: TimetableConflictChoice.skipCourse,
                      child: Text('跳过整门课'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      controller.setConflictChoice(index, value);
                    }
                  },
                ),
              ),
            ),
        ],
        if (preview.duplicates.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('重复课程', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          for (final duplicate in preview.duplicates)
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: ListTile(
                title: Text(
                  duplicate.kind == TimetableDuplicateKind.exact
                      ? '发现完全相同的课程'
                      : '发现时间相同的已导入课程',
                ),
                subtitle: Text(
                  duplicate.kind == TimetableDuplicateKind.exact
                      ? '默认跳过，避免重复写入。'
                      : '默认保留现有课程；也可作为新课程导入。',
                ),
                trailing: DropdownButton<TimetableDuplicateResolution>(
                  value:
                      controller.duplicateChoices[duplicate.courseId] ??
                      duplicate.resolution,
                  items: const [
                    DropdownMenuItem(
                      value: TimetableDuplicateResolution.skip,
                      child: Text('跳过'),
                    ),
                    DropdownMenuItem(
                      value: TimetableDuplicateResolution.update,
                      child: Text('保留现有'),
                    ),
                    DropdownMenuItem(
                      value: TimetableDuplicateResolution.create,
                      child: Text('仍然新建'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      controller.setDuplicateChoice(duplicate.courseId, value);
                    }
                  },
                ),
              ),
            ),
        ],
        const SizedBox(height: 20),
        _Notice(
          title: '导入后将创建锁定课程',
          detail: '课程会作为固定日程占用时间，不会被自动排程移动。整批课程可后续撤销。',
          error: false,
        ),
      ],
    );
  }
}

final class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.warning = false,
  });
  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    width: 150,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: warning
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: warning
                ? Theme.of(context).colorScheme.onErrorContainer
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: warning
                ? Theme.of(context).colorScheme.onErrorContainer
                : null,
          ),
        ),
      ],
    ),
  );
}

final class _Notice extends StatelessWidget {
  const _Notice({
    required this.title,
    required this.detail,
    required this.error,
  });
  final String title;
  final String detail;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: error
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: error
                ? Theme.of(context).colorScheme.onErrorContainer
                : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          style: TextStyle(
            color: error
                ? Theme.of(context).colorScheme.onErrorContainer
                : Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ],
    ),
  );
}
