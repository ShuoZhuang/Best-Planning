import 'dart:io';

import 'package:flutter/material.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';

final class TimetableUploadStep extends StatelessWidget {
  const TimetableUploadStep({required this.controller, super.key});

  final TimetableImportController controller;

  @override
  Widget build(BuildContext context) {
    final path = controller.selectedImagePath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('上传课表', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '选择学校课表截图。图片只在本机识别，不会上传，也不会存入数据库。',
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(
                  Icons.document_scanner_outlined,
                  size: 44,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  path == null ? '尚未选择图片' : path.split(RegExp(r'[\\/]')).last,
                  key: const Key('selected-image-name'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (path != null) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: 220,
                      width: double.infinity,
                      child: ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLowest,
                        child: RotatedBox(
                          quarterTurns: controller.quarterTurns,
                          child: Image.file(
                            File(path),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const Center(child: Text('预览不可用，仍可尝试本地识别')),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('rotate-timetable-left'),
                        onPressed: controller.rotateLeft,
                        icon: const Icon(Icons.rotate_left_rounded),
                        label: const Text('左旋转'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('rotate-timetable-right'),
                        onPressed: controller.rotateRight,
                        icon: const Icon(Icons.rotate_right_rounded),
                        label: const Text('右旋转'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('crop-timetable-image'),
                        onPressed: () => _showCropDialog(context),
                        icon: const Icon(Icons.crop_rounded),
                        label: Text(
                          controller.cropRect == null ? '裁剪识别区域' : '修改裁剪区域',
                        ),
                      ),
                      if (controller.cropRect != null)
                        TextButton(
                          onPressed: controller.clearCrop,
                          child: const Text('恢复全图'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '调整后请点“重新识别”，已编辑内容不会在后台被覆盖。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('pick-timetable-image'),
                  onPressed: controller.recognizing
                      ? null
                      : controller.pickAndRecognize,
                  icon: controller.recognizing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(
                    controller.recognizing
                        ? '本地识别中…'
                        : path == null
                        ? '选择课表图片'
                        : '更换并重新识别',
                  ),
                ),
                if (path != null && !controller.recognizing) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('retry-timetable-ocr'),
                    onPressed: controller.recognizeSelected,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重新识别'),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (controller.errorMessage != null) ...[
          const SizedBox(height: 16),
          _InlineMessage(message: controller.errorMessage!),
          // M6（§10「错误恢复」）：**与图片有关的失败**要能"就地换图"。
          //
          // 为什么是在这里而不是只靠上方那个通用选择按钮：§10 要求"图片读取失败时能换图"。
          // 用户读完失败原因之后，下一步动作必须在**同一处**，否则他还要回头去找按钮。
          //
          // 为什么只对这两种失败显示：换一张图**解决不了**"本机没装中文 OCR"或
          // "设备不支持本地识别"——给了反而把用户引到错的方向。
          if (controller.ocrFailureCode ==
                  TimetableOcrFailureCode.decodeFailed ||
              controller.ocrFailureCode ==
                  TimetableOcrFailureCode.imageTooLarge) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('timetable-change-image'),
              onPressed: controller.recognizing
                  ? null
                  : () => controller.pickAndRecognize(),
              icon: const Icon(Icons.image_outlined),
              label: const Text('更换图片'),
            ),
          ],
        ],
        if (controller.ocrFailureCode != null || controller.draft == null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('manual-timetable-entry'),
            onPressed: controller.startManualEntry,
            icon: const Icon(Icons.edit_calendar_outlined),
            label: const Text('不使用识别，手动录入课程'),
          ),
        ],
        if (controller.draft != null) ...[
          const SizedBox(height: 16),
          Text(
            '已获取 ${controller.draft!.courses.length} 门课程，下一步可以逐条校对。',
            key: const Key('recognized-course-count'),
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ],
    );
  }

  Future<void> _showCropDialog(BuildContext context) async {
    final current = controller.cropRect;
    var left = current?.left ?? 0.0;
    var top = current?.top ?? 0.0;
    var right = current == null ? 0.0 : 1 - current.left - current.width;
    var bottom = current == null ? 0.0 : 1 - current.top - current.height;
    final result = await showDialog<(double, double, double, double)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('裁剪识别区域'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('拖动四个边缘的留白比例，去掉手机状态栏、底部导航或课表外的内容。'),
                _CropSlider(
                  label: '左边',
                  value: left,
                  onChanged: (value) => setState(() => left = value),
                ),
                _CropSlider(
                  label: '上边',
                  value: top,
                  onChanged: (value) => setState(() => top = value),
                ),
                _CropSlider(
                  label: '右边',
                  value: right,
                  onChanged: (value) => setState(() => right = value),
                ),
                _CropSlider(
                  label: '下边',
                  value: bottom,
                  onChanged: (value) => setState(() => bottom = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: left + right >= .9 || top + bottom >= .9
                  ? null
                  : () => Navigator.pop(context, (left, top, right, bottom)),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    controller.setCropInsets(
      left: result.$1,
      top: result.$2,
      right: result.$3,
      bottom: result.$4,
    );
  }
}

final class _CropSlider extends StatelessWidget {
  const _CropSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 48, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(0, .4),
          max: .4,
          divisions: 20,
          label: '${(value * 100).round()}%',
          onChanged: onChanged,
        ),
      ),
      SizedBox(width: 44, child: Text('${(value * 100).round()}%')),
    ],
  );
}

final class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ],
    ),
  );
}
