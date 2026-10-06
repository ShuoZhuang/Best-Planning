import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_page.dart';

void main() {
  testWidgets('本机缺少中文 OCR 时保留图片并提供手动录入', (tester) async {
    tester.view.physicalSize = const Size(800, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.languageUnavailable),
      picker: const _Picker(r'G:\screens\schedule.png'),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: TimetableImportPage(
          controller: controller,
          onCancel: () {},
          onCompleted: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-timetable-image')));
    await tester.pumpAndSettle();

    expect(find.text('schedule.png'), findsOneWidget);
    expect(find.textContaining('本机未安装简体中文 OCR'), findsOneWidget);
    expect(find.byKey(const Key('manual-timetable-entry')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('图片读取失败时提示重新选择或检查文件位置', () async {
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.decodeFailed),
      picker: const _Picker(r'F:\downloads\schedule.jpg'),
    );
    await controller.initialize();

    await controller.pickAndRecognize();

    expect(
      controller.errorMessage,
      '无法读取这张图片。请确认文件没有被移动或删除，也可以重新选择 PNG 或 JPG。',
    );
  });

  testWidgets('后退步骤保留已编辑的课程', (tester) async {
    final controller = _controller();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: TimetableImportPage(
          controller: controller,
          onCancel: () {},
          onCompleted: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-timetable-entry')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();

    final course = controller.draft!.courses.single;
    await tester.enterText(
      find.byKey(Key('course-name-${course.id}')),
      '算法与数据结构',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
    expect(find.text('确认学期'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wizard-previous')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '算法与数据结构'), findsOneWidget);
  });

  testWidgets('800px 窗口可完整走到预览且不溢出', (tester) async {
    tester.view.physicalSize = const Size(800, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: TimetableImportPage(
          controller: controller,
          onCancel: () {},
          onCompleted: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manual-timetable-entry')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
    final course = controller.draft!.courses.single;
    await tester.enterText(find.byKey(Key('course-name-${course.id}')), '大学物理');
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();

    expect(find.text('预览并确认'), findsOneWidget);
    expect(find.byKey(const Key('commit-timetable-import')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('当前周数与第一周周一可以双向换算', () async {
    final controller = _controller();
    await controller.initialize();

    controller.setCurrentWeek(5);
    expect(controller.firstWeekMonday, DateTime(2026, 9, 7));
    controller.setFirstWeekMonday(DateTime(2026, 9, 14));
    expect(controller.currentWeek, 4);
  });

  test('未解决校对项时不允许最终提交', () async {
    final controller = _controller();
    await controller.initialize();
    controller.startManualEntry();
    expect(controller.hasUnresolvedReviews, isTrue);

    final course = controller.draft!.courses.single;
    controller.updateCourse(course.copyWith(name: '大学物理'));
    await controller.buildPreview();
    expect(controller.preview, isNotNull);
    expect(controller.hasUnresolvedReviews, isFalse);
    expect(controller.canCommit, isTrue);
  });

  test('解析时若领域还没读出来，预览前会补上默认领域（学业）', () async {
    // 真实顺序就是这样：进页面就并发 `initialize()`，而它是异步的，用户可能在它完成前
    // 就上传图片。解析那一刻 `areas` 为空 → 课程归属写成 null，而它**只写那一次**，
    // 于是导进来的课永远没有领域（用户反馈：导入的课程不属于学业）。
    final controller = _controller();
    controller.startManualEntry();
    final course = controller.draft!.courses.single;
    expect(course.areaId, isNull, reason: '构造时尚未读领域，模拟"解析早于 initialize 完成"');
    controller.updateCourse(course.copyWith(name: '大学物理'));

    await controller.initialize();
    await controller.buildPreview();

    expect(controller.draft!.courses.single.areaId, 'area-study');
    expect(controller.preview!.series.single.event.areaId, 'area-study');
  });

  test('补齐默认领域是幂等的：已选过领域的课程不会被改动', () async {
    final controller = _controller();
    await controller.initialize();
    controller.startManualEntry();
    // 用户在审阅步骤把归属改成别的领域：再算一次预览不该被默认值改回去。
    controller.updateCourse(
      controller.draft!.courses.single.copyWith(
        name: '大学物理',
        areaId: 'area-lab',
      ),
    );
    await controller.buildPreview();

    expect(controller.draft!.courses.single.areaId, 'area-lab');
    expect(controller.preview!.series.single.event.areaId, 'area-lab');
  });
}

TimetableImportController _controller({
  TimetableOcrEngine ocr = const _EmptyOcr(),
  TimetableImagePicker picker = const _Picker(null),
}) {
  final clock = _Clock();
  final ids = _Ids();
  return TimetableImportController(
    ocrEngine: ocr,
    academicCalendar: AcademicCalendarService(
      repository: _AcademicRepository(),
      clock: clock,
      idGenerator: ids,
    ),
    importService: TimetableImportService(
      calendarRepository: const _CalendarRepository(),
      zones: TimeZoneDatabase(),
    ),
    workspace: WorkspaceService(
      repository: _WorkspaceRepository(),
      clock: clock,
      idGenerator: ids,
    ),
    timeZoneId: 'Asia/Shanghai',
    referenceDate: DateTime(2026, 10, 5),
    imagePicker: picker,
    clock: clock,
    idGenerator: ids,
    imageHasher: (_) async => 'hash',
  );
}

final class _Picker implements TimetableImagePicker {
  const _Picker(this.path);
  final String? path;
  @override
  Future<String?> pickImage() async => path;
}

final class _FailingOcr implements TimetableOcrEngine {
  const _FailingOcr(this.code);
  final TimetableOcrFailureCode code;
  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async =>
      throw TimetableOcrException(code);
}

final class _EmptyOcr implements TimetableOcrEngine {
  const _EmptyOcr();
  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async =>
      const OcrDocument(width: 1, height: 1, textAngle: null, lines: []);
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 5);
}

final class _Ids implements IdGenerator {
  var value = 0;
  @override
  String next() => 'id-${value++}';
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
  final terms = <AcademicTerm>[];
  final templates = <PeriodTemplate>[];
  @override
  Future<List<AcademicTerm>> listTerms() async => [...terms];
  @override
  Future<List<PeriodTemplate>> listTemplates() async => [...templates];
  @override
  Future<void> saveTerm(AcademicTerm term) async => terms.add(term);
  @override
  Future<void> saveTemplate(PeriodTemplate template) async =>
      templates.add(template);
  @override
  Future<void> setDefaultTemplate(
    String templateId,
    DateTime updatedAtUtc,
  ) async {}
}

final class _WorkspaceRepository implements WorkspaceRepository {
  final areas = [
    PlannerArea(
      id: 'area-study',
      name: '学业',
      color: 0,
      sortOrder: 0,
      createdAtUtc: DateTime.utc(2026),
      updatedAtUtc: DateTime.utc(2026),
    ),
    // 第二个领域：让"用户把课程改到别的领域"是一个真实存在的选择。
    PlannerArea(
      id: 'area-lab',
      name: '科研',
      color: 0,
      sortOrder: 1,
      createdAtUtc: DateTime.utc(2026),
      updatedAtUtc: DateTime.utc(2026),
    ),
  ];
  @override
  Future<List<PlannerArea>> listAreas() async => [...areas];
  @override
  Future<List<PlannerProject>> listProjects() async => const [];
  @override
  Future<void> saveArea(PlannerArea area) async {}
  @override
  Future<void> saveProject(PlannerProject project) async {}
}
