import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/domain/services/timetable_parser.dart';

abstract interface class TimetableImagePicker {
  Future<String?> pickImage();
}

final class FileSelectorTimetableImagePicker implements TimetableImagePicker {
  const FileSelectorTimetableImagePicker();

  @override
  Future<String?> pickImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '课表图片', extensions: ['png', 'jpg', 'jpeg']),
      ],
    );
    return file?.path;
  }
}

enum TimetableWizardStep { upload, review, term, periods, preview }

enum TimetableConflictChoice { keepPending, excludeOccurrence, skipCourse }

/// 一次导入的结果摘要。
///
/// **为什么要有它**：完成提示原先只报"共创建 N 组重复课程"。用户在校对步骤跳掉一门后，
/// 看到 16 门课只建了 15 组，只能把它当成缺陷——因为提示里没有"识别了多少、为什么少了"。
/// 把识别数与被跳过的原因一起摆出来，这个差值就不再需要用户反推。
final class TimetableImportOutcome {
  const TimetableImportOutcome({
    required this.batch,
    required this.recognizedCourses,
    required this.createdSeries,
    required this.skippedCourses,
    required this.duplicateCourses,
    required this.excludedOccurrences,
  });

  final TimetableImportBatch batch;

  /// 校对步骤里识别到的课程数（跳过的也算在内）。
  final int recognizedCourses;

  /// 实际写入的重复课程组数。
  final int createdSeries;

  /// 用户在冲突里选了"跳过该课程"的课程数。
  final int skippedCourses;

  /// 判定为重复、因而没有新建的课程数（按用户选择跳过或更新）。
  final int duplicateCourses;

  /// 被单次排除的出现次数。
  final int excludedOccurrences;

  String get message {
    final omitted = <String>[
      if (skippedCourses > 0) '跳过 $skippedCourses 门',
      if (duplicateCourses > 0) '重复未新建 $duplicateCourses 门',
    ];
    final exclusions = excludedOccurrences > 0
        ? '，另排除 $excludedOccurrences 次'
        : '';
    final explanation = omitted.isEmpty
        ? ''
        : '（识别 $recognizedCourses 门，${omitted.join('、')}）';
    return '课表已导入，共创建 $createdSeries 组重复课程$exclusions$explanation';
  }
}

final class TimetableImportController extends ChangeNotifier {
  TimetableImportController({
    required this.ocrEngine,
    required this.academicCalendar,
    required this.importService,
    required this.workspace,
    required this.timeZoneId,
    required DateTime referenceDate,
    this.parser = const TimetableParser(),
    this.imagePicker = const FileSelectorTimetableImagePicker(),
    this.clock = const SystemClock(),
    IdGenerator? idGenerator,
    Future<String> Function(String path)? imageHasher,
  }) : referenceDate = DateTime(
         referenceDate.year,
         referenceDate.month,
         referenceDate.day,
       ),
       _ids = idGenerator ?? UuidIdGenerator(),
       _imageHasher = imageHasher ?? _hashImage;

  final TimetableOcrEngine ocrEngine;
  final AcademicCalendarService academicCalendar;
  final TimetableImportService importService;
  final WorkspaceService workspace;
  final String timeZoneId;
  final TimetableParser parser;
  final TimetableImagePicker imagePicker;
  final Clock clock;
  final IdGenerator _ids;
  final Future<String> Function(String path) _imageHasher;

  TimetableWizardStep step = TimetableWizardStep.upload;
  bool initializing = true;
  bool recognizing = false;
  bool buildingPreview = false;
  bool committing = false;
  String? selectedImagePath;
  OcrCropRect? cropRect;
  int quarterTurns = 0;
  String? errorMessage;
  TimetableOcrFailureCode? ocrFailureCode;
  TimetableDraft? draft;
  TimetableImportPreview? preview;
  TimetableImportBatch? committedBatch;

