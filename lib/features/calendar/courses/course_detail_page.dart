import 'package:flutter/material.dart';

import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/domain/models/course_series.dart';

/// 一门课的详情与改写入口（1.8.0，设计规范 §10.1／§10.2）。
///
/// **范围选择是三选一，不是复选框**：规范 §10.2 的"仅本次／此次及以后／整个课程"是
/// **互斥**的作用范围，选了两个就等于没有说明白要改多少。用 `SegmentedButton` 表达互斥。
///
/// **删除必须二次确认，且确认框里要有课程名与次数**（规范 §10.2 第六条）：
/// "确定要删除吗"没有告诉用户他将失去什么，而删除不可逆。
///
/// ## 本轮（计划 §2.0）只保留一个整门课程入口
///
/// 这一页此前有**两个**指向整门课程的按钮：「编辑课程」（走课程快照事务）与「改时间」
/// （走 `CalendarService.replaceSeries` 的逐片段循环）。后者只提交时间，标题与时区由
/// 两张进程内缓存补齐，缓存里没有就写 `未命名事项` 与 `UTC`——用户只改一次钟点，
/// 课程名、教师、地点、领域、项目就都没了。
///
/// 现在「改时间」已被删除，钟点编辑并入「编辑课程」：那里保存走
/// `previewCourseEdit()` → `saveCourse()` → `CourseWriteGateway.replaceCourseSeries()`
/// 的**单事务**链路，整门课的资料与安排一次提交。
final class CourseDetailPage extends StatefulWidget {
  const CourseDetailPage({
    required this.service,
    required this.logicalCourseId,
    this.onDeleted,
    this.onCancel,
    this.onEditCourse,
    this.onRestoreFromTimetable,
    this.restoreFromTimetableAvailable = false,
    super.key,
  });

  final CourseManagementService service;
  final String logicalCourseId;
  final VoidCallback? onDeleted;
  final VoidCallback? onCancel;

  /// 「编辑课程」的去处（计划 §2.0：整门课程资料的**唯一**入口）。
  ///
  /// 与 [onCancel] 同一口径：为空时**不显示**按钮——不给点了没反应的反馈。
  final VoidCallback? onEditCourse;

  /// 「从原课表恢复」的去处：删除受损课程之后跳转课表导入页（计划 §2.0.3 路径二）。
  final VoidCallback? onRestoreFromTimetable;

  /// **该恢复路径是否可用**（计划 Task 4 Step 4 的 feature gate）。
  ///
  /// 它依赖"删掉整门课之后同一张图片还能重新导入"（Task 7–10 的批次状态与重导入）。
  /// 那些还没落地时，把这个入口放出去就是把用户送到**仍会被同哈希拦住的死路**上：
  /// 课程被删了、图片却导不回来。因此默认关闭，由组合根在能力齐备后打开。
  final bool restoreFromTimetableAvailable;

  @override
  State<CourseDetailPage> createState() => _CourseDetailPageState();
}

final class _CourseDetailPageState extends State<CourseDetailPage> {
  CourseSeriesDetail? _detail;
  CourseDeletionPreview? _preview;
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

