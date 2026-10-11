import 'package:flutter/material.dart';

import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/features/calendar/courses/course_edit_dialog.dart';

/// 一门课的详情与改写入口（1.8.0，设计规范 §10.1／§10.2）。
///
/// **范围选择是三选一，不是复选框**：规范 §10.2 的"仅本次／此次及以后／整个课程"是
/// **互斥**的作用范围，选了两个就等于没有说明白要改多少。用 `SegmentedButton` 表达互斥。
///
/// **删除必须二次确认，且确认框里要有课程名与次数**（规范 §10.2 第六条）：
/// "确定要删除吗"没有告诉用户他将失去什么，而删除不可逆。
final class CourseDetailPage extends StatefulWidget {
  const CourseDetailPage({
    required this.service,
    required this.logicalCourseId,
    this.onDeleted,
    this.onCancel,
    this.zones,
    this.timeZoneId,
    super.key,
  });

  final CourseManagementService service;
  final String logicalCourseId;
  final VoidCallback? onDeleted;
  final VoidCallback? onCancel;

  /// 改时间对话框要用它把"本地钟点"换算成 UTC 提议时段（规范 §10.2 末条）。
  /// 为空时不显示「改时间」入口——**不给点了没反应的按钮**。
  final TimeZoneDatabase? zones;
  final String? timeZoneId;

  @override
  State<CourseDetailPage> createState() => _CourseDetailPageState();
}

final class _CourseDetailPageState extends State<CourseDetailPage> {
  CourseSeriesDetail? _detail;
  CourseDeletionPreview? _preview;
  CourseEditScope _scope = CourseEditScope.entireCourse;
  String? _status;
  bool _busy = false;

