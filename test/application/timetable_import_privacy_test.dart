import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show AppDatabase;
import 'package:personal_planner/data/repositories/drift_export_data_source.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/repositories/academic_calendar_repository.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';

void main() {
  test(
    'database and structured export retain only image hash and base name',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await database.customInsert(
        "INSERT INTO areas (id, name, color, sort_order, is_life, created_at_utc, updated_at_utc) VALUES ('study', '学业', 0, 0, 0, 1, 1)",
      );
      await database.customInsert(
        "INSERT INTO academic_terms (id, name, first_week_monday_local_date, total_weeks, time_zone_id, created_at_utc, updated_at_utc) VALUES ('term', '秋季学期', '2026-10-05', 16, 'Asia/Shanghai', 1, 1)",
      );
      final start = DateTime.utc(2026, 10, 5);
      await DriftTimetableImportRepository(database).commit(
        TimetableImportCommit(
          batchId: 'batch',
          termId: 'term',
          sourceImageHash: 'sha256-only',
          sourceFileName: r'G:\private\student-20261234\schedule.png',
          createdAtUtc: DateTime.utc(2026, 10, 6),
          series: [
            TimetableImportSeriesWrite(
              event: CalendarEvent(
                id: 'event',
                title: '大学物理',
                startAtUtc: start,
                endAtUtc: start.add(const Duration(minutes: 100)),
                timeZoneId: 'Asia/Shanghai',
                recurrenceRuleId: 'rule',
                areaId: 'study',
                sourceKind: CalendarEventSourceKind.timetableImport,
                importBatchId: 'batch',
                logicalCourseId: 'course',
                updatedAtUtc: DateTime.utc(2026, 10, 6),
              ),
              rule: RecurrenceRule(
                id: 'rule',
                weekdays: const {DateTime.monday},
                localStartMinute: 8 * 60,
                durationMinutes: 100,
                validFromLocalDate: DateTime(2026, 10, 5),
                validUntilLocalDate: DateTime(2026, 12, 21),
                timeZoneId: 'Asia/Shanghai',
              ),
            ),
          ],
        ),
      );

      final batch = await database
          .select(database.timetableImportBatches)
          .getSingle();
      expect(batch.sourceFileName, 'schedule.png');
      final export = jsonEncode(
        await DriftExportDataSource(database).loadAllFacts(),
      );
      expect(export, contains('schedule.png'));
      expect(export, contains('sha256-only'));
      expect(export, isNot(contains(r'G:\private')));
      expect(export, isNot(contains('student-20261234')));
    },
  );

  test(
    'OCR failure shown to the user never echoes the selected private path',
    () async {
      const privatePath = r'G:\private\student-20261234\schedule.png';
      final clock = _Clock();
      final ids = _Ids();
      final controller = TimetableImportController(
        ocrEngine: const _LeakyFailureOcr(privatePath),
        academicCalendar: AcademicCalendarService(
          repository: _AcademicRepository(),
          clock: clock,
          idGenerator: ids,
        ),
        importService: TimetableImportService(
          calendarRepository: const _EmptyCalendar(),
          zones: TimeZoneDatabase(),
        ),
        workspace: WorkspaceService(
          repository: _WorkspaceRepository(),
          clock: clock,
          idGenerator: ids,
        ),
        timeZoneId: 'Asia/Shanghai',
        referenceDate: DateTime(2026, 10, 5),
        imagePicker: const _Picker(privatePath),
      );
      await controller.initialize();
      await controller.pickAndRecognize();

      expect(controller.selectedImagePath, privatePath, reason: '向导内存中应保留选图状态');
      expect(controller.errorMessage, isNot(contains(privatePath)));
      expect(controller.errorMessage, isNot(contains('student-20261234')));
    },
  );
}

final class _LeakyFailureOcr implements TimetableOcrEngine {
  const _LeakyFailureOcr(this.path);
  final String path;
  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async =>
      throw TimetableOcrException(
        TimetableOcrFailureCode.recognitionFailed,
        path,
      );
}

final class _Picker implements TimetableImagePicker {
  const _Picker(this.path);
  final String path;
  @override
  Future<String?> pickImage() async => path;
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 6);
}

final class _Ids implements IdGenerator {
  var value = 0;
  @override
  String next() => 'privacy-${value++}';
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

final class _EmptyCalendar implements CalendarRepository {
  const _EmptyCalendar();

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _WorkspaceRepository implements WorkspaceRepository {
  @override
  Future<List<PlannerArea>> listAreas() async => const [];
  @override
  Future<List<PlannerProject>> listProjects() async => const [];
  @override
  Future<void> saveArea(PlannerArea area) async {}
  @override
  Future<void> saveProject(PlannerProject project) async {}
}
