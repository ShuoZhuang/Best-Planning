import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/features/calendar/special_day/special_day_page.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';

void main() {
  testWidgets('特殊日页面展示四种处理方式和各自影响', (tester) async {
    SpecialDayDraft? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: SpecialDayPage(
          recoveryDate: DateTime(2026, 10, 3),
          rules: DefaultSettings.v1(),
          timeZoneId: 'UTC',
          fixedEvents: const [],
          onCreateOverride: (draft) async {
            submitted = draft;
            return _result();
          },
        ),
      ),
    );

    expect(find.text('重新安排可移动任务'), findsOneWidget);
    expect(find.text('取消次日可移动任务'), findsOneWidget);
    expect(find.text('安排补觉'), findsOneWidget);
    expect(find.text('单次接受较短睡眠'), findsOneWidget);
    expect(find.textContaining('不会修改长期作息'), findsWidgets);

    final shorterSleep = find.text('单次接受较短睡眠');
    await tester.ensureVisible(shorterSleep);
    await tester.tap(shorterSleep);
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('accepted-sleep-minutes')),
      '360',
    );
    final createButton = find.text('生成恢复方案');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(submitted?.resolution, RecoveryResolution.acceptShorterSleep);
    expect(submitted?.acceptedSleepMinutes, 360);
    // 文案必须与真实行为一致：例外只用于本次方案，预览不会留下持久设置。
    expect(find.text('恢复保护已用于本次方案'), findsOneWidget);
    expect(find.text('仅作用于本次生成的计划，不会写入长期作息偏好。'), findsOneWidget);
  });

  testWidgets('最低睡眠与早课冲突时明确保留早课', (tester) async {
    final earlyClass = CalendarOccurrence(
      eventId: 'class-1',
      title: '早课',
      range: TimeRange(
        startUtc: DateTime.utc(2026, 10, 2, 23, 30),
        endUtc: DateTime.utc(2026, 10, 3, 1),
      ),
      locked: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SpecialDayPage(
          recoveryDate: DateTime(2026, 10, 3),
          rules: DefaultSettings.v1(),
          timeZoneId: 'UTC',
          fixedEvents: [earlyClass],
          onCreateOverride: (_) async => _result(
            conflicts: [
              PlanningConflict(
                code: ConflictCode.minimumSleepConflict,
                relatedEntityIds: const ['class-1'],
              ),
            ],
            fixedEvents: [earlyClass],
          ),
        ),
      ),
    );

    final createButton = find.text('生成恢复方案');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(find.text('最低睡眠与不可移动早课冲突'), findsOneWidget);
    expect(find.text('已保留：早课'), findsOneWidget);
  });
}

RecoveryPlan _result({
  List<PlanningConflict> conflicts = const [],
  List<CalendarOccurrence> fixedEvents = const [],
}) => RecoveryPlan(
  recoveryDate: DateTime(2026, 10, 3),
  earliestSchedulableUtc: DateTime.utc(2026, 10, 3),
  sleepProtection: TimeRange(
    startUtc: DateTime.utc(2026, 10, 2, 17),
    endUtc: DateTime.utc(2026, 10, 3),
  ),
  conflicts: conflicts,
  fixedEventsToKeep: fixedEvents,
  proposalId: 'proposal',
);
