import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:personal_planner/application/adjustment_preview_port.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/pending_plan_preview.dart';
import 'package:personal_planner/domain/models/plan_adjustment.dart';
import 'package:personal_planner/domain/repositories/plan_adjustment_transaction.dart';

/// 「延后本次」的持久预览页（计划 Task 9 Step 7）。
///
/// 三条纪律：
/// 1. **只读仓储**：页面不接收 `ScheduleProposal` / 原始时刻 / 草稿，重开页面即可恢复；
/// 2. **无裸 UUID**：标题来自创建时的快照，未知时显示「未命名任务」；
/// 3. **单飞**：确认/取消/撤销在请求期间禁用，异常转成结果卡片而不是未处理 Future。
final class AdjustmentPreviewPage extends StatefulWidget {
  const AdjustmentPreviewPage({
    super.key,
    required this.adjustmentId,
    required this.port,
    required this.zones,
    required this.timeZoneId,
  });

  final String adjustmentId;
  final AdjustmentPreviewPort port;
  final TimeZoneDatabase zones;
  final String timeZoneId;

  @override
  State<AdjustmentPreviewPage> createState() => _AdjustmentPreviewPageState();
}

final class _AdjustmentPreviewPageState extends State<AdjustmentPreviewPage> {
  AdjustmentPreviewView? _view;
  bool _loading = true;
  bool _busy = false;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final view = await widget.port.loadPreview(widget.adjustmentId);
      if (!mounted) return;
      setState(() {
        _view = view;
        _loading = false;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _message = '读取这次调整失败，请稍后重试。';
      });
    }
  }

  Future<void> _confirm() async {
    final view = _view;
    final preview = view?.preview;
    if (view == null || preview == null || _busy || !view.canConfirm) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    AdjustmentApplyReceipt receipt;
    try {
      receipt = await widget.port.confirmAdjustment(
        adjustmentId: widget.adjustmentId,
        previewId: preview.preview.previewId,
      );
    } on Exception {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _message = '应用失败，当前计划未改变。';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed =
          receipt.status != AdjustmentApplyStatus.applied &&
          receipt.status != AdjustmentApplyStatus.alreadyApplied;
      _message = _applyMessage(receipt);
    });
    await _load();
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final cancelled = await widget.port.cancel(widget.adjustmentId);
      if (!mounted) return;
      setState(() => _busy = false);
      if (!cancelled) {
        setState(() {
          _failed = true;
          _message = '这次调整已经结束，无法取消。';
        });
        return;
      }
      Navigator.of(context).maybePop();
    } on Exception {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _message = '取消失败，请稍后重试。';
      });
    }
  }

  Future<void> _undo() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    PlanUndoResult result;
    try {
      result = await widget.port.undoAdjustment(widget.adjustmentId);
    } on Exception {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _message = '撤销失败，当前计划未改变。';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed =
          result.status != PlanUndoStatus.undone &&
          result.status != PlanUndoStatus.alreadyUndone;
      _message = switch (result.status) {
        PlanUndoStatus.undone || PlanUndoStatus.alreadyUndone => '已恢复调整前的计划。',
        PlanUndoStatus.executionAlreadyStarted => '已有任务开始，不能自动撤销。',
        PlanUndoStatus.supersededByAnotherPlan => '之后又应用了新的计划，这次调整不能跨版本撤销。',
        PlanUndoStatus.notFound => '找不到这次调整的撤销记录。',
        PlanUndoStatus.concurrentModification => '计划正在被另一个操作修改，请稍后重试。',
      };
    });
    await _load();
  }

  String _applyMessage(AdjustmentApplyReceipt receipt) =>
      switch (receipt.status) {
        AdjustmentApplyStatus.applied => '计划已更新。',
        AdjustmentApplyStatus.alreadyApplied => '这次调整已经应用过了，计划没有再次改变。',
        AdjustmentApplyStatus.stale => '预览已过期，请按原意重新生成。',
        AdjustmentApplyStatus.invalid => '方案未通过校验，当前计划未改变。',
        AdjustmentApplyStatus.adjustmentUnfulfilled => '方案没有兑现这次延后，当前计划未改变。',
        AdjustmentApplyStatus.concurrentModification => '另一个操作先修改了计划，请重新生成。',
        AdjustmentApplyStatus.notFound => '找不到这次调整。',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('延后本次')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _view == null
          ? _messageCard('找不到这次调整。')
          : _content(_view!),
      bottomNavigationBar: _view == null ? null : _actions(_view!),
    );
  }

  Widget _content(AdjustmentPreviewView view) {
    final adjustment = view.adjustment;
    final preview = view.preview;
    final blocks = preview?.blocks ?? const <PendingPlanPreviewBlock>[];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_message != null) ...[
          Card(
            color: _failed
                ? Theme.of(context).colorScheme.errorContainer
                : Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_message!),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  adjustment.targetTitleSnapshot,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  '原时间：${_range(adjustment.sourceStartUtc, adjustment.sourceEndUtc)}',
                ),
                const SizedBox(height: 4),
                Text(
                  '最早可开始：${_instant(adjustment.notBeforeUtc)}'
                  '（实际位置可能更晚）',
                ),
                if (_targetStart(preview) case final targetStart?) ...[
                  const SizedBox(height: 4),
                  Text('新时间：${_instant(targetStart)}'),
                ],
                const SizedBox(height: 4),
                Text('状态：${_statusLabel(adjustment.status)}'),
              ],
            ),
          ),
        ),
        if (blocks.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('调整后的安排', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final block in blocks)
            ListTile(
              dense: true,
              title: Text(block.title),
              subtitle: Text(_instant(block.startUtc)),
            ),
        ],
        if (view.canConfirm) ...[
          const SizedBox(height: 12),
          Text(
            '确认后才写入当前计划；取消不会改变任何已确认内容。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _messageCard(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );

  Widget? _actions(AdjustmentPreviewView view) {
    if (view.canUndo) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.tonal(
            key: const Key('adjustment-undo'),
            onPressed: _busy ? null : _undo,
            child: const Text('撤销本次调整'),
          ),
        ),
      );
    }
    if (!view.canConfirm && !view.canCancel) return null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (view.canCancel)
              Expanded(
                child: OutlinedButton(
                  key: const Key('adjustment-cancel'),
                  onPressed: _busy ? null : _cancel,
                  child: const Text('取消调整'),
                ),
              ),
            if (view.canCancel && view.canConfirm) const SizedBox(width: 12),
            if (view.canConfirm)
              Expanded(
                child: FilledButton(
                  key: const Key('adjustment-confirm'),
                  onPressed: _busy ? null : _confirm,
                  child: Text(_busy ? '处理中…' : '确认应用'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  DateTime? _targetStart(PendingPreviewBundle? preview) {
    if (preview == null) return null;
    try {
      final summary = jsonDecode(preview.preview.summaryJson);
      if (summary is Map && summary['targetStartUtc'] is num) {
        return DateTime.fromMicrosecondsSinceEpoch(
          (summary['targetStartUtc']! as num).toInt(),
          isUtc: true,
        );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String _statusLabel(PlanAdjustmentStatus status) => switch (status) {
    PlanAdjustmentStatus.active => '尚未生成预览',
    PlanAdjustmentStatus.generating => '正在生成',
    PlanAdjustmentStatus.previewReady => '预览已就绪',
    PlanAdjustmentStatus.applying => '正在应用',
    PlanAdjustmentStatus.applied => '已应用',
    PlanAdjustmentStatus.cancelled => '已取消',
    PlanAdjustmentStatus.failed => '生成失败',
    PlanAdjustmentStatus.stale => '预览已过期',
    PlanAdjustmentStatus.expired => '已过期',
  };

  String _instant(DateTime instantUtc) {
    final local = widget.zones.toLocal(instantUtc, widget.timeZoneId);
    return '${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  String _range(DateTime startUtc, DateTime endUtc) =>
      '${_instant(startUtc)} – ${_two(widget.zones.toLocal(endUtc, widget.timeZoneId).hour)}:'
      '${_two(widget.zones.toLocal(endUtc, widget.timeZoneId).minute)}';

  String _two(int value) => value.toString().padLeft(2, '0');
}
