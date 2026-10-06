import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/application/repository_schedule_problem_source.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_academic_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_life_area_lookup.dart';
import 'package:personal_planner/data/repositories/drift_plan_repository.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';
import 'package:personal_planner/data/repositories/drift_timetable_import_repository.dart';
import 'package:personal_planner/data/repositories/drift_workspace_repository.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';
import 'package:personal_planner/scheduling/schedule_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('本地识别、导入、避让课程和整批撤销形成闭环', (tester) async {
    const timeZoneId = 'Asia/Shanghai';
    final zones = TimeZoneDatabase();
    final clock = _FixedClock(DateTime.utc(2026, 10, 5));
    final ids = _Ids();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final calendar = DriftCalendarRepository(database);
    final tasks = DriftTaskRepository(database.taskDao);
    final plans = DriftPlanRepository(database, clock: clock);
    final settingsRepository = DriftSettingsRepository(database, clock);
    final settings = SettingsService(repository: settingsRepository);
    final workspaceRepository = DriftWorkspaceRepository(database);
    final workspace = WorkspaceService(
      repository: workspaceRepository,
      clock: clock,
      idGenerator: ids,
    );
    await workspace.ensureDefaultAreas();
    final changes = <ScheduleInputChange>[];
    final importService = TimetableImportService(
      calendarRepository: calendar,
      zones: zones,
      importRepository: DriftTimetableImportRepository(
        database,
        now: clock.nowUtc,
      ),
      onScheduleInputChanged: changes.add,
    );
    final controller = TimetableImportController(
      ocrEngine: const _FixtureOcr(),
      academicCalendar: AcademicCalendarService(
        repository: DriftAcademicCalendarRepository(database),
        clock: clock,
        idGenerator: ids,
      ),
      importService: importService,
      workspace: workspace,
      timeZoneId: timeZoneId,
      referenceDate: DateTime(2026, 10, 5),
      imagePicker: const _Picker(r'G:\fixtures\timetable.png'),
      clock: clock,
      idGenerator: ids,
      imageHasher: (_) async => 'fixture-sha256',
    );

    await controller.initialize();
    await controller.pickAndRecognize();
    expect(controller.draft!.courses, hasLength(1));
    expect(controller.draft!.courses.single.reviewReasons, isEmpty);
    await controller.buildPreview();
    expect(controller.preview!.occurrences, hasLength(2));
    final batch = await controller.commit();
    expect(batch, isNotNull);
    expect(changes.single.label, '导入课表');

    final windowStart = zones.localMidnightToUtc(
      DateTime(2026, 10, 5),
      timeZoneId,
    );
    final windowEnd = zones.localMidnightToUtc(
      DateTime(2026, 10, 19),
      timeZoneId,
    );
    final imported = await calendar.occurrencesBetween(windowStart, windowEnd);
    expect(imported, hasLength(2));

    final study = (await workspace.listAreas()).firstWhere(
      (area) => area.name == '学业',
    );
    final taskResult =
        await TaskService(
          repository: tasks,
          workspace: workspaceRepository,
          clock: clock,
          idGenerator: ids,
        ).saveDraft(
          TaskDraft(title: '完成课程作业', estimatedMinutes: 120, areaId: study.id),
        );
    expect(taskResult.isSuccess, isTrue);

    final source = RepositoryScheduleProblemSource(
      tasks: tasks,
      lifeAreas: DriftLifeAreaLookup(database),
      calendar: calendar,
      settings: settings,
      plans: plans,
      clock: clock,
      timeZoneId: timeZoneId,
      zones: zones,
    );
    final planning = PlanningService(
      source: source,
      engine: DeterministicScheduleEngine(zones),
    );
    final proposal = await planning.createProposal();
    final taskBlocks = proposal.blocks
        .where((block) => block.taskId == taskResult.task!.id)
        .toList();
    expect(taskBlocks, isNotEmpty);
    for (final block in taskBlocks) {
      for (final course in imported) {
        expect(block.range.overlaps(course.range), isFalse);
      }
    }

    await importService.rollback(batch!.id);
    expect(changes.map((change) => change.label), ['导入课表', '撤销课表导入']);
    expect(await calendar.occurrencesBetween(windowStart, windowEnd), isEmpty);

    final replanned = await planning.createProposal();
    expect(
      replanned.blocks.where((block) => block.taskId == taskResult.task!.id),
      isNotEmpty,
    );
    expect((await source.load()).fixedIntervals, isEmpty);
  });
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var value = 0;
  @override
  String next() => 'flow-${value++}';
}

final class _Picker implements TimetableImagePicker {
  const _Picker(this.path);
  final String path;
  @override
  Future<String?> pickImage() async => path;
}

final class _FixtureOcr implements TimetableOcrEngine {
  const _FixtureOcr();

  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async =>
      const OcrDocument(
        width: 500,
        height: 400,
        textAngle: null,
        lines: [
          OcrLine(
            text: '星期一',
            words: [
              OcrWord(
                text: '星期一',
                bounds: OcrRect(left: 100, top: 10, width: 80, height: 20),
              ),
            ],
          ),
          OcrLine(
            text: '星期二',
            words: [
              OcrWord(
                text: '星期二',
                bounds: OcrRect(left: 220, top: 10, width: 80, height: 20),
              ),
            ],
          ),
          OcrLine(
            text: '1',
            words: [
              OcrWord(
                text: '1',
                bounds: OcrRect(left: 20, top: 80, width: 20, height: 20),
              ),
            ],
          ),
          OcrLine(
            text: '2',
            words: [
              OcrWord(
                text: '2',
                bounds: OcrRect(left: 20, top: 140, width: 20, height: 20),
              ),
            ],
          ),
          OcrLine(
            text: '大学物理\n张震\n1-2周\nA402',
            words: [
              OcrWord(
                text: '大学物理',
                bounds: OcrRect(left: 105, top: 72, width: 70, height: 24),
              ),
              OcrWord(
                text: '张震',
                bounds: OcrRect(left: 120, top: 100, width: 36, height: 20),
              ),
              OcrWord(
                text: '1-2周',
                bounds: OcrRect(left: 112, top: 126, width: 50, height: 20),
              ),
              OcrWord(
                text: 'A402',
                bounds: OcrRect(left: 118, top: 152, width: 40, height: 20),
              ),
            ],
          ),
        ],
      );
}
