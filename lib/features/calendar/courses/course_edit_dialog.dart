import 'package:flutter/material.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_date_time_fields.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';

/// 改一门课的时间，**并在保存前看到冲突**（设计规范 §10.2 末条）。
///
/// 规范原文："修改课程时间、周次、地点或归属后必须重新检测冲突并预览。"
/// 计划 Task 10 Step 3："修改时间后先显示冲突，再允许返回修改；**硬冲突不能直接保存**。"
///
/// 这个文件在计划里是**声明的交付物**（Task 10 的 `Create:` 一栏），此前不存在，
/// 于是 §10.2 那一条在界面上不成立——`previewTimeChange` 与
/// `detectCourseTimeConflicts` 早就有了，缺的只是入口。
///
/// **一期只做时间**：周次、地点、归属的编辑各自还需要新的草稿字段与校验，
/// 与"先让冲突预览落地"是两件事。对话框的冲突预览这一层是三者共用的，
/// 因此先把这条链路接通、并把范围写清楚，比一次做完四样更可验证。
///
/// 流程是**两步**而不是一步：先"预览冲突"，看到结果后才出现"保存"。
/// 一步到位会让用户在完全不知情的情况下覆盖保护时间。
Future<CourseTimeChange?> showCourseEditDialog(
  BuildContext context, {
  required CourseManagementService service,
  required CourseSeriesSummary summary,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) => showDialog<CourseTimeChange>(
  context: context,
  builder: (context) => CourseEditDialog(
    service: service,
    summary: summary,
    zones: zones,
    timeZoneId: timeZoneId,
  ),
);

/// 用户确认后的改动：**只表达钟点**，不表达日期。
///
/// 日期由服务层按每一段自己的星期映射（`_mapToSegmentDay`）。
/// 让界面交出具体日期会把"每一段保留自己的星期"这条语义丢掉——
/// 而那正是本批次修掉的一个真实缺陷（一门周一+周四的课被压成两段都在周一）。
final class CourseTimeChange {
  const CourseTimeChange({required this.start, required this.end});

  final TimeOfDay start;
  final TimeOfDay end;

  int get startMinute => start.hour * 60 + start.minute;
  int get endMinute => end.hour * 60 + end.minute;
}

final class CourseEditDialog extends StatefulWidget {
  const CourseEditDialog({
    required this.service,
    required this.summary,
    required this.zones,
    required this.timeZoneId,
    super.key,
  });

  final CourseManagementService service;
  final CourseSeriesSummary summary;

  /// 提议时段必须按**事项自己的时区**换算成 UTC 时刻。
  ///
  /// 不传时区、直接用 `DateTime.utc(baseDay).add(Duration(minutes: 本地钟点))`
  /// 会把本地钟点当成 UTC 钟点，于是"周一 08:00"在提议里变成 `08:00Z`，
  /// 而库里那条占用是 `00:00Z`——**两者永远不重叠，冲突检测形同虚设**。
  /// 这与规范 §4.1 点名的那类二次换算缺陷是同一个形状。
  final TimeZoneDatabase zones;
  final String timeZoneId;

  @override
  State<CourseEditDialog> createState() => _CourseEditDialogState();
}

final class _CourseEditDialogState extends State<CourseEditDialog> {
  late TimeOfDay _start;
  late TimeOfDay _end;

  /// 已经"预览过"的钟点。相同时不重复请求；改动后冲突列表立刻作废。
  ({int startMinute, int endMinute})? _previewedFor;
  List<CourseTimeConflict>? _conflicts;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start = TimeOfDay(
      hour: widget.summary.startMinute ~/ 60,
      minute: widget.summary.startMinute % 60,
    );
    _end = TimeOfDay(
      hour: widget.summary.endMinute ~/ 60,
      minute: widget.summary.endMinute % 60,
    );
  }

  bool get _endAfterStart => _endMinute > _startMinute;

  int get _startMinute => _start.hour * 60 + _start.minute;
  int get _endMinute => _end.hour * 60 + _end.minute;

  /// 已经预览过、且预览的就是当前钟点。
  bool get _isPreviewed =>
      _previewedFor != null &&
      _previewedFor!.startMinute == _startMinute &&
      _previewedFor!.endMinute == _endMinute;

  bool get _hasBlockingConflict =>
      (_conflicts ?? const []).any(isBlockingCourseTimeConflict);

  /// 改钟点时作废上一次预览。
  ///
  /// **这是安全属性而不是界面细节**：不作废的话，用户"预览 → 看到没有冲突 →
  /// 改成会撞保护时间的新钟点 → 直接按保存"就能带着旧结论保存新时间。
  void _changeTime({TimeOfDay? start, TimeOfDay? end}) {
    setState(() {
      if (start != null) _start = start;
      if (end != null) _end = end;
      _previewedFor = null;
      _conflicts = null;
      _error = null;
    });
  }

  Future<void> _preview() async {
    if (!_endAfterStart) {
      setState(() => _error = '结束时间必须晚于开始时间');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final detail = await widget.service.findCourse(
      widget.summary.logicalCourseId,
    );
    final conflicts = <CourseTimeConflict>[];
    if (detail != null) {
      // 提议时段 = "该片段自己那一周的星期几 + 新钟点"，按**事项时区**换算成 UTC。
      //
      // **不能**用 `baseUtc.add(Duration(minutes: 本地钟点))`：那会把本地钟点当成
      // UTC 钟点，于是东八区一门周一 08:00 的课在提议里变成 `08:00Z`，而库里那条占用
      // 是 `00:00Z` —— 两者永不重叠，冲突检测**看起来在工作、实际从不命中**。
      // 这与规范 §4.1 点名的那类二次换算缺陷是同一个形状。
      //
      // 基准取本地 2026-01-05（周一），于是 `weekday == monday` 落在同一天。
      final baseLocalDate = DateTime(2026, 1, 5);
      final proposed = <({String eventId, TimeRange range})>[
        for (final segment in detail.segments)
          (
            eventId: segment.eventId,
            range: _proposedRangeFor(
              baseLocalDate: baseLocalDate,
              weekday: segment.weekday,
            ),
          ),
      ];
      conflicts.addAll(
        await widget.service.previewTimeChange(
          logicalCourseId: widget.summary.logicalCourseId,
          proposed: proposed,
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _conflicts = conflicts;
      _previewedFor = (startMinute: _startMinute, endMinute: _endMinute);
    });
  }

  /// 把"基准周一 + 目标星期 + 当前钟点"按**事项时区**换算成 UTC 区间。
  ///
  /// 日期用**日历加法**（`DateTime(y, m, d + n)`）而不是 `add(Duration(days: n))`：
  /// 后者在夏令时切换日会漂一小时，与 `deferNotBeforeUtc` 是同一条理由。
  TimeRange _proposedRangeFor({
    required DateTime baseLocalDate,
    required int weekday,
  }) {
    final date = DateTime(
      baseLocalDate.year,
      baseLocalDate.month,
      baseLocalDate.day + (weekday - DateTime.monday),
    );
    return TimeRange(
      startUtc: widget.zones.localDateTimeToUtc(
        date,
        _startMinute,
        widget.timeZoneId,
      ),
      endUtc: widget.zones.localDateTimeToUtc(
        date,
        _endMinute,
        widget.timeZoneId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = _conflicts;
    return AlertDialog(
      title: const Text('改课程时间'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.summary.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text('改的是一门课在当前学期的全部片段；每段保留自己的星期。'),
            const SizedBox(height: 16),
            PlannerTimeField(
              value: _start,
              label: '开始时间',
              enabled: !_busy,
              onChanged: (value) => _changeTime(start: value),
              boxKey: const Key('course-edit-start-box'),
            ),
            const SizedBox(height: 12),
            PlannerTimeField(
              value: _end,
              label: '结束时间',
              enabled: !_busy,
              errorText: _endAfterStart ? null : '结束时间必须晚于开始时间',
              onChanged: (value) => _changeTime(end: value),
              boxKey: const Key('course-edit-end-box'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const Key('course-edit-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (conflicts != null && _isPreviewed) ...[
              const SizedBox(height: 16),
              _ConflictList(conflicts: conflicts),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('course-edit-cancel'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        // **两步**：先预览，看到冲突后才出现保存。
        if (!_isPreviewed)
          FilledButton(
            key: const Key('course-edit-preview'),
            onPressed: (_busy || !_endAfterStart) ? null : _preview,
            child: Text(_busy ? '检测中…' : '预览冲突'),
          )
        else
          FilledButton(
            key: const Key('course-edit-save'),
            // **硬冲突不能直接保存**：保存按钮直接不可用，而不是"点了再弹一次提示"。
            onPressed: _hasBlockingConflict
                ? null
                : () => Navigator.pop(
                    context,
                    CourseTimeChange(start: _start, end: _end),
                  ),
            child: const Text('保存'),
          ),
      ],
    );
  }
}

final class _ConflictList extends StatelessWidget {
  const _ConflictList({required this.conflicts});

  final List<CourseTimeConflict> conflicts;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        conflicts.isEmpty ? '没有检测到冲突。' : '检测到 ${conflicts.length} 处冲突：',
        key: const Key('course-edit-conflict-summary'),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      for (final conflict in conflicts)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '· ${_label(conflict)}',
            key: Key('course-edit-conflict-${conflict.otherEventId}'),
            style: TextStyle(
              color: isBlockingCourseTimeConflict(conflict)
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        ),
      if (conflicts.any(isBlockingCourseTimeConflict))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            '有硬冲突，请先改时间或调整那些安排。',
            key: const Key('course-edit-blocking-hint'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );

  /// **标题而不是 id**（规范全局不变量第 7 条）：用户要做的是去改那一项，
  /// 而他认不出 uuid。
  static String _label(CourseTimeConflict conflict) {
    final kind = switch (conflict.kind) {
      CourseTimeConflictKind.fixedEvent => '撞上固定日程',
      CourseTimeConflictKind.protectedTime => '撞上保护时间',
      CourseTimeConflictKind.sameCourse => '与这门课自己的另一段重叠',
      CourseTimeConflictKind.otherCourse => '撞上另一门课',
    };
    return '$kind：${conflict.title}';
  }
}
