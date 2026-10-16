import 'package:flutter/material.dart';

import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/design/planner_editor_scaffold.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/models/workspace.dart';

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
/// ## 冲突预览是**两步保存**，不是一步
///
/// 第一次点「保存」只算预览（影响摘要 ＋ 冲突），第二次才真的写。理由写在
/// [_preview] 上：改课程安排会**删掉片段**，而删掉的片段名下有用户逐次调整过的例外——
/// 那个数量必须让用户先看见。
final class CourseEditorPage extends StatefulWidget {
  const CourseEditorPage({
    required this.service,
    required this.logicalCourseId,
    this.loadAreas,
    this.loadProjects,
    this.onSaved,
    this.onCancel,
    super.key,
  });

  final CourseManagementService service;
  final String logicalCourseId;

  /// 领域与项目清单。**为空时不显示这两个选择器**——与"不给点了没反应的入口"
  /// 同一条口径：没有清单就选不出东西。
  final Future<List<PlannerArea>> Function()? loadAreas;
  final Future<List<PlannerProject>> Function()? loadProjects;

  final VoidCallback? onSaved;
  final VoidCallback? onCancel;

  @override
  State<CourseEditorPage> createState() => _CourseEditorPageState();
}

final class _CourseEditorPageState extends State<CourseEditorPage> {
  bool _loaded = false;
  CourseSeriesDetail? _detail;

  late TextEditingController _title;
  late TextEditingController _teacher;
  late TextEditingController _location;

  String? _areaId;
  String? _projectId;

  /// 按片段逐个编辑的安排。**顺序与详情一致**，删除行用的是下标。
  final List<_ScheduleRow> _rows = [];

  List<PlannerArea> _areas = const [];
  List<PlannerProject> _projects = const [];

  Map<String, String> _errors = const {};
  String? _status;

  /// 已算出的预览；`null` 表示"当前没有有效预览"。
  CourseEditPreview? _preview;

  /// 预览对应的冲突。**阻断类与警告类分开**：
  /// 前者禁止保存，后者要求用户勾选确认。
  List<CourseTimeConflict> _conflicts = const [];
  bool _acknowledgedConflicts = false;
  bool _busy = false;

  /// 「换领域后旧项目被清空」的那句说明（计划 Task 5 Step 2）。
  String? _projectClearedNotice;

