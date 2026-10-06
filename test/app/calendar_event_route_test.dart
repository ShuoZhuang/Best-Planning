import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';

void main() {
  testWidgets('从日历新建固定日程，保存后返回周视图', (tester) async {
    final repository = _MemoryCalendarRepository();
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          calendar: repository,
          calendarService: CalendarService(
            repository: repository,
            recurringRepository: repository,
            clock: const _Clock(),
            idGenerator: _Ids(),
            zones: TimeZoneDatabase(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-calendar-event')));
    await tester.pumpAndSettle();

    expect(find.text('新建固定日程'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('event-title')), '周末聚餐');
    await tester.tap(find.text('保存日程'));
    await tester.pumpAndSettle();

    expect(repository.saved, hasLength(1));
    expect(repository.saved.single.title, '周末聚餐');
    expect(repository.saved.single.timeZoneId, 'Asia/Shanghai');
    expect(find.text('七日日历'), findsOneWidget);
  });
}

final class _MemoryCalendarRepository
    implements CalendarRepository, RecurringCalendarRepository {
  final List<CalendarEvent> saved = [];

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async => saved.add(event);

  @override
  Future<void> saveRecurring(CalendarEvent event, RecurrenceRule rule) async {
    saved.add(event);
  }
}

final class _Clock implements Clock {
  const _Clock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 3);
}

final class _Ids implements IdGenerator {
  var _next = 0;

  @override
  String next() => 'event-${_next++}';
}
