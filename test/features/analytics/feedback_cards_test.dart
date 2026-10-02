import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/models/feedback_message.dart';
import 'package:personal_planner/features/analytics/feedback_cards.dart';

void main() {
  testWidgets('反馈卡说明统计范围，可隐藏且文案保持中性', (tester) async {
    final messages = [
      FeedbackMessage(
        code: FeedbackCode.lifeQuotaReached,
        tone: FeedbackTone.achievement,
        parameters: const {'actualMinutes': 400, 'targetMinutes': 360},
        evidence: const [
          FeedbackEvidence(code: 'lifeQuotaProgress', value: 400 / 360),
        ],
      ),
      FeedbackMessage(
        code: FeedbackCode.estimateReviewSuggested,
        tone: FeedbackTone.suggestion,
        parameters: const {'differencePercent': 50},
        evidence: const [
          FeedbackEvidence(code: 'estimateVariance', value: 0.5),
        ],
      ),
    ];
    final filter = AnalyticsFilter(
      startUtc: DateTime.utc(2026, 10, 1),
      endUtc: DateTime.utc(2026, 10, 8),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedbackCards(messages: messages, filter: filter),
        ),
      ),
    );

    expect(find.textContaining('2026-10-01 至 2026-10-07'), findsOneWidget);
    expect(find.textContaining('400 / 360 分钟'), findsOneWidget);
    final allText = tester
        .widgetList<Text>(find.byType(Text))
        .map((item) => item.data ?? '')
        .join(' ');
    for (final banned in ['失败', '偷懒', '惩罚', '落后', '扣分', '不自律']) {
      expect(allText, isNot(contains(banned)));
    }

    await tester.tap(find.byKey(const Key('hide-feedback-lifeQuotaReached')));
    await tester.pump();

    expect(find.textContaining('400 / 360 分钟'), findsNothing);
    expect(find.textContaining('实际用时与原预估相差 50%'), findsOneWidget);
  });
}
