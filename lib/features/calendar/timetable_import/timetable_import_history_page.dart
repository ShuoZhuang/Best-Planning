import 'package:flutter/material.dart';

import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_rollback.dart';

/// **导入记录页**（计划 §2.6／Task 10）。
///
/// ## 为什么需要一个持久入口
///
/// 修复前撤销导入只存在于导入完成后那条**短暂提示条**上：提示条一消失、应用一重启，
/// 用户就再也拿不到批次 id——而仓储的 `inspectRollback`／`rollback` 一直都在，
/// 只是**不可达**（计划 §1.10）。这一页把那两个能力接出来。
///
/// ## 入口固定为「近期日历 → 管理课程 → 导入记录」
///
/// 课程管理页已经有"导入课表"入口，把记录页放在它旁边，用户找"我导入过什么"时
/// 自然会去那里；放进近期日历的顶部工具栏会继续挤压那一排本来就紧张的按钮。
///
/// ## 它不认识的数据库
///
/// 页面只调用 [TimetableImportService]：不碰 Drift、不拼 SQL、不复制回滚流程。
/// 撤销走 [confirmAndRollbackTimetableImport]，与提示条**同一套确认与 force 集合**。
final class TimetableImportHistoryPage extends StatefulWidget {
  const TimetableImportHistoryPage({
    required this.service,
    this.onImportTimetable,
    this.onCancel,
    super.key,
  });

  final TimetableImportService service;

  /// 「导入课表」的去处。为空时不显示该按钮——不给点了没反应的入口。
  final VoidCallback? onImportTimetable;
  final VoidCallback? onCancel;

  @override
  State<TimetableImportHistoryPage> createState() =>
      _TimetableImportHistoryPageState();
}

final class _TimetableImportHistoryPageState
    extends State<TimetableImportHistoryPage> {
  List<TimetableImportHistoryItem>? _items;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await widget.service.listHistory();
      if (!mounted) return;
      setState(() {
        _items = items;
        _busy = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        // **错误态要给用户可读的说明与"重试"**，而不是一个空白页面或异常文本
        // （规范全局不变量第 7 条：不显示数据库异常、路径或 uuid）。
        _error = '读取导入记录失败。你可以重试；如果一直失败，请先备份数据再联系我们。';
        _busy = false;
      });
    }
  }

  Future<void> _rollback(TimetableImportHistoryItem item) async {
    final result = await confirmAndRollbackTimetableImport(
      context,
      widget.service,
      item.batchId,
    );
    if (!mounted) return;
    switch (result.outcome) {
      case TimetableImportRollbackOutcome.rolledBack:
        _show('已撤销这次导入，删除 ${result.deletedEventCount} 组课程');
        // **成功之后重新加载列表**（Task 10 Step 7）：不乐观地先移除那一行——
        // 失败时列表保持原状态并提供重试，比"先删掉再发现没删成"诚实得多。
        await _load();
      case TimetableImportRollbackOutcome.cancelled:
        return;
      case TimetableImportRollbackOutcome.failed:
        _show('撤销失败，导入记录保持原样。请重试。');
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.onCancel != null)
                IconButton(
                  key: const Key('import-history-back'),
                  tooltip: '返回',
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              Expanded(
                child: Text(
                  '导入记录',
                  key: const Key('import-history-title'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (widget.onImportTimetable != null)
                FilledButton.tonalIcon(
                  key: const Key('import-history-import'),
                  onPressed: widget.onImportTimetable,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('导入课表'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_busy && items == null)
            const Expanded(
              child: Center(
                child: CircularProgressIndicator(
                  key: Key('import-history-loading'),
                ),
              ),
            )
          else if (_error case final message?)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message,
                      key: const Key('import-history-error'),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      key: const Key('import-history-retry'),
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else if (items == null || items.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  '还没有课表导入记录。',
                  key: const Key('import-history-empty'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                key: const Key('import-history-list'),
                itemCount: items.length,
                itemBuilder: (context, index) =>
                    _row(context, items[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, TimetableImportHistoryItem item) {
    return Card(
      key: Key('import-history-${item.batchId}'),
      child: ListTile(
        // **只显示文件名与状态文案**：不显示批次 id、不显示图片哈希、不显示数据库异常。
        title: Text(item.sourceFileName),
        subtitle: Text(
          '${item.termName ?? '未命名学期'} · '
          '${_localTime(item.createdAtUtc)}\n'
          '原 ${item.createdSeriesCount} 组 · 还剩 ${item.remainingSeriesCount} 组'
          '${item.protectedSeriesCount > 0 ? ' · ${item.protectedSeriesCount} 组有修改' : ''}'
          '\n${_statusLabel(item)}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 8,
          children: [
            if (item.canRollback)
              OutlinedButton(
                key: Key('import-history-rollback-${item.batchId}'),
                onPressed: _busy ? null : () => _rollback(item),
                child: const Text('撤销'),
              ),
            // **已删除部分课程而没有剩余系列的批次**：撤销没有意义，
            // 但用户接下来要做的正是"用原图恢复"（§2.6）。
            if (!item.canRollback &&
                item.status == TimetableImportBatchStatus.partiallyDeleted &&
                widget.onImportTimetable != null)
              OutlinedButton(
                key: Key('import-history-reimport-${item.batchId}'),
                onPressed: widget.onImportTimetable,
                child: const Text('重新导入课表'),
              ),
          ],
        ),
      ),
    );
  }

  /// 状态文案（计划 §2.6 的四句）。
  static String _statusLabel(TimetableImportHistoryItem item) {
    final protectedSeries = item.protectedSeriesCount > 0;
    return switch (item.status) {
      TimetableImportBatchStatus.committed =>
        protectedSeries ? '导入后有修改' : '已导入',
      TimetableImportBatchStatus.partiallyDeleted => '已删除部分课程，可重新导入',
      TimetableImportBatchStatus.rolledBack => '已撤销',
      TimetableImportBatchStatus.draft => '未完成',
    };
  }

  static String _localTime(DateTime utc) {
    final local = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