  /// 保存受损课程恢复路径二：**备份 → 删除整门课 → 回到课表导入**（计划 §2.0.3）。
  ///
  /// 两步确认是刻意的，而且两步说的不是同一件事：
  ///
  /// 1. 这一步说清"会失去什么"（片段数、课次数、逐次调整条数）并**要求用户确认已有备份**；
  /// 2. 下一步才是既有的删除二次确认。
  ///
  /// **不能只留一步**：删除后原课程资料在库里就没了（导入批次不保存 OCR 原文），
  /// 而重新导入需要用户手里还有那张课表图片。系统无法替他确认这件事。
  Future<void> _restoreFromTimetable() async {
    final preview = _preview;
    if (preview == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('course-restore-dialog'),
        title: Text('用原课表恢复「${preview.title}」？'),
        content: Text(
          '将删除本学期的 ${preview.affectedSeriesCount} 个系列片段、'
          '共 ${preview.affectedOccurrenceCount} 次课，'
          '以及这些片段名下**全部逐次调整**。\n\n'
          '删除后请用**原来那张课表图片**重新导入；'
          '系统没有保存课表的原始识别内容，无法自动还原课程名称、教师、地点与领域。\n\n'
          '请确认你已经备份了这门课的数据，并且手里还有那张课表图片。',
        ),
        actions: [
          TextButton(
            key: const Key('course-restore-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('course-restore-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('我已备份，继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _delete(proceedToReimport: true);
  }

  Future<void> _delete({bool proceedToReimport = false}) async {
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
    if (!result.isSuccess) return;
    // **恢复路径二删完就回到课表导入**（§2.0.3）：留在详情页只会看到"找不到这门课程"，
    // 而用户下一步必须做的是重新选那张原图。
    if (proceedToReimport) {
      widget.onRestoreFromTimetable?.call();
      return;
    }
    widget.onDeleted?.call();
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
            // **结构化完整性提示**（计划 §2.0.3／Task 4 Step 2）。它说的是确定的事实
            // （"与旧版占位标题/时区不一致相符"），而不是猜测出来的原值。
            if (detail.hasIntegrityIssues) ...[
              _IntegrityBanner(
                detail: detail,
                onRepair: widget.onEditCourse,
                onRestore: widget.restoreFromTimetableAvailable
                    ? _restoreFromTimetable
                    : null,
              ),
              const SizedBox(height: 12),
            ],
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
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                // 「编辑课程」：整门课程资料（名称、教师、地点、领域、项目、星期、周次）
                // 与上课安排的**唯一**入口。范围编辑不在这里——单次与"此次及以后"在
                // 日历的具体课次上（那里才有真实发生时间），见 [onEditCourse] 的说明。
                if (widget.onEditCourse != null)
                  FilledButton.icon(
                    key: const Key('course-edit-course'),
                    onPressed: _busy ? null : widget.onEditCourse,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('编辑课程'),
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

/// 旧版时间修改损伤的**阻断级提示**（计划 §2.0.3／Task 4 Step 2）。
///
/// 它必须说清三件事，缺一件用户就会做错：
///
/// 1. **发生了什么**：这门课的资料可能被旧版的时间修改覆盖掉了；
/// 2. **系统做不到什么**：库里有没保存课表的原始识别内容，因此**不能自动还原**名称、
///    教师、地点或领域；
/// 3. **用户能做什么**：两条真实路径——手工补全并预览保存，或备份后删除该课程、
///    再用原课表重新导入。
final class _IntegrityBanner extends StatelessWidget {
  const _IntegrityBanner({
    required this.detail,
    required this.onRepair,
    required this.onRestore,
  });

  final CourseSeriesDetail detail;
  final VoidCallback? onRepair;

  /// 为空时**不显示**这条恢复路径（计划 Task 4 Step 4 的 feature gate）。
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('course-integrity-banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '检测到这门课程可能受旧版时间修改问题影响。'
            '保存前请核对课程名称、教师、地点、领域、项目和上课安排。',
            key: const Key('course-integrity-message'),
            style: TextStyle(color: scheme.onErrorContainer),
          ),
          const SizedBox(height: 4),
          Text(
            // **不提供"自动恢复原名称"**：数据库里没有可重放的原值。
            '系统没有保存课表的原始识别内容，无法自动还原原来的课程名称、教师、地点或领域。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (detail.hasLegacyPlaceholderTitle) ...[
            const SizedBox(height: 4),
            Text(
              '这门课的标题仍是旧版的占位文字「$legacyPlaceholderCourseTitle」，'
              '需要在编辑页里显式确认后才算核对过。',
              key: const Key('course-integrity-placeholder'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (onRepair != null)
                FilledButton.tonal(
                  key: const Key('course-integrity-repair'),
                  onPressed: onRepair,
                  child: const Text('手工修复'),
                ),
              if (onRestore != null)
                OutlinedButton(
                  key: const Key('course-integrity-restore'),
                  onPressed: onRestore,
                  child: const Text('从原课表恢复'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
