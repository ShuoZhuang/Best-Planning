import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

final class PreferencesPage extends StatefulWidget {
  const PreferencesPage({
    required this.service,
    this.loadEvidence,
    this.onSuggestionAction,
    super.key,
  });

  final PreferenceService service;

  /// 读取用于重新分析的历史证据；为空时只列出已保存的建议，不重新分析。
  ///
  /// `PreferenceService.refresh(evidence)` 此前**没有任何生产调用方**（全库只有测试调用），
  /// 因此建议永远不会被生成——偏好页列出的是一份永远空着的名单，即便证据已在积累。
  /// 这一页是它最自然的触发点：分析结果就是这一页要展示的内容。
  final Future<List<PreferenceEvidence>> Function()? loadEvidence;

  /// 用户对某条建议采取的动作（`accepted`／`rejected`／`disabled`）。
  ///
  /// 统计的"建议采纳行为"（FR-STAT）读的正是 `suggestion:<code>` 这类事件，而此前没有任何
  /// 代码产生它们，因此该项恒为空（W5）。这一页是这些动作唯一的发生地。
  final void Function(String action, String suggestionId)? onSuggestionAction;

  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

final class _PreferencesPageState extends State<PreferencesPage> {
  List<PreferenceSuggestion> _suggestions = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final loadEvidence = widget.loadEvidence;
    if (loadEvidence != null) {
      // 先按证据重新分析，再把结果列出来；否则这一页永远只显示"没有建议"。
      // autoApply 保持默认的 false：FR-PREF-04 要求默认由用户确认后才影响排程。
      await widget.service.refresh(await loadEvidence());
    }
    final values = await widget.service.list();
    if (!mounted) return;
    setState(() {
      _suggestions = values;
      _loading = false;
    });
  }

  Future<void> _act(Future<void> Function() action) async {
    await action();
    await _reload();
  }

  /// 先记事件再执行动作。
  ///
  /// 事件记录的是"用户做了什么"，因此即使随后的服务调用失败，这次意图也该留下——否则统计
  /// 只统计成功的动作，而"用户点了拒绝但保存失败"恰恰是需要被看见的情况。
  Future<void> _recorded(
    String action,
    String suggestionId,
    Future<void> Function() perform,
  ) async {
    widget.onSuggestionAction?.call(action, suggestionId);
    await perform();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('学习偏好')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '由你决定哪些规律生效',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            const Text('只分析非特殊日的已确认记录。学习结果仅影响软偏好，不会改变最低睡眠、用餐保护或每日上限。'),
            const SizedBox(height: 18),
            if (_loading) const LinearProgressIndicator(),
            if (!_loading && _suggestions.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('目前还没有达到证据门槛的建议。'),
                ),
              ),
            for (final suggestion in _suggestions)
              _SuggestionCard(
                suggestion: suggestion,
                onConfirm: () => _act(() => _recorded(
                  'accepted',
                  suggestion.id,
                  () => widget.service.confirm(suggestion.id),
                )),
                onReject: () => _act(() => _recorded(
                  'rejected',
                  suggestion.id,
                  () => widget.service.reject(suggestion.id),
                )),
                onDisable: () => _act(() => _recorded(
                  'disabled',
                  suggestion.id,
                  () => widget.service.disable(suggestion.id),
                )),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    await widget.service.undoLastAutoApply();
                    await _reload();
                  },
                  icon: const Icon(Icons.undo),
                  label: const Text('撤销上次自动更新'),
                ),
                TextButton.icon(
                  onPressed: () => _act(widget.service.clearLearned),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清除学习结果'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

final class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.onConfirm,
    required this.onReject,
    required this.onDisable,
  });

  final PreferenceSuggestion suggestion;
  final VoidCallback onConfirm;
  final VoidCallback onReject;
  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('yyyy-MM-dd');
    final difference = (suggestion.effectDifference * 100).round();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title(suggestion),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '${suggestion.evidenceCount} 条记录 · '
              '${suggestion.activeDayCount} 个活跃日 · 效果差 $difference%',
            ),
            Text(
              '${format.format(suggestion.observedFromUtc)} 至 '
              '${format.format(suggestion.observedToUtc)} · '
              '${suggestion.explanationCode}',
            ),
            const SizedBox(height: 8),
            Text(_status(suggestion.status)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              children: [
                FilledButton(
                  onPressed:
                      suggestion.status == PreferenceSuggestionStatus.confirmed
                      ? null
                      : onConfirm,
                  child: const Text('确认采用'),
                ),
                OutlinedButton(onPressed: onReject, child: const Text('拒绝')),
                TextButton(onPressed: onDisable, child: const Text('停用')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _title(PreferenceSuggestion suggestion) => switch (suggestion.kind) {
  PreferenceSuggestionKind.preferredTimeWindow =>
    '建议优先安排在 ${_minute(suggestion.suggestedStartMinute!)}—'
        '${_minute(suggestion.suggestedEndMinute!)}',
  PreferenceSuggestionKind.preferredFocusMinutes =>
    '建议专注片段 ${suggestion.suggestedFocusMinutes} 分钟',
};

String _status(PreferenceSuggestionStatus status) => switch (status) {
  PreferenceSuggestionStatus.suggested => '等待你的决定',
  PreferenceSuggestionStatus.confirmed => '已确认',
  PreferenceSuggestionStatus.rejected => '已拒绝',
  PreferenceSuggestionStatus.disabled => '已停用',
  PreferenceSuggestionStatus.autoApplied => '已自动采用，可撤销',
};

String _minute(int value) =>
    '${(value ~/ 60).toString().padLeft(2, '0')}:'
    '${(value % 60).toString().padLeft(2, '0')}';