  /// 用户是否**显式确认过**"这个占位标题就是正确的课程名"（计划 Task 4 Step 2）。
  ///
  /// 旧版把导入课程的标题写成了 `未命名事项`（计划 §1.1）。检测到之后不允许用户
  /// 不看提示就再次确认保存——他**可以保留**这个标题，但必须显式勾选一次，
  /// 让"我知道它叫这个"变成一条有据可查的动作，而不是一次静默放行。
  bool _confirmedLegacyTitle = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _teacher = TextEditingController();
    _location = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _teacher.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final detail = await widget.service.findCourse(widget.logicalCourseId);
    final areas = await widget.loadAreas?.call() ?? const <PlannerArea>[];
    final projects =
        await widget.loadProjects?.call() ?? const <PlannerProject>[];
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _detail = detail;
      _areas = areas;
      _projects = projects;
      if (detail != null) {
        _title.text = detail.summary.title;
        final head = detail.segments.firstOrNull;
        _teacher.text = head?.teacher ?? '';
        _location.text = head?.location ?? '';
        _areaId = head?.areaId;
        _projectId = head?.projectId;
        _rows
          ..clear()
          ..addAll(detail.segments.map(_ScheduleRow.fromSegment));
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 草稿
  // ─────────────────────────────────────────────────────────────────────────────

  CourseProfileDraft? _draft() {
    final detail = _detail;
    if (detail == null) return null;
    return CourseProfileDraft(
      logicalCourseId: widget.logicalCourseId,
      title: _title.text,
      teacher: _teacher.text.trim(),
      location: _location.text.trim(),
      areaId: _areaId,
      projectId: _projectId,
      schedule: [for (final row in _rows) row.toDraft()],
    );
  }

  /// **任何字段变化都作废旧预览**（计划 Task 5 Step 3）。
  ///
  /// 留着旧预览比没有预览更糟：用户会按**过期的数字**判断"要不要真的删掉这一段"，
  /// 而那个数字正是他做决定的依据。
  void _invalidatePreview() {
    if (_preview == null && _conflicts.isEmpty && _status == null) return;
    setState(_clearPreviewState);
  }

  /// 清掉"上一版的预览结论"。**不自己 `setState`**：调用方决定重建的时机。
  void _clearPreviewState() {
    _preview = null;
    _conflicts = const [];
    _acknowledgedConflicts = false;
    _status = null;
    _errors = const {};
  }

  /// 标题／教师／地点不属于任何一条安排，因此脏标记落在页面上。
  bool _profileDirty = false;

  void _onTextChanged() {
    // **必须无条件重建**：标题文本决定"旧版占位标题"那条核对提示是否还该出现
    // （用户把它改成真实课程名之后就不该再要求勾选），而那个判断读的是控制器的
    // 当前文本。走 `_invalidatePreview` 的"没有预览就不重建"短路会让提示卡住不动。
    setState(() {
      _profileDirty = true;
      _clearPreviewState();
    });
  }

  void _chooseArea(String? areaId) {
    setState(() {
      _areaId = areaId;
      // **换领域后旧项目若不属于新领域，立即清空并说明**（计划 Task 5 Step 2）。
      //
      // 悄悄留着会让这门课挂在一个不属于所选领域的项目上，而用户以为自己
      // 只是换了领域。**不隐式创建项目**（计划原文）：找不到就把项目留空。
      final project = _projectFor(_projectId);
      if (project == null || project.areaId != areaId) {
        final hadProject = _projectId != null;
        _projectId = null;
        _projectClearedNotice = hadProject
            ? '原项目不属于「${_areaName(areaId)}」，已清空。请重新选择或留空。'
            : null;
      } else {
        _projectClearedNotice = null;
      }
      _preview = null;
      _conflicts = const [];
      _acknowledgedConflicts = false;
      _status = null;
      _errors = const {};
    });
  }

  PlannerProject? _projectFor(String? id) {
    if (id == null) return null;
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  String _areaName(String? id) {
    for (final area in _areas) {
      if (area.id == id) return area.name;
    }
    return '未命名领域';
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 预览与保存
  // ─────────────────────────────────────────────────────────────────────────────

  /// 第一次点保存：算预览与冲突，**不写库**。
  ///
  /// 为什么必须是两步：改课程安排会**删掉片段**，而被删的片段名下有用户逐次调整过的
  /// 例外。计划 §2.1 要求把这四项（新增／删除片段数、受影响课次变化、会删的例外数）
  /// 明确列出来，用户二次确认后才应用。
  Future<void> _computePreview() async {
    final detail = _detail;
    final draft = _draft();
    if (detail == null || draft == null) return;

    final errors = validateCourseProfile(draft);
    if (errors.isNotEmpty) {
      setState(() {
        _errors = errors;
        _preview = null;
      });
      return;
    }

    setState(() => _busy = true);
    final preview = await widget.service.previewCourseEdit(
      CourseSaveRequest(
        logicalCourseId: widget.logicalCourseId,
        profile: draft,
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
      ),
    );
    final conflicts = await _detectConflicts(draft);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errors = const {};
      _preview = preview;
      _conflicts = conflicts;
      // **作废勾选**：换了内容之后，"我已查看"说的是上一版的内容。
      _acknowledgedConflicts = false;
    });
  }

  /// 把草稿展开成"改完之后每一段会落在哪些时刻"，交给服务的冲突预览。
  ///
  /// **按周展开整学期**：冲突可能发生在任何一周，只看第一周会漏掉"第 8 周与
  /// 另一门课撞上"这类问题。次数有上限（一学期 16 周 × 每段最多 7 天），因此代价可控。
  Future<List<CourseTimeConflict>> _detectConflicts(
    CourseProfileDraft draft,
  ) async {
    final proposed = <({String eventId, TimeRange range})>[];
    for (var index = 0; index < draft.schedule.length; index++) {
      final row = draft.schedule[index];
      final segmentId = index < _detail!.segments.length
          ? _detail!.segments[index].eventId
          : '$index';
      for (final day in _occurrenceStarts(row)) {
        proposed.add((
          eventId: segmentId,
          range: TimeRange(
            startUtc: day,
            endUtc: day.add(Duration(minutes: row.endMinute - row.startMinute)),
          ),
        ));
      }
    }
    if (proposed.isEmpty) return const [];
    final found = await widget.service.previewTimeChange(
      logicalCourseId: widget.logicalCourseId,
      proposed: proposed,
    );
    return found;
  }

  /// 一段安排在整学期里的每一次起始时刻。
  ///
  /// **按本地日期逐天推进、再逐次换算 UTC**，而不是"加 7×24 小时"：后者在夏令时切换
  /// 那一周会漂一小时，于是"周三 08:00 会不会撞上别的课"这个问题的答案在那一周是错的。
  List<DateTime> _occurrenceStarts(CourseScheduleDraft row) {
    final starts = <DateTime>[];
    final last = row.validUntilLocalDate ?? row.validFromLocalDate;
    var date = DateTime(
      row.validFromLocalDate.year,
      row.validFromLocalDate.month,
      row.validFromLocalDate.day,
    );
    final end = DateTime(last.year, last.month, last.day);
    final zones = widget.service.zones;
    final zoneId = widget.service.timeZoneId;
    if (zones == null || zoneId == null) return const [];
    while (!date.isAfter(end)) {
      if (row.weekdays.contains(date.weekday) && _matchesInterval(row, date)) {
        starts.add(zones.localDateTimeToUtc(date, row.startMinute, zoneId));
      }
      date = date.add(const Duration(days: 1));
    }
    return starts;
  }

  bool _matchesInterval(CourseScheduleDraft row, DateTime date) {
    if (row.intervalWeeks <= 1) return true;
    final anchor = DateTime(
      row.validFromLocalDate.year,
      row.validFromLocalDate.month,
      row.validFromLocalDate.day,
    );
    final anchorMonday = anchor.subtract(
      Duration(days: anchor.weekday - DateTime.monday),
    );
    final monday = date.subtract(
      Duration(days: date.weekday - DateTime.monday),
    );
    final weeks = monday.difference(anchorMonday).inDays ~/ 7;
    return weeks >= 0 && weeks % row.intervalWeeks == 0;
  }

  bool get _hasBlockingConflict => _conflicts.any(isBlockingCourseTimeConflict);

  /// 当前状态下这个主按钮能不能按（计划 Task 5 Step 3）。
  ///
  /// 三种情况：
  /// - **还没出预览** ⇒ 能按（第一次点击就是去算预览）；
  /// - **有警告冲突且用户没勾"我已查看"** ⇒ 不能按。勾选就是"他真的看过"的凭据，
  ///   不让它影响按钮的可用状态，这个勾选就只是装饰；
  /// - 其余 ⇒ 能按。
  bool get _canSaveFromPreview {
    if (_preview == null) return true;
    if (_conflicts.isNotEmpty && !_acknowledgedConflicts) return false;
    // **还没核对旧版占位标题** ⇒ 不能按（计划 Task 4 Step 2）。
    if (_needsLegacyTitleConfirmation) return false;
    return true;
  }

  /// 这门课命中"疑似旧版占位标题"，而且用户**还没有把它改掉**。
  ///
  /// 改掉（写成真实课程名）就不再需要确认：那时用户已经主动核对过了。
  bool get _needsLegacyTitleConfirmation =>
      (_detail?.hasLegacyPlaceholderTitle ?? false) &&
      _title.text.trim() == legacyPlaceholderCourseTitle &&
      !_confirmedLegacyTitle;

  void _onPrimaryAction() {
    if (_preview == null) {
      _computePreview();
      return;
    }
    _save();
  }

  /// 第二次点保存：真的写库。
  Future<void> _save() async {
    final detail = _detail;
    final draft = _draft();
    if (detail == null || draft == null) return;

    setState(() => _busy = true);
    final result = await widget.service.saveCourse(
      CourseSaveRequest(
        logicalCourseId: widget.logicalCourseId,
        profile: draft,
        expectedRevisions: detail.sourceRevisions,
        expectedFingerprint: detail.revisionFingerprint,
      ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.status == CourseSaveStatus.saved) {
        _status = '已保存';
        // **保存成功后必须清掉预览**：留着它，按钮就还是「确认保存」，
        // 而用户下一次点它会照着**上一版**的预览再写一遍——而预览里那句
        // "会删除 N 段"已经不再成立。预览说的是"将要发生什么"，写完就该消失。
        _preview = null;
        _conflicts = const [];
        _acknowledgedConflicts = false;
        // 草稿现在就是"已保存的样子"，因此行不再算脏。
        for (final row in _rows) {
          row.markClean();
        }
      } else if (result.status == CourseSaveStatus.invalid) {
        _errors = result.fieldErrors ?? const {};
      } else {
        // **失败时如实说"原内容未改变"**：不这么说，用户会以为改了一半。
        _status = result.error;
      }
    });
    if (result.status != CourseSaveStatus.saved) return;
    // **保存成功后重新读取**（计划 Task 4 Step 3）：只有所有确定性问题真的消失了，
    // 提示才该移除。不重读的话，用户把占位标题改成真名并保存之后，横幅会继续挂着，
    // 而那条提示说的是"可能受损"——它必须跟着数据走，不能跟着页面生命周期走。
    await _load();
    if (!mounted) return;
    setState(() => _status = '已保存');
    widget.onSaved?.call();
  }

