import 'package:flutter/material.dart';

import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/protected_time_series.dart';
import 'package:personal_planner/domain/repositories/protected_time_series_repository.dart';
import 'package:personal_planner/features/calendar/protected_time/protected_time_editor_page.dart';

/// 编辑一个**保护时间系列**：先把详情读出来，再交给编辑器预填
/// （课程与保护时间管理修复计划 Task 8 Step 1）。
///
/// ## 为什么需要这一层
///
/// 编辑器是纯展示的（它只收一个已经填好的表单和一个保存回调），而"读详情"是异步的。
/// 把 `FutureBuilder` 放在路由里会让 `router.dart` 多出一段与导航无关的加载逻辑；
/// 放在编辑器里则会让它同时承担"新建"与"先读后填"两种生命周期。
///
/// 因此这里是一个**只做一件事**的适配器：读 → 预填 → 用 `updateEvent` 写回。
///
/// ## 三条不能含糊的边界
///
/// - **绝不走 `CalendarService.save()`**：那会生成新的 `CalendarEvent`，于是"改一次名字"
///   变成"又建了一条"——管理页多一行、日历上多一串，而用户以为自己只是改了个名字。
///   这正是本批次要修的缺陷（计划 §1.2）。
/// - **`expectedUpdatedAtUtc` 必须带**：用户在别处改过这条规则时返回 `stale` 而不是覆盖。
/// - **读不到就给一个说清楚的页面**：不给一个空表单——那会让用户以为这条规则是空的，
///   一保存就把它的名称、时间、重复规则全部覆盖掉。
final class ProtectedTimeSeriesEditorPage extends StatefulWidget {
  const ProtectedTimeSeriesEditorPage({
    required this.reader,
    required this.calendar,
    required this.anchorId,
    required this.timeZoneId,
    required this.zones,
    this.workspace,
    this.onSaved,
    this.onCancel,
    super.key,
  });

  final ProtectedTimeSeriesReader reader;
  final CalendarService calendar;
  final String anchorId;
  final String timeZoneId;
  final TimeZoneDatabase zones;
  final WorkspaceService? workspace;
  final void Function(BuildContext context)? onSaved;
  final VoidCallback? onCancel;

  @override
  State<ProtectedTimeSeriesEditorPage> createState() =>
      _ProtectedTimeSeriesEditorPageState();
}

final class _ProtectedTimeSeriesEditorPageState
    extends State<ProtectedTimeSeriesEditorPage> {
  bool _loaded = false;
  ProtectedTimeSeries? _series;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final series = await widget.reader.findProtectedSeries(widget.anchorId);
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _series = series;
    });
  }

  /// 真正执行保存：把表单字段翻译成一次 `updateEvent`（整条系列）。
  Future<String?> _update({
    required String title,
    required String notes,
    required DateTime startAtUtc,
    required DateTime endAtUtc,
    required bool weekly,
    required Set<int> weekdays,
    DateTime? recurrenceEnd,
  }) async {
    final series = _series!;
    final result = await widget.calendar.updateEvent(
      target: CalendarEditTarget(
        anchorId: series.anchorId,
        scope: EventEditScope.entireSeries,
        // **乐观并发**：页面读到的是 `series.updatedAtUtc`，别处改过就返回 stale。
        expectedUpdatedAtUtc: series.updatedAtUtc,
      ),
      event: CalendarEventEditDraft(
        title: title,
        notes: notes,
        startAtUtc: startAtUtc,
        endAtUtc: endAtUtc,
        timeZoneId: widget.timeZoneId,
        kind: CalendarEventKind.protected,
      ),
      recurrence: weekly
          ? RecurrenceEditDraft(
              weekdays: weekdays,
              intervalWeeks: 1,
              validFromLocalDate: series.validFromLocalDate,
              validUntilLocalDate: recurrenceEnd,
            )
          : null,
    );
    // **按状态分别说话**（计划 §5 的失败表）：
    // - `invalid`：字段级错误交回编辑器逐字段显示；
    // - `savedWithWarning`：数据**已经落库**，因此不能报错（那会让用户重复保存），
    //   但也不能假装完全成功——它在编辑器上作为一条标题级提示显示；
    // - `stale` / `missing` / `failed` / `unsupported`：整段失败，显示那一句。
    if (result.status == CalendarMutationStatus.saved) return null;
    if (result.status == CalendarMutationStatus.invalid) {
      final errors = result.fieldErrors;
      if (errors != null && errors.isNotEmpty) {
        return errors.values.first;
      }
      return '这些内容无法保存，请检查后重试。';
    }
    return result.error ?? '保存失败，原内容未改变。';
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final series = _series;
    if (series == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('编辑保护时间')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              // **说清"该怎么办"而不是只说"失败了"**（计划 §5 的失败表文案）。
              '这条保护时间已删除或链接过期，找不到它。请返回列表重新打开。',
              key: const Key('protected-series-missing'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return ProtectedTimeEditorPage(
      service: widget.calendar,
      timeZoneId: widget.timeZoneId,
      zones: widget.zones,
      workspace: widget.workspace,
      editAnchorId: widget.anchorId,
      series: series,
      onUpdateSeries: _update,
      onSaved: () => widget.onSaved?.call(context),
      onCancel: widget.onCancel,
    );
  }
}
