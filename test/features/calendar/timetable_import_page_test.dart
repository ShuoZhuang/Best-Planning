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

    expect(controller.errorMessage, contains('schedule.jpg'));
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // M6（路线图 §10「错误恢复」）解码失败要能自查。
  // 规格：`docs/superpowers/specs/2026-10-07-m6-timetable-import-reliability.md`
  // ─────────────────────────────────────────────────────────────────────────────

  test('M6 解码失败的消息同时给出**文件名**与**支持的格式**', () async {
    // §10：「无法解码图片时显示文件名、支持格式和'更换图片'，不得只显示系统异常文本」。
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.decodeFailed),
      picker: const _Picker(r'F:\downloads\我的课表.png'),
    );
    await controller.initialize();
    await controller.pickAndRecognize();

    final message = controller.errorMessage!;
    expect(message, contains('我的课表.png'), reason: '要写出是哪个文件读不了');
    for (final format in const ['PNG', 'JPG', 'JPEG']) {
      expect(message, contains(format), reason: '要写清支持哪些格式，用户才知道该换什么');
    }
  });

  test('M6 解码失败的消息**不暴露目录路径**，只给文件名', () async {
    // 只取文件名而不是完整路径有两个理由：
    // ① §10 同时要求"图片原件不写入数据库、不上传"，把完整路径摆在界面上没有必要；
    // ② 那是用户机器上的目录结构，截图或录屏时会跟着外泄。
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.decodeFailed),
      picker: const _Picker(r'F:\downloads\私密目录\我的课表.png'),
    );
    await controller.initialize();
    await controller.pickAndRecognize();

    final message = controller.errorMessage!;
    expect(message, contains('我的课表.png'));
    expect(
      message,
      isNot(contains(r'F:\downloads')),
      reason: '不该把用户机器上的完整目录摆到界面上，实际=$message',
    );
    expect(message, isNot(contains('私密目录')), reason: '父目录名也不该出现');
  });

  test('M6 图片过大时也给出文件名与"更换图片"的指引', () async {
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.imageTooLarge),
      picker: const _Picker(r'G:\screens\big.png'),
    );
    await controller.initialize();
    await controller.pickAndRecognize();

    expect(controller.errorMessage, contains('big.png'));
  });

  test('M6 原始异常文本不得出现在提示里（§10 最后一条退出条件）', () async {
    // 这条对应 §10 退出条件："图片读取失败不再暴露 PathAccessException 等原始异常"。
    // 用一个**带路径、且异常文本很长**的异常来模拟底层读取失败，
    // 断言界面上看不到异常类型名，也看不到那串路径。
    final controller = _controller(
      ocr: const _ThrowingOcr(
        r'PathAccessException: Cannot open file, path = '
        r"'C:\Users\someone\Documents\课表.png' (OS Error: 拒绝访问。, errno = 5)",
      ),
      picker: const _Picker(r'C:\Users\someone\Documents\课表.png'),
    );
    await controller.initialize();
    await controller.pickAndRecognize();

    final message = controller.errorMessage!;
    expect(
      message,
      isNot(contains('PathAccessException')),
      reason: '对用户来说异常类名毫无意义，不该出现在界面上。实际=$message',
    );
    expect(
      message,
      isNot(contains('OS Error')),
      reason: '系统错误码同样不该直接抛给用户。实际=$message',
    );
    expect(message, contains('课表.png'), reason: '但要告诉他是哪个文件');
  });

  testWidgets('M6 与图片有关的失败处**就地**给出「更换图片」', (tester) async {
    // §10：「图片读取失败时能换图、旋转、裁剪、重试或手动继续」。
    // 动作必须与解释在**同一处**，否则用户读完原因还要回头找按钮。
    final picker = _CountingPicker(r'G:\screens\broken.png');
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.decodeFailed),
      picker: picker,
    );
    await controller.initialize();
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

    expect(
      find.byKey(const Key('timetable-change-image')),
      findsOneWidget,
      reason: '解码失败时必须就地能换图',
    );
    // 手动录入也必须还在（§10："不能把用户困在上传步骤"）。
    expect(find.byKey(const Key('manual-timetable-entry')), findsOneWidget);

    final before = picker.calls;
    // **先滚到它**：失败提示在页面下方，800×760 的默认视口里"更换图片"落在视口外，
    // 直接 `tap` 会静默打空（只留一句 "would not hit test" 警告），
    // 断言就会报"calls 没变"——看起来像功能坏了，其实是没点到。
    await tester.ensureVisible(find.byKey(const Key('timetable-change-image')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable-change-image')));
    await tester.pumpAndSettle();
    expect(picker.calls, greaterThan(before), reason: '点"更换图片"要真的再去选一次图');
  });

  testWidgets('M6 与图片**无关**的失败不给「更换图片」', (tester) async {
    // 缺 OCR 语言、设备不支持 OCR 这些换图解决不了，给了反而把用户引到错的方向。
    final controller = _controller(
      ocr: const _FailingOcr(TimetableOcrFailureCode.languageUnavailable),
      picker: const _Picker(r'G:\screens\schedule.png'),
    );
    await controller.initialize();
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

    expect(
      find.byKey(const Key('timetable-change-image')),
      findsNothing,
      reason: '换一张图解决不了"本机没装中文 OCR"',
    );
    // 但手动录入仍要可用。
    expect(find.byKey(const Key('manual-timetable-entry')), findsOneWidget);
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

/// 记账用的选择器：用来证明"更换图片"真的又去选了一次。
final class _CountingPicker implements TimetableImagePicker {
  _CountingPicker(this.path);
  final String? path;
  int calls = 0;
  @override
  Future<String?> pickImage() async {
    calls++;
    return path;
  }
}

/// 抛出一个**不是** `TimetableOcrException` 的底层异常。
///
/// 用来钉住 §10 的退出条件"不再暴露 `PathAccessException` 等原始异常"：
/// 真实的读取失败会从引擎里以各种运行时异常形式冒出来，而界面**只能**给出人话。
final class _ThrowingOcr implements TimetableOcrEngine {
  const _ThrowingOcr(this.message);
  final String message;
  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async =>
      throw StateError(message);
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
