import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/feedback_message.dart';

final class FeedbackCards extends StatefulWidget {
  const FeedbackCards({
    required this.messages,
    required this.filter,
    super.key,
  });

  final List<FeedbackMessage> messages;
  final AnalyticsFilter filter;

  @override
  State<FeedbackCards> createState() => _FeedbackCardsState();
}

final class _FeedbackCardsState extends State<FeedbackCards> {
  final _hidden = <FeedbackCode>{};

  @override
  Widget build(BuildContext context) {
    final visible = widget.messages
        .where((message) => !_hidden.contains(message.code))
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();
    final format = DateFormat('yyyy-MM-dd');
    final end = widget.filter.endUtc.subtract(const Duration(days: 1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本期反馈', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '依据 ${format.format(widget.filter.startUtc)} 至 '
          '${format.format(end)} 的已确认记录生成；隐藏仅影响显示。',
        ),
        const SizedBox(height: 10),
        for (final message in visible)
          Card(
            color: _background(context, message.tone),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_icon(message.tone)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(message.code),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(_body(message)),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('hide-feedback-${message.code.name}'),
                    tooltip: '隐藏这条反馈',
                    onPressed: () => setState(() => _hidden.add(message.code)),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

Color _background(BuildContext context, FeedbackTone tone) => switch (tone) {
  FeedbackTone.achievement => Theme.of(context).colorScheme.primaryContainer,
  FeedbackTone.suggestion => Theme.of(context).colorScheme.tertiaryContainer,
  FeedbackTone.observation => Theme.of(
    context,
  ).colorScheme.surfaceContainerHigh,
};

IconData _icon(FeedbackTone tone) => switch (tone) {
  FeedbackTone.achievement => Icons.celebration_outlined,
  FeedbackTone.suggestion => Icons.lightbulb_outline,
  FeedbackTone.observation => Icons.insights_outlined,
};

String _title(FeedbackCode code) => switch (code) {
  FeedbackCode.lifeQuotaReached => '生活时间已被认真照顾',
  FeedbackCode.actualInvestmentGrowth => '本期留下了更多真实投入记录',
  FeedbackCode.completionImproved => '完成节奏有所提升',
  FeedbackCode.onTimeImproved => '按期完成更稳定',
  FeedbackCode.estimateReviewSuggested => '可以用真实记录校准预估',
  FeedbackCode.interruptionPattern => '发现了重复出现的中断',
  FeedbackCode.planActualClose => '计划与实际较为接近',
};

String _body(FeedbackMessage message) {
  final values = message.parameters;
  return switch (message.code) {
    FeedbackCode.lifeQuotaReached =>
      '生活与娱乐时间达到 ${values['actualMinutes']} / '
          '${values['targetMinutes']} 分钟，给恢复精力留出了空间。',
    FeedbackCode.actualInvestmentGrowth =>
      '本期确认了 ${values['currentMinutes']} 分钟实际投入，'
          '比对比期增加 ${values['deltaMinutes']} 分钟。',
    FeedbackCode.completionImproved =>
      '完成率从 ${values['previousNumerator']} / '
          '${values['previousDenominator']} 变化为 '
          '${values['currentNumerator']} / ${values['currentDenominator']}。',
    FeedbackCode.onTimeImproved =>
      '按期完成从 ${values['previousNumerator']} / '
          '${values['previousDenominator']} 变化为 '
          '${values['currentNumerator']} / ${values['currentDenominator']}。',
    FeedbackCode.estimateReviewSuggested =>
      '实际用时与原预估相差 ${values['differencePercent']}%，'
          '下次可以参考这段真实记录调整预估。',
    FeedbackCode.interruptionPattern =>
      '同类中断出现 ${values['count']} 次，可以考虑提前留出应对空间。',
    FeedbackCode.planActualClose =>
      '计划 ${values['plannedMinutes']} 分钟，实际 '
          '${values['actualMinutes']} 分钟。',
  };
}