  /// 读取是否**已经跑完**。
  ///
  /// **不能拿 `_detail == null` 当"还在加载"**：课程不存在时它同样是 `null`，
  /// 于是页面会**永远转圈**，既不报错也不给返回入口。
  /// 深链 `/calendar/courses/<不存在的 id>`（旧链接、或那门课刚被删）就会撞上这个状态。
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final detail = await widget.service.findCourse(widget.logicalCourseId);
    final preview = await widget.service.previewDelete(widget.logicalCourseId);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _preview = preview;
      _loaded = true;
    });
  }

  Future<void> _run(Future<CourseCommandResult> Function() command) async {
    setState(() => _busy = true);
    final result = await command();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result.isSuccess ? '已保存' : result.error;
    });
    if (result.isSuccess) await _load();
  }

  Future<void> _delete() async {
    final preview = _preview;
    final detail = _detail;
    if (preview == null || detail == null) return;
    // **二次确认，且写清课程名与次数**。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('course-delete-dialog'),
        title: Text('删除「${preview.title}」？'),
        content: Text(
          '会删除本学期的 ${preview.affectedSeriesCount} 个系列片段，'
          '共 ${preview.affectedOccurrenceCount} 次课。这一步无法撤销。',
        ),
        actions: [
          TextButton(
            key: const Key('course-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('course-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final result = await widget.service.deleteCourse(widget.logicalCourseId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result.isSuccess ? '课程已删除' : result.error;
    });
    if (result.isSuccess) widget.onDeleted?.call();
  }

  Future<void> _pause() async {
    final now = DateTime.now();
    await _run(
      () => widget.service.pauseFrom(
        logicalCourseId: widget.logicalCourseId,
        // **从今天起停**：用户点"暂停"时想的是"以后别排了"，而不是"从某个我还没选的日期"。
        fromLocalDate: DateTime(now.year, now.month, now.day),
      ),
    );
  }

  /// 改整个课程的时间：**先弹冲突预览，确认后才写**（规范 §10.2 末条）。
  ///
  /// 顺序是刻意的：对话框内部就是"预览冲突 → 出现保存"，因此这里拿到
  /// [CourseTimeChange] 时用户**已经看过冲突**；硬冲突时对话框不会返回结果。
  Future<void> _editTime() async {
    final detail = _detail;
    final zones = widget.zones;
    final timeZoneId = widget.timeZoneId;
    if (detail == null || zones == null || timeZoneId == null) return;

    final choice = await showCourseEditDialog(
      context,
      service: widget.service,
      summary: detail.summary,
      zones: zones,
      timeZoneId: timeZoneId,
    );
    if (choice == null || !mounted) return;

    // 把钟点换算成 UTC：**用第一段自己的星期**作为日期载体。服务层会按
    // 每一段自己的星期重新映射（`_mapToSegmentDay`），因此这里给的日期只决定钟点。
    final first = detail.segments.first;
    final baseLocalDate = DateTime(2026, 1, 5);
    final date = DateTime(
      baseLocalDate.year,
      baseLocalDate.month,
      baseLocalDate.day + (first.weekday - DateTime.monday),
    );

    await _run(
      () => widget.service.editWholeCourse(
        logicalCourseId: widget.logicalCourseId,
        newStartUtc: zones.localDateTimeToUtc(
          date,
          choice.startMinute,
          timeZoneId,
        ),
        newEndUtc: zones.localDateTimeToUtc(date, choice.endMinute, timeZoneId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final preview = _preview;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.onCancel != null)
                IconButton(
                  key: const Key('course-detail-back'),
                  tooltip: '返回',
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              Expanded(
                child: Text(
                  detail?.summary.title ?? '课程',
                  key: const Key('course-detail-title'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // **读完了却没有这门课**要给一句说明，而不是继续转圈。
          // 用 `_loaded` 而不是 `detail == null` 判断"还在加载"——见字段注释。
          if (!_loaded)
            const Center(child: CircularProgressIndicator())
          else if (detail == null)
            Center(
              child: Text(
                '找不到这门课程。它可能已被删除，或链接已过期。',
                key: const Key('course-detail-missing'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else ...[
            Text(
              '共 ${detail.segments.length} 个系列片段',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            // 规范 §10.1 把**教师**列为本页要展示的字段之一。它一直存在
            // （`CourseSeriesSummary.teacher` 来自课表导入写进 `notes` 的名字），
            // 但此前只有管理列表显示它，**详情页从来不显示**——而详情页正是用户
            // 点进来"确认这是哪门课、谁教的"的地方。
            if (detail.summary.teacher.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '教师：${detail.summary.teacher}',
                key: const Key('course-detail-teacher'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (detail.summary.location.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '地点：${detail.summary.location}',
                key: const Key('course-detail-location'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final segment in detail.segments)
                    ListTile(
                      key: Key('course-segment-${segment.eventId}'),
                      leading: const Icon(Icons.event_outlined),
                      title: Text(
                        '周${segment.weekday} ${_hhmm(segment.startMinute)}',
                      ),
                      subtitle: Text(
                        '${_hhmm(segment.startMinute)}–${_hhmm(segment.endMinute)}'
                        '${segment.intervalWeeks > 1 ? ' · 每 ${segment.intervalWeeks} 周' : ''}'
                        '${segment.location.isEmpty ? '' : ' · ${segment.location}'}',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<CourseEditScope>(
              key: const Key('course-edit-scope'),
              segments: const [
                ButtonSegment(
                  value: CourseEditScope.thisOccurrence,
                  label: Text('仅本次'),
                ),
                ButtonSegment(
                  value: CourseEditScope.followingOccurrences,
                  label: Text('此次及以后'),
                ),
                ButtonSegment(
                  value: CourseEditScope.entireCourse,
                  label: Text('整个课程'),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (selection) =>
                  setState(() => _scope = selection.single),
            ),
            const SizedBox(height: 8),
            Text(switch (_scope) {
              CourseEditScope.thisOccurrence => '只改这一次课，其余各次保持原样。',
              CourseEditScope.followingOccurrences => '把这一次及其之后的课换到新时间。',
              CourseEditScope.entireCourse =>
                '改这门课在当前学期的全部 ${detail.segments.length} 个系列片段。',
            }, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                // 「改时间」（1.8.0，规范 §10.2 末条）：**保存前先看冲突**。
                // 未装配时区时不给这个入口——对话框无法把本地钟点换算成提议时段，
                // 而"检测不到冲突"比"没有这个按钮"更糟。
                if (widget.zones != null && widget.timeZoneId != null)
                  OutlinedButton.icon(
                    key: const Key('course-edit-time'),
                    onPressed: _busy ? null : _editTime,
                    icon: const Icon(Icons.schedule_outlined),
                    label: const Text('改时间'),
                  ),
                OutlinedButton.icon(
                  key: const Key('course-pause'),
                  onPressed: _busy ? null : _pause,
                  icon: const Icon(Icons.pause_circle_outline),
                  label: const Text('暂停课程'),
                ),
                OutlinedButton.icon(
                  key: const Key('course-delete'),
                  onPressed: _busy || preview == null ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除课程'),
                ),
              ],
            ),
            if (preview case final value?) ...[
              const SizedBox(height: 8),
              Text(
                '删除会影响 ${value.affectedSeriesCount} 个片段、'
                '共 ${value.affectedOccurrenceCount} 次课。',
                key: const Key('course-delete-preview'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
          if (_status case final status?) ...[
            const SizedBox(height: 8),
            Text(status),
          ],
        ],
      ),
    );
  }

  static String _hhmm(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';
}
