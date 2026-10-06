import 'package:flutter/material.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/features/calendar/timetable_import/period_step.dart';
import 'package:personal_planner/features/calendar/timetable_import/preview_step.dart';
import 'package:personal_planner/features/calendar/timetable_import/review_step.dart';
import 'package:personal_planner/features/calendar/timetable_import/term_step.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';
import 'package:personal_planner/features/calendar/timetable_import/upload_step.dart';

final class TimetableImportPage extends StatefulWidget {
  const TimetableImportPage({
    required this.controller,
    required this.onCancel,
    required this.onCompleted,
    super.key,
  });

  final TimetableImportController controller;
  final VoidCallback onCancel;
  final ValueChanged<TimetableImportBatch> onCompleted;

  @override
  State<TimetableImportPage> createState() => _TimetableImportPageState();
}

final class _TimetableImportPageState extends State<TimetableImportPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialize();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const Key('timetable-import-back'),
            tooltip: controller.step == TimetableWizardStep.upload
                ? '返回日历'
                : '上一步',
            onPressed: controller.step == TimetableWizardStep.upload
                ? widget.onCancel
                : controller.back,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: const Text('导入课表'),
        ),
        body: controller.initializing
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _ProgressHeader(step: controller.step),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 120),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1040),
                          child: _step(controller),
                        ),
                      ),
                    ),
                  ),
                  if (controller.errorMessage != null &&
                      controller.step != TimetableWizardStep.upload)
                    Container(
                      key: const Key('timetable-import-error'),
                      margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              controller.errorMessage!,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  _Footer(
                    controller: controller,
                    onCancel: widget.onCancel,
                    onCommit: () => _commit(context),
                  ),
                ],
              ),
      );
    },
  );

  Widget _step(
    TimetableImportController controller,
  ) => switch (controller.step) {
    TimetableWizardStep.upload => TimetableUploadStep(controller: controller),
    TimetableWizardStep.review => TimetableReviewStep(controller: controller),
    TimetableWizardStep.term => TimetableTermStep(controller: controller),
    TimetableWizardStep.periods => TimetablePeriodStep(controller: controller),
    TimetableWizardStep.preview => TimetablePreviewStep(controller: controller),
  };

  Future<void> _commit(BuildContext context) async {
    final batch = await widget.controller.commit();
    if (!mounted || batch == null) return;
    widget.onCompleted(batch);
  }
}

final class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({required this.step});
  final TimetableWizardStep step;

  static const labels = ['上传', '校对', '学期', '节次', '预览'];

  @override
  Widget build(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Row(
          children: [
            for (var index = 0; index < labels.length; index++) ...[
              Expanded(
                child: Semantics(
                  selected: index == step.index,
                  label: '第 ${index + 1} 步，${labels[index]}',
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: index <= step.index
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                          shape: BoxShape.circle,
                        ),
                        child: index < step.index
                            ? Icon(
                                Icons.check_rounded,
                                size: 17,
                                color: Theme.of(context).colorScheme.onPrimary,
                              )
                            : Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: index == step.index
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                ),
                              ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        labels[index],
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
              ),
              if (index < labels.length - 1)
                Expanded(
                  child: Divider(
                    color: index < step.index
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

final class _Footer extends StatelessWidget {
  const _Footer({
    required this.controller,
    required this.onCancel,
    required this.onCommit,
  });
  final TimetableImportController controller;
  final VoidCallback onCancel;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    elevation: 4,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            TextButton(onPressed: onCancel, child: const Text('取消')),
            const Spacer(),
            if (controller.step != TimetableWizardStep.upload) ...[
              OutlinedButton.icon(
                key: const Key('wizard-previous'),
                onPressed: controller.back,
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('上一步'),
              ),
              const SizedBox(width: 12),
            ],
            if (controller.step == TimetableWizardStep.preview)
              FilledButton.icon(
                key: const Key('commit-timetable-import'),
                onPressed: controller.canCommit ? onCommit : null,
                icon: controller.committing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(controller.committing ? '正在导入…' : '确认导入'),
              )
            else
              FilledButton.icon(
                key: const Key('wizard-next'),
                onPressed: controller.canContinue ? controller.next : null,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(
                  controller.step == TimetableWizardStep.periods
                      ? '生成预览'
                      : '下一步',
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