  List<PlannerArea> areas = const [];
  List<PlannerProject> projects = const [];
  List<AcademicTerm> savedTerms = const [];
  List<PeriodTemplate> savedTemplates = const [];
  late DateTime referenceDate;
  late DateTime firstWeekMonday;
  int currentWeek = 1;
  int totalWeeks = 16;
  String termName = '';
  String? selectedTermId;
  String? selectedTemplateId;
  List<PeriodEntry> periodEntries = _defaultPeriods();
  final Set<String> skippedCourseIds = {};
  final Map<String, TimetableDuplicateResolution> duplicateChoices = {};
  final Map<int, TimetableConflictChoice> conflictChoices = {};

  String? get defaultAreaId {
    if (areas.isEmpty) return null;
    return areas
        .firstWhere(
          (area) => area.name.trim() == '学业',
          orElse: () => areas.first,
        )
        .id;
  }

  bool get hasUnresolvedReviews =>
      draft == null ||
      draft!.courses.any((course) => course.reviewReasons.isNotEmpty);

  bool get canContinue {
    switch (step) {
      case TimetableWizardStep.upload:
        return draft != null && draft!.courses.isNotEmpty && !recognizing;
      case TimetableWizardStep.review:
        return draft != null && draft!.courses.isNotEmpty;
      case TimetableWizardStep.term:
        return totalWeeks >= 1 &&
            totalWeeks <= 60 &&
            termName.trim().isNotEmpty;
      case TimetableWizardStep.periods:
        return periodValidationMessage == null && !buildingPreview;
      case TimetableWizardStep.preview:
        return canCommit;
    }
  }

  bool get canCommit =>
      preview != null &&
      !hasUnresolvedReviews &&
      !committing &&
      !buildingPreview;

  String? get periodValidationMessage {
    if (periodEntries.isEmpty) return '至少需要一节课的时间';
    final sorted = [...periodEntries]
      ..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    for (var index = 0; index < sorted.length; index++) {
      final entry = sorted[index];
      if (entry.startMinute >= entry.endMinute) return '每节课的结束时间必须晚于开始时间';
      if (index > 0 && entry.startMinute < sorted[index - 1].endMinute) {
        return '课程时间段不能互相重叠';
      }
    }
    return null;
  }

  Future<void> initialize() async {
    if (!initializing) return;
    try {
      final values = await Future.wait<Object>([
        workspace.listAreas(),
        workspace.listProjects(),
        academicCalendar.listTerms(),
        academicCalendar.listTemplates(),
      ]);
      areas = values[0] as List<PlannerArea>;
      projects = values[1] as List<PlannerProject>;
      savedTerms = values[2] as List<AcademicTerm>;
      savedTemplates = values[3] as List<PeriodTemplate>;
      _loadInitialAcademicSettings();
    } catch (_) {
      errorMessage = '暂时无法读取领域、学期或节次设置';
      _loadInitialAcademicSettings();
    } finally {
      initializing = false;
      notifyListeners();
    }
  }

  Future<void> pickAndRecognize() async {
    final path = await imagePicker.pickImage();
    if (path == null) return;
    selectedImagePath = path;
    await recognizeSelected();
  }

