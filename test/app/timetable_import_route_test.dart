import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/repositories/academic_calendar_repository.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';

void main() {
  testWidgets('从七日日历可以打开五步课表导入页', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    await settings.write(
      OnboardingPage.schemaVersionKey,
      OnboardingPage.currentSchemaVersion.toString(),
    );
    // 首次教程闸门与首次引导是同一条套路（设置键 + 版本比较）。不喂这一条，
    // 整应用 pump 出来的会是教程页而不是主界面——教程自身的用例在 test/features/tutorial/。
    // ignore: unused_local_variable
    await settings.write(
      TutorialPage.seenKey,
      TutorialPage.currentVersion.toString(),
    );
    final clock = const _Clock();
    final ids = _Ids();
    await tester.pumpWidget(
      ProviderScope(
        child: PlannerApp(
          timeZoneId: 'Asia/Shanghai',
          settingsRepository: settings,
          timetableOcr: const _Ocr(),
          timetableImport: TimetableImportService(
            calendarRepository: const _CalendarRepository(),
            zones: TimeZoneDatabase(),
          ),
          academicCalendar: AcademicCalendarService(
            repository: _AcademicRepository(),
            clock: clock,
            idGenerator: ids,
          ),
          workspaceService: WorkspaceService(
            repository: _WorkspaceRepository(),
            clock: clock,
            idGenerator: ids,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('日历'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-timetable')));
    await tester.pumpAndSettle();

    expect(find.byType(TimetableImportPage), findsOneWidget);
    expect(find.text('导入课表'), findsWidgets);
    expect(find.text('上传课表'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable-import-back')));
    await tester.pumpAndSettle();
    expect(find.text('七日日历'), findsOneWidget);
  });
}

final class _Ocr implements TimetableOcrEngine {
  const _Ocr();
  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async =>
      const OcrDocument(width: 1, height: 1, textAngle: null, lines: []);
}

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5);
}

final class _Ids implements IdGenerator {
  var value = 0;
  @override
  String next() => 'route-id-${value++}';
}

final class _CalendarRepository implements CalendarRepository {
  const _CalendarRepository();
  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];
  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _AcademicRepository implements AcademicCalendarRepository {
  @override
  Future<List<AcademicTerm>> listTerms() async => const [];
  @override
  Future<List<PeriodTemplate>> listTemplates() async => const [];
  @override
  Future<void> saveTerm(AcademicTerm term) async {}
  @override
  Future<void> saveTemplate(PeriodTemplate template) async {}
  @override
  Future<void> setDefaultTemplate(
    String templateId,
    DateTime updatedAtUtc,
  ) async {}
}

final class _WorkspaceRepository implements WorkspaceRepository {
  @override
  Future<List<PlannerArea>> listAreas() async => [
    PlannerArea(
      id: 'study',
      name: '学业',
      color: 0,
      sortOrder: 0,
      createdAtUtc: DateTime.utc(2026),
      updatedAtUtc: DateTime.utc(2026),
    ),
  ];
  @override
  Future<List<PlannerProject>> listProjects() async => const [];
  @override
  Future<void> saveArea(PlannerArea area) async {}
  @override
  Future<void> saveProject(PlannerProject project) async {}
}
