import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

final class PreferencesPage extends StatefulWidget {
  const PreferencesPage({required this.service, super.key});

  final PreferenceService service;

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
                onConfirm: () =>
                    _act(() => widget.service.confirm(suggestion.id)),
                onReject: () =>
                    _act(() => widget.service.reject(suggestion.id)),
                onDisable: () =>
                    _act(() => widget.service.disable(suggestion.id)),
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