  Future<void> recognizeSelected() async {
    final path = selectedImagePath;
    if (path == null || recognizing) return;
    recognizing = true;
    errorMessage = null;
    ocrFailureCode = null;
    notifyListeners();
    try {
      final document = await ocrEngine.recognize(
        OcrImageRequest(
          path: path,
          cropRect: cropRect,
          quarterTurns: quarterTurns,
        ),
      );
      final parsed = parser.parse(document);
      draft = TimetableDraft(
        detectedTotalWeeks: parsed.detectedTotalWeeks,
        courses: parsed.courses.map(_withDefaultArea).toList(growable: false),
      );
      if (parsed.detectedTotalWeeks != null) {
        totalWeeks = parsed.detectedTotalWeeks!;
      }
      preview = null;
      if (draft!.courses.isEmpty) {
        errorMessage = '没有识别到课程，可以调整图片后重试，或手动录入。';
      }
    } on TimetableOcrException catch (error) {
      ocrFailureCode = error.code;
      errorMessage = switch (error.code) {
        TimetableOcrFailureCode.languageUnavailable =>
          '本机未安装简体中文 OCR，你仍可以保留这张图并手动录入。',
        TimetableOcrFailureCode.imageTooLarge =>
          '「${_fileName(path)}」尺寸过大，请裁剪后重试，或换一张更小的图（支持 PNG、JPG、JPEG）。',
        TimetableOcrFailureCode.decodeFailed =>
          '无法读取「${_fileName(path)}」。请确认文件没有被移动或删除，'
              '或换一张图（支持 PNG、JPG、JPEG）。',
        TimetableOcrFailureCode.platformUnavailable => '当前设备不支持本地课表识别。',
        TimetableOcrFailureCode.recognitionFailed => '课表识别失败，可以重试或手动录入。',
      };
    } catch (_) {
      // **吞掉原始异常，给一句人话**（§10 退出条件："图片读取失败不再暴露
      // `PathAccessException` 等原始异常"）。底层读取失败会以各种运行时异常形式冒出来
      // （`PathAccessException`、`FileSystemException`、平台通道错误……），
      // 它们的类型名与 `OS Error 5` 之类的文本对用户毫无意义，还会把路径带出去。
      errorMessage =
          '无法读取「${_fileName(path)}」。请确认文件没有被移动或删除，'
          '或换一张图（支持 PNG、JPG、JPEG）。';
    } finally {
      recognizing = false;
      notifyListeners();
    }
  }

  /// 从路径里取出**文件名**（不含目录）。
  ///
  /// **为什么只给文件名**：§10 一边要求"显示文件名"，一边要求"图片原件不写入数据库、
  /// 不上传"。把 `C:\Users\someone\Documents\...` 这串目录摆在界面上没有必要，
  /// 而且截图或录屏时会跟着外泄用户的目录结构。
  ///
  /// 同时兼容 Windows 的 `\` 与 POSIX 的 `/`：这个应用的图片路径来自平台选择器，
  /// 在测试里两种都可能出现。
  static String _fileName(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final index = normalized.lastIndexOf('/');
    final name = index == -1 ? normalized : normalized.substring(index + 1);
    return name.isEmpty ? path : name;
  }

  void rotateLeft() {
    quarterTurns = (quarterTurns + 3) % 4;
    preview = null;
    notifyListeners();
  }

  void rotateRight() {
    quarterTurns = (quarterTurns + 1) % 4;
    preview = null;
    notifyListeners();
  }

