import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/features/settings/academic_calendar/academic_calendar_page.dart';

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5);
}

final class _Ids implements IdGenerator {
  var count = 0;
  @override
  String next() => 'id-${++count}';
}

void main() {
  late AppDatabase database;
  late AcademicCalendarService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = AcademicCalendarService(
      repository: DriftAcademicCalendarRepository(database),
      clock: _Clock(),
      idGenerator: _Ids(),
    );
  });

  tearDown(() => database.close());

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AcademicCalendarPage(
          service: service,
          referenceDate: DateTime(2026, 10, 5),
          timeZoneId: 'Asia/Shanghai',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('当前周数与第一周星期一双向换算', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const Key('academic-current-week')), '5');
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('academic-first-monday')))
          .controller!
          .text,
      '2026-09-07',
    );

    await tester.enterText(
      find.byKey(const Key('academic-first-monday')),
      '2026-09-14',
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('academic-current-week')))
          .controller!
          .text,
      '4',
    );
  });

  testWidgets('节次可批量生成、逐行修改并以内联错误阻止保存', (tester) async {
    await pump(tester);

    await tester.enterText(find.byKey(const Key('period-count')), '2');
    await tester.tap(find.text('批量生成'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('period-start-1')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('period-start-2')), '08:30');
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存节次模板'));
    await tester.pumpAndSettle();

    expect(find.textContaining('overlap'), findsOneWidget);
    expect(await service.listTemplates(), isEmpty);
  });
}