  Future<void> _cancel() async {
    // **有未保存改动时先问"放弃更改？"**（计划 Task 5 Step 7）：直接走掉会让用户
    // 白填一遍，而这一页有六七个字段。
    final dirty =
        _detail != null &&
        (_profileDirty || _preview != null || _rows.any((row) => row.dirty));
    if (!dirty) {
      widget.onCancel?.call();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('course-editor-discard'),
        title: const Text('放弃更改？'),
        content: const Text('这门课有还没保存的改动，离开后它们会丢掉。'),
        actions: [
          TextButton(
            key: const Key('course-editor-discard-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            key: const Key('course-editor-discard-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃更改'),
          ),
        ],
      ),
    );
    if (discard == true) widget.onCancel?.call();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 界面
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = _detail;
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
            if (widget.onCancel != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('course-editor-back'),
                onPressed: widget.onCancel,
                child: const Text('返回课程列表'),
              ),
            ],
          ],
        ),
      );
    }

    return PlannerEditorScaffold(
      key: const Key('course-editor-page'),
      title: '编辑「${detail.summary.title}」',
      subtitle: '这里改的是整门课。只想改一次课，请到日历上那条安排点「编辑」。',
      onCancel: widget.onCancel == null ? null : _cancel,
      errorSummary: _errorSummary(),
      actions: [
        // **阻断冲突时按钮根本不出现**，而不是"出现了但点不动"（计划 Task 5 Step 3）。
        //
        // 两者的差别不是外观：一个能点但什么都不做的按钮会让人反复试，而用户**正确**
        // 的动作是去改冲突，不是再确认一次。规范 §10.2 那句"硬冲突不能直接保存"
        // 说的是"没有这条路"，而不是"这条路被堵着"。
        if (!_hasBlockingConflict)
          FilledButton(
            key: _preview == null
                ? const Key('course-editor-save')
                : const Key('course-editor-confirm-save'),
            // **守卫要体现在"能不能按"上，而不能只体现在"按了之后做什么"**。
            //
            // 第一版把警告冲突的判据写在 `onPressed` 的闭包里（先 `return` 掉），
            // 于是按钮**看起来可点、点了没反应**——用户会反复试，而正确的动作是
            // 去勾"我已查看课程冲突"。测试因此读到 `onPressed != null` 而失败。
            onPressed: _busy || !_canSaveFromPreview ? null : _onPrimaryAction,
            child: Text(_preview == null ? '保存' : '确认保存'),
          ),
      ],
      // **`Column` 而不是 `ListView`**：`PlannerEditorScaffold` 的内容区本身已经在
      // 一个滚动视图里，再套一个纵向 viewport 会得到 "Vertical viewport was given
      // unbounded height"——两层滚动条不是"多一层保险"，而是直接抛错。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **结构化完整性提示**（计划 §2.0.3／Task 4 Step 2）：编辑页是"手工修复"那条
          // 路径的落点，因此提示必须出现在这里，而不只是详情页。
          if (detail.hasIntegrityIssues) ...[
            _integrityNotice(context, detail),
            const SizedBox(height: 16),
          ],
          _sectionTitle('课程资料'),
          _textField('course-title', '课程名称', _title),
          _textField('course-teacher', '教师', _teacher),
          _textField('course-location', '地点', _location),
          if (widget.loadAreas != null) _areaField(),
          if (widget.loadProjects != null && _areaId != null) _projectField(),
          if (_projectClearedNotice case final notice?) ...[
            const SizedBox(height: 4),
            Text(
              notice,
              key: const Key('course-project-cleared'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          _sectionTitle('上课安排'),
          for (var index = 0; index < _rows.length; index++)
            _rowCard(context, index, detail),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('course-add-row'),
              onPressed: () {
                setState(() {
                  _rows.add(
                    _ScheduleRow.fromSegment(detail.segments.first)
                      ..title = detail.summary.title,
                  );
                  _invalidatePreview();
                });
              },
              icon: const Icon(Icons.add),
              label: const Text('添加一段安排'),
            ),
          ),
          const SizedBox(height: 24),
          if (_preview case final preview?) _previewCard(context, preview),
          if (_status case final status?) ...[
            const SizedBox(height: 12),
            Text(status, key: const Key('course-editor-status')),
          ],
        ],
      ),
    );
  }

  Widget _errorSummary() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final message in _errors.values)
        Text(message, style: const TextStyle(color: Colors.red)),
    ],
  );

  /// 旧版损伤提示 ＋（命中占位标题时的）显式确认勾选。
  ///
  /// 文案与详情页一致，因为用户在两处看到的是**同一件事**；差别只在于编辑页多做一件事：
  /// 把"我确认这是正确课程名"变成保存的前置条件（计划 Task 4 Step 2）。
  Widget _integrityNotice(BuildContext context, CourseSeriesDetail detail) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('course-editor-integrity-banner'),
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
            key: const Key('course-editor-integrity-message'),
            style: TextStyle(color: scheme.onErrorContainer),
          ),
          Text(
            '系统没有保存课表的原始识别内容，无法自动还原原来的课程名称、教师、地点或领域。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (detail.hasLegacyPlaceholderTitle &&
              _title.text.trim() == legacyPlaceholderCourseTitle) ...[
            const SizedBox(height: 4),
            // **`Row` 而不是 `CheckboxListTile`**：`CheckboxListTile` 内部是一个
            // `ListTile`，而 `ListTile` 把背景与水波纹画在最近的 `Material` 上——
            // 这里外面是一个带底色的 `Container`，Flutter 会因此直接抛
            // "ListTile background color or ink splashes may be invisible"。
            // 显式的 `Checkbox` ＋ 文案既避开那条断言，也不必为提示条引入 `Material`。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  key: const Key('course-editor-confirm-legacy-title'),
                  value: _confirmedLegacyTitle,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _confirmedLegacyTitle = value ?? false;
                          // 勾选状态本身不算"内容变了"，因此不动预览；
                          // 但它决定"确认保存"能不能按，所以必须重建。
                        }),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('我确认这是正确课程名'),
                        Text(
                          '标题仍是旧版的占位文字，保存前必须显式核对一次；'
                          '如果它不是真实课程名，请在上面改成正确的名称。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _textField(
    String key,
    String label,
    TextEditingController controller,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key(key),
      controller: controller,
      onChanged: (_) => _onTextChanged(),
      decoration: InputDecoration(
        labelText: label,
        errorText: _errors[key.replaceFirst('course-', '')],
      ),
    ),
  );

  Widget _areaField() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String?>(
      key: const Key('course-area'),
      initialValue: _areaId,
      decoration: const InputDecoration(labelText: '领域'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('不归属领域')),
        for (final area in _areas)
          DropdownMenuItem<String?>(value: area.id, child: Text(area.name)),
      ],
      onChanged: _chooseArea,
    ),
  );

  Widget _projectField() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String?>(
      key: const Key('course-project'),
      initialValue: _projectId,
      decoration: const InputDecoration(
        labelText: '项目',
        helperText: '只列出属于所选领域的项目',
      ),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('不归属项目')),
        for (final project in _projects)
          if (project.areaId == _areaId)
            DropdownMenuItem<String?>(
              value: project.id,
              child: Text(project.name),
            ),
      ],
      onChanged: (value) {
        setState(() {
          _projectId = value;
          _projectClearedNotice = null;
          _preview = null;
          _conflicts = const [];
          _acknowledgedConflicts = false;
          _status = null;
        });
      },
    ),
  );

  Widget _rowCard(BuildContext context, int index, CourseSeriesDetail detail) {
    final row = _rows[index];
    final weekdayLabel = (row.weekdays.toList()..sort())
        .map(_weekdayLabel)
        .join('、');
    return Card(
      key: Key('course-row-$index'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$weekdayLabel ${_hhmm(row.startMinute)}–${_hhmm(row.endMinute)}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                // **用 `Semantics` 显式给名称，不依赖 `tooltip`**。
                //
                // `IconButton` 没有 `semanticLabel` 参数。`tooltip` 有时会进入语义树，
                // 但实测它**不稳定**：同一棵树里这个节点的 label 时有时无
                // （工具提示有自己的显示时机）。而"读屏用户能不能听到这个按钮叫什么"
                // 不能靠一个看时机的机制——因此显式给 label，tooltip 只留给指针用户。
                //
                // 名称里必须带**课程名与星期**：这一页上可能有好几行结构相同的安排，
                // 只读"删除"的话读屏用户不知道自己在删哪一段课。
                Semantics(
                  button: true,
                  label: '删除「${detail.summary.title}」的 $weekdayLabel 这一段',
                  child: IconButton(
                    key: Key('course-remove-$index'),
                    tooltip: '删除「${detail.summary.title}」的 $weekdayLabel 这一段',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() {
                        _rows.removeAt(index);
                        _invalidatePreview();
                      });
                    },
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                for (var day = DateTime.monday; day <= DateTime.sunday; day++)
                  FilterChip(
                    key: Key('course-row-$index-day-$day'),
                    label: Text(_weekdayLabel(day)),
                    selected: row.weekdays.contains(day),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          row.weekdays.add(day);
                        } else {
                          row.weekdays.remove(day);
                        }
                        _invalidatePreview();
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: Key('course-row-$index-start'),
                    initialValue: _hhmm(row.startMinute),
                    decoration: const InputDecoration(
                      labelText: '开始',
                      hintText: 'HH:mm',
                    ),
                    onChanged: (value) {
                      final parsed = _parseTime(value);
                      if (parsed != null) row.startMinute = parsed;
                      _onTextChanged();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    key: Key('course-row-$index-end'),
                    initialValue: _hhmm(row.endMinute),
                    decoration: const InputDecoration(
                      labelText: '结束',
                      hintText: 'HH:mm',
                    ),
                    onChanged: (value) {
                      final parsed = _parseTime(value);
                      if (parsed != null) row.endMinute = parsed;
                      _onTextChanged();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: Key('course-row-$index-interval'),
                    initialValue: row.intervalWeeks,
                    decoration: const InputDecoration(labelText: '频率'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('每周')),
                      DropdownMenuItem(value: 2, child: Text('隔周')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        row.intervalWeeks = value ?? 1;
                        _invalidatePreview();
                      });
                    },
                  ),
                ),
              ],
            ),
            if (row.intervalWeeks == 2) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<WeekParity>(
                key: Key('course-row-$index-parity'),
                initialValue: row.parity,
                decoration: const InputDecoration(labelText: '单周还是双周'),
                items: const [
                  DropdownMenuItem(value: WeekParity.odd, child: Text('单周')),
                  DropdownMenuItem(value: WeekParity.even, child: Text('双周')),
                ],
                onChanged: (value) {
                  setState(() {
                    row.parity = value ?? WeekParity.every;
                    _invalidatePreview();
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _previewCard(BuildContext context, CourseEditPreview preview) {
    final blocking = <CourseTimeConflict>[];
    final warnings = <CourseTimeConflict>[];
    for (final conflict in _conflicts) {
      if (isBlockingCourseTimeConflict(conflict)) {
        blocking.add(conflict);
      } else {
        warnings.add(conflict);
      }
    }
    return Card(
      key: const Key('course-editor-preview'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('这次保存会做什么', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            // 四项都要列（计划 §2.1）。只报"删除 1 段"没有意义——
            // 用户要知道的是"这学期会少上几次课"。
            Text('新增片段：${preview.addedSegments} 段'),
            Text('改写片段：${preview.updatedSegments} 段'),
            Text('删除片段：${preview.removedSegments} 段'),
            Text(
              '课次变化：${preview.affectedOccurrenceDelta >= 0 ? '+' : ''}'
              '${preview.affectedOccurrenceDelta} 次',
            ),
            // **两类例外删除分开写**（计划 §2.5）：合成一句"会删除 3 条例外"
            // 无法解释其中哪几条是"整段被删"、哪几条是"超出新周次"——
            // 而后者正是用户缩短周次时最该被提醒的一件事。
            if (preview.removedSegmentExceptionCount > 0)
              Text(
                '删除片段会一并带走 '
                '${preview.removedSegmentExceptionCount} 条你单独调整过的课次',
                key: const Key('course-editor-removed-segment-exceptions'),
              ),
            if (preview.invalidatedRetainedExceptionCount > 0)
              Text(
                '另有 ${preview.invalidatedRetainedExceptionCount} 条单独调整'
                '已超出新的周次或星期，将一并删除',
                key: const Key('course-editor-invalidated-exceptions'),
              ),
            if (blocking.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '这些冲突必须先解决，不能直接保存：',
                key: const Key('course-editor-blocking'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              for (final conflict in blocking)
                Text(
                  '「${conflict.title}」'
                  '${_hhmm(_localMinute(conflict.range.startUtc))}–'
                  '${_hhmm(_localMinute(conflict.range.endUtc))} 已被占用',
                ),
            ],
            if (warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const Key('course-editor-ack-conflicts'),
                contentPadding: EdgeInsets.zero,
                value: _acknowledgedConflicts,
                onChanged: (value) =>
                    setState(() => _acknowledgedConflicts = value ?? false),
                title: const Text('我已查看课程冲突'),
                subtitle: Text(
                  '与 ${warnings.map((c) => '「${c.title}」').toSet().join('、')} 时间重叠',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  int _localMinute(DateTime utc) {
    final zones = widget.service.zones;
    final zoneId = widget.service.timeZoneId;
    if (zones == null || zoneId == null) return utc.hour * 60 + utc.minute;
    final local = zones.toLocal(utc, zoneId);
    return local.hour * 60 + local.minute;
  }

  static String _hhmm(int minute) =>
      '${(minute ~/ 60).toString().padLeft(2, '0')}:'
      '${(minute % 60).toString().padLeft(2, '0')}';

  static int? _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  static String _weekdayLabel(int weekday) => switch (weekday) {
    DateTime.monday => '周一',
    DateTime.tuesday => '周二',
    DateTime.wednesday => '周三',
    DateTime.thursday => '周四',
    DateTime.friday => '周五',
    DateTime.saturday => '周六',
    DateTime.sunday => '周日',
    _ => '周?',
  };
}

/// 一行安排的编辑状态。
///
/// **不复用 `CourseScheduleDraft`**：那个类型在构造时把集合包成不可变的
/// （`UnmodifiableSetView`），而这里需要用户逐次开关星期。用可变的行状态、
/// 在提交时构造草稿，比"每次改动都重建一个不可变对象"少一层噪音。
final class _ScheduleRow {
  _ScheduleRow({
    required this.startMinute,
    required this.endMinute,
    required Set<int> weekdays,
    required this.validFromLocalDate,
    this.validUntilLocalDate,
    this.intervalWeeks = 1,
    this.parity = WeekParity.every,
    this.startWeek = 1,
    this.title = '',
    this.areaId,
    this.projectId,
    this.teacher = '',
    this.location = '',
  }) : weekdays = Set.of(weekdays);

  factory _ScheduleRow.fromSegment(CourseSeriesSegment segment) => _ScheduleRow(
    startMinute: segment.startMinute,
    endMinute: segment.endMinute,
    weekdays: segment.weekdays,
    validFromLocalDate: segment.validFromLocalDate,
    validUntilLocalDate: segment.validUntilLocalDate,
    intervalWeeks: segment.intervalWeeks,
    parity: segment.weekSpan.parity,
    startWeek: segment.weekSpan.startWeek,
    title: segment.title,
    areaId: segment.areaId,
    projectId: segment.projectId,
    teacher: segment.teacher,
    location: segment.location,
  );

  int startMinute;
  int endMinute;
  final Set<int> weekdays;
  final DateTime validFromLocalDate;
  DateTime? validUntilLocalDate;
  int intervalWeeks;
  WeekParity parity;
  int startWeek;
  String title;
  String? areaId;
  String? projectId;
  String teacher;
  String location;

  /// 这一行相对读进来的样子有没有被改过（取消时的"放弃更改？"要用）。
  ///
  /// **必须真的被置起**：第一版写的是 `dirty = dirty`（一个空操作），于是
  /// `_cancel` 的"有未保存改动"判据永远为假——改了地点之后点取消会**直接走掉**，
  /// 用户白填一遍。字段与集合的每个改动点都要调 [markDirty]。
  bool dirty = false;

  void markDirty() => dirty = true;

  void markClean() => dirty = false;

  CourseScheduleDraft toDraft() => CourseScheduleDraft(
    startMinute: startMinute,
    endMinute: endMinute,
    weekdays: weekdays,
    intervalWeeks: intervalWeeks,
    parity: parity,
    startWeek: startWeek,
    validFromLocalDate: validFromLocalDate,
    validUntilLocalDate: validUntilLocalDate,
  );
}