  void setCropInsets({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    final width = 1 - left - right;
    final height = 1 - top - bottom;
    cropRect = left == 0 && top == 0 && right == 0 && bottom == 0
        ? null
        : OcrCropRect(left: left, top: top, width: width, height: height);
    preview = null;
    notifyListeners();
  }

  void clearCrop() {
    cropRect = null;
    notifyListeners();
  }

  void startManualEntry() {
    draft ??= const TimetableDraft(courses: []);
    if (draft!.courses.isEmpty) addCourse();
    errorMessage = null;
    notifyListeners();
  }

  void addCourse() {
    final courses = [...?draft?.courses];
    courses.add(
      _validateCourse(
        CourseDraft(
          id: _ids.next(),
          name: '',
          areaId: defaultAreaId,
          weekday: DateTime.monday,
          startPeriod: 1,
          endPeriod: 2,
          weekSpans: [WeekSpan(startWeek: 1, endWeek: totalWeeks)],
          originalText: '',
        ),
      ),
    );
    draft = TimetableDraft(
      courses: courses,
      detectedTotalWeeks: draft?.detectedTotalWeeks,
    );
    preview = null;
    notifyListeners();
  }

  void updateCourse(CourseDraft course) {
    final current = draft;
    if (current == null) return;
    final next = current.courses
        .map((item) => item.id == course.id ? _validateCourse(course) : item)
        .toList(growable: false);
    draft = TimetableDraft(
      courses: next,
      detectedTotalWeeks: current.detectedTotalWeeks,
    );
    preview = null;
    notifyListeners();
  }

  void removeCourse(String courseId) {
    final current = draft;
    if (current == null) return;
    draft = TimetableDraft(
      courses: current.courses.where((item) => item.id != courseId).toList(),
      detectedTotalWeeks: current.detectedTotalWeeks,
    );
    skippedCourseIds.remove(courseId);
    preview = null;
    notifyListeners();
  }

  List<PlannerProject> projectsFor(String? areaId) => projects
      .where((project) => project.areaId == areaId && !project.isArchived)
      .toList(growable: false);

  void setCurrentWeek(int week) {
    if (week < 1 || week > 60) return;
    currentWeek = week;
    firstWeekMonday = AcademicWeekCalculator.firstWeekMonday(
      referenceDate: referenceDate,
      weekNumber: week,
    );
    preview = null;
    notifyListeners();
  }

  void setFirstWeekMonday(DateTime monday) {
    final date = DateTime(monday.year, monday.month, monday.day);
    if (date.weekday != DateTime.monday || date.isAfter(referenceDate)) return;
    firstWeekMonday = date;
    currentWeek = AcademicWeekCalculator.weekNumber(
      firstWeekMonday: date,
      date: referenceDate,
    );
    preview = null;
    notifyListeners();
  }

  void setTotalWeeks(int weeks) {
    if (weeks < 1 || weeks > 60) return;
    totalWeeks = weeks;
    preview = null;
    notifyListeners();
  }

  void setTermName(String value) {
    termName = value;
    preview = null;
    notifyListeners();
  }

  void selectTerm(String? id) {
    if (id == null) return;
    final term = savedTerms.where((item) => item.id == id).firstOrNull;
    if (term == null) return;
    selectedTermId = term.id;
    termName = term.name;
    firstWeekMonday = term.firstWeekMonday;
    totalWeeks = term.totalWeeks;
    try {
      currentWeek = AcademicWeekCalculator.weekNumber(
        firstWeekMonday: firstWeekMonday,
        date: referenceDate,
      );
    } on ArgumentError {
      currentWeek = 1;
    }
    preview = null;
    notifyListeners();
  }

  void selectTemplate(String? id) {
    if (id == null) return;
    final template = savedTemplates.where((item) => item.id == id).firstOrNull;
    if (template == null) return;
    selectedTemplateId = template.id;
    periodEntries = [...template.entries];
    preview = null;
    notifyListeners();
  }

  void updatePeriod(PeriodEntry entry) {
    final next = [...periodEntries];
    final index = next.indexWhere(
      (item) => item.periodNumber == entry.periodNumber,
    );
    if (index < 0) {
      next.add(entry);
    } else {
      next[index] = entry;
    }
    next.sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    periodEntries = next;
    selectedTemplateId = null;
    preview = null;
    notifyListeners();
  }

  void addPeriod() {
    final number = periodEntries.isEmpty
        ? 1
        : periodEntries
                  .map((entry) => entry.periodNumber)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    final start = periodEntries.isEmpty
        ? 8 * 60
        : periodEntries.last.endMinute + 10;
    if (start + 45 > 24 * 60) return;
    periodEntries = [
      ...periodEntries,
      PeriodEntry(
        periodNumber: number,
        startMinute: start,
        endMinute: start + 45,
      ),
    ];
    selectedTemplateId = null;
    preview = null;
    notifyListeners();
  }

  void removePeriod(int periodNumber) {
    periodEntries = periodEntries
        .where((entry) => entry.periodNumber != periodNumber)
        .toList();
    selectedTemplateId = null;
    preview = null;
    notifyListeners();
  }

  Future<bool> next() async {
    if (!canContinue) return false;
    if (step == TimetableWizardStep.periods) {
      await buildPreview();
      if (preview == null) return false;
    }
    if (step.index < TimetableWizardStep.values.length - 1) {
      step = TimetableWizardStep.values[step.index + 1];
      notifyListeners();
      return true;
    }
    return false;
  }

  void back() {
    if (step.index == 0) return;
    step = TimetableWizardStep.values[step.index - 1];
    notifyListeners();
  }

  Future<void> buildPreview() async {
    // 先用**现在**读到领域补一次默认归属，再拿它去算预览。
    //
    // 解析那一刻领域可能还没读出来（`initialize()` 是异步的，失败时 `areas` 为空），
    // 于是那时写进课程的默认值是 null，而它只写那一次——不在这里补，导进来的课就永远
    // 没有领域（用户看到的现象：导入的课程不属于学业）。
    final value = _withDefaultAreas(draft);
    if (value == null || periodValidationMessage != null) return;
    draft = value;
    buildingPreview = true;
    errorMessage = null;
    notifyListeners();
    try {
      final now = clock.nowUtc();
      final term = AcademicTerm(
        id: selectedTermId ?? 'preview-term',
        name: termName,
        firstWeekMonday: firstWeekMonday,
        totalWeeks: totalWeeks,
        timeZoneId: timeZoneId,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
      final periods = PeriodTemplate(
        id: selectedTemplateId ?? 'preview-periods',
        name: '本次导入节次',
        isDefault: false,
        entries: periodEntries,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
      preview = await importService.preview(value, term, periods);
      duplicateChoices
        ..clear()
        ..addEntries(
          preview!.duplicates.map(
            (item) => MapEntry(item.courseId, item.resolution),
          ),
        );
      conflictChoices
        ..clear()
        ..addEntries(
          preview!.conflicts.indexed.map(
            (item) => MapEntry(item.$1, TimetableConflictChoice.keepPending),
          ),
        );
    } catch (_) {
      preview = null;
      errorMessage = '无法生成导入预览，请检查学期、节次和课程信息。';
    } finally {
      buildingPreview = false;
      notifyListeners();
    }
  }

  void setDuplicateChoice(
    String courseId,
    TimetableDuplicateResolution choice,
  ) {
    duplicateChoices[courseId] = choice;
    notifyListeners();
  }

  void setConflictChoice(int index, TimetableConflictChoice choice) {
    conflictChoices[index] = choice;
    final value = preview;
    skippedCourseIds.clear();
    if (value != null) {
      for (final entry in conflictChoices.entries) {
        if (entry.value == TimetableConflictChoice.skipCourse &&
            entry.key >= 0 &&
            entry.key < value.conflicts.length) {
          skippedCourseIds.add(value.conflicts[entry.key].imported.courseId);
        }
      }
    }
    notifyListeners();
  }

  Future<TimetableImportOutcome?> commit() async {
    final value = preview;
    if (!canCommit || value == null) return null;
    committing = true;
    errorMessage = null;
    notifyListeners();
    try {
      final existing = savedTerms
          .where((term) => term.id == selectedTermId)
          .firstOrNull;
      final term = await academicCalendar.saveTerm(
        existing: existing,
        name: termName,
        firstWeekMonday: firstWeekMonday,
        totalWeeks: totalWeeks,
        timeZoneId: timeZoneId,
      );
      selectedTermId = term.id;
      final batchId = _ids.next();
      final now = clock.nowUtc();
      final logicalIds = <String, String>{};
      final writes = <TimetableImportSeriesWrite>[];
      for (final series in value.series) {
        if (skippedCourseIds.contains(series.courseId)) continue;
        final duplicate = duplicateChoices[series.courseId];
        if (duplicate == TimetableDuplicateResolution.skip ||
            duplicate == TimetableDuplicateResolution.update) {
          continue;
        }
        final ruleId = _ids.next();
        final eventId = _ids.next();
        final logicalId = logicalIds.putIfAbsent(series.courseId, _ids.next);
        final rule = RecurrenceRule(
          id: ruleId,
          weekdays: series.rule.weekdays,
          localStartMinute: series.rule.localStartMinute,
          durationMinutes: series.rule.durationMinutes,
          intervalWeeks: series.rule.intervalWeeks,
          validFromLocalDate: series.rule.validFromLocalDate,
          validUntilLocalDate: series.rule.validUntilLocalDate,
          timeZoneId: series.rule.timeZoneId,
        );
        final event = series.event.copyWith(
          id: eventId,
          recurrenceRuleId: ruleId,
          importBatchId: batchId,
          logicalCourseId: logicalId,
          updatedAtUtc: now,
        );
        final exclusions = <TimetableImportExclusion>[];
        for (final entry in conflictChoices.entries) {
          if (entry.value != TimetableConflictChoice.excludeOccurrence ||
              entry.key < 0 ||
              entry.key >= value.conflicts.length) {
            continue;
          }
          final conflict = value.conflicts[entry.key];
          if (conflict.imported.seriesId != series.id) continue;
          exclusions.add(
            TimetableImportExclusion(
              id: _ids.next(),
              occurrenceStartUtc: conflict.imported.range.startUtc,
            ),
          );
        }
        writes.add(
          TimetableImportSeriesWrite(
            event: event,
            rule: rule,
            exclusions: exclusions,
          ),
        );
      }
      if (writes.isEmpty) {
        throw StateError('没有可导入的课程');
      }
      final path = selectedImagePath;
      final hash = path == null ? 'manual-$batchId' : await _imageHasher(path);
      final fileName = path == null
          ? '手动录入'
          : path.split(RegExp(r'[\\/]')).last;
      committedBatch = await importService.commit(
        TimetableImportCommit(
          batchId: batchId,
          termId: term.id,
          sourceImageHash: hash,
          sourceFileName: fileName,
          createdAtUtc: now,
          series: writes,
        ),
      );
      return TimetableImportOutcome(
        batch: committedBatch!,
        recognizedCourses: draft?.courses.length ?? value.series.length,
        createdSeries: writes.length,
        skippedCourses: <String>{
          for (final series in value.series)
            if (skippedCourseIds.contains(series.courseId)) series.courseId,
        }.length,
        duplicateCourses: <String>{
          for (final series in value.series)
            if (duplicateChoices[series.courseId] ==
                    TimetableDuplicateResolution.skip ||
                duplicateChoices[series.courseId] ==
                    TimetableDuplicateResolution.update)
              series.courseId,
        }.length,
        excludedOccurrences: writes.fold(
          0,
          (total, write) => total + write.exclusions.length,
        ),
      );
    } on DuplicateTimetableImportException {
      errorMessage = '这张课表已经导入过，本次没有重复写入。';
      return null;
    } catch (_) {
      errorMessage = '导入失败，数据未写入，可以修改后重试。';
      return null;
    } finally {
      committing = false;
      notifyListeners();
    }
  }

  CourseDraft _withDefaultArea(CourseDraft course) =>
      course.areaId == null ? course.copyWith(areaId: defaultAreaId) : course;

  /// 给草稿里所有还没有领域的课程补上默认领域（学业）。
  ///
  /// 幂等：已经选过领域的课程原样保留，因此用户在审阅步骤手动改过的归属不会被覆盖。
  /// `defaultAreaId` 仍为空（一个领域都没有）时原样返回，不编造归属。
  TimetableDraft? _withDefaultAreas(TimetableDraft? value) {
    if (value == null || defaultAreaId == null) return value;
    if (value.courses.every((course) => course.areaId != null)) return value;
    return TimetableDraft(
      courses: [for (final course in value.courses) _withDefaultArea(course)],
      detectedTotalWeeks: value.detectedTotalWeeks,
    );
  }

  static CourseDraft _validateCourse(CourseDraft course) {
    final reasons = <TimetableReviewReason>{};
    if (course.name.trim().isEmpty) {
      reasons.add(TimetableReviewReason.missingName);
    }
    if (course.weekday == null || course.weekday! < 1 || course.weekday! > 7) {
      reasons.add(TimetableReviewReason.ambiguousWeekday);
    }
    if (course.startPeriod == null || course.endPeriod == null) {
      reasons.add(TimetableReviewReason.ambiguousPeriods);
    } else if (course.startPeriod! <= 0 ||
        course.endPeriod! < course.startPeriod!) {
      reasons.add(TimetableReviewReason.invalidRange);
    }
    if (course.weekSpans.isEmpty) {
      reasons.add(TimetableReviewReason.missingWeeks);
    }
    if (course.weekSpans.any((span) => span.endWeek < span.startWeek)) {
      reasons.add(TimetableReviewReason.invalidRange);
    }
    return course.copyWith(reviewReasons: reasons);
  }

  void _loadInitialAcademicSettings() {
    final matching = savedTerms.where((term) {
      final end = term.firstWeekMonday.add(Duration(days: term.totalWeeks * 7));
      return !referenceDate.isBefore(term.firstWeekMonday) &&
          referenceDate.isBefore(end);
    }).firstOrNull;
    if (matching != null) {
      selectedTermId = matching.id;
      termName = matching.name;
      firstWeekMonday = matching.firstWeekMonday;
      totalWeeks = matching.totalWeeks;
      currentWeek = AcademicWeekCalculator.weekNumber(
        firstWeekMonday: firstWeekMonday,
        date: referenceDate,
      );
    } else {
      firstWeekMonday = AcademicWeekCalculator.firstWeekMonday(
        referenceDate: referenceDate,
        weekNumber: 1,
      );
      termName = '${referenceDate.year}年学期';
    }
    final template =
        savedTemplates.where((item) => item.isDefault).firstOrNull ??
        savedTemplates.firstOrNull;
    if (template != null) {
      selectedTemplateId = template.id;
      periodEntries = [...template.entries];
    }
  }

  static Future<String> _hashImage(String path) async =>
      sha256.convert(await File(path).readAsBytes()).toString();

  static List<PeriodEntry> _defaultPeriods() => [
    PeriodEntry(periodNumber: 1, startMinute: 8 * 60, endMinute: 8 * 60 + 45),
    PeriodEntry(
      periodNumber: 2,
      startMinute: 8 * 60 + 55,
      endMinute: 9 * 60 + 40,
    ),
    PeriodEntry(
      periodNumber: 3,
      startMinute: 9 * 60 + 55,
      endMinute: 10 * 60 + 40,
    ),
    PeriodEntry(
      periodNumber: 4,
      startMinute: 10 * 60 + 50,
      endMinute: 11 * 60 + 35,
    ),
    PeriodEntry(
      periodNumber: 5,
      startMinute: 13 * 60 + 30,
      endMinute: 14 * 60 + 15,
    ),
    PeriodEntry(
      periodNumber: 6,
      startMinute: 14 * 60 + 25,
      endMinute: 15 * 60 + 10,
    ),
    PeriodEntry(
      periodNumber: 7,
      startMinute: 15 * 60 + 25,
      endMinute: 16 * 60 + 10,
    ),
    PeriodEntry(
      periodNumber: 8,
      startMinute: 16 * 60 + 20,
      endMinute: 17 * 60 + 5,
    ),
    PeriodEntry(periodNumber: 9, startMinute: 18 * 60, endMinute: 18 * 60 + 45),
    PeriodEntry(
      periodNumber: 10,
      startMinute: 18 * 60 + 50,
      endMinute: 19 * 60 + 35,
    ),
    PeriodEntry(
      periodNumber: 11,
      startMinute: 19 * 60 + 45,
      endMinute: 20 * 60 + 30,
    ),
    PeriodEntry(
      periodNumber: 12,
      startMinute: 20 * 60 + 40,
      endMinute: 21 * 60 + 25,
    ),
  ];
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
