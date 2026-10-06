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
        TimetableOcrFailureCode.imageTooLarge => '图片尺寸过大，请裁剪后重试。',
        TimetableOcrFailureCode.decodeFailed =>
          '无法读取这张图片。请确认文件没有被移动或删除，也可以重新选择 PNG 或 JPG。',
        TimetableOcrFailureCode.platformUnavailable => '当前设备不支持本地课表识别。',
        TimetableOcrFailureCode.recognitionFailed => '课表识别失败，可以重试或手动录入。',
      };
    } catch (_) {
      errorMessage = '课表识别失败，图片仍已保留，可以重试或手动录入。';
    } finally {
      recognizing = false;
      notifyListeners();
    }
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
    final value = draft;
    if (value == null || periodValidationMessage != null) return;
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

  Future<TimetableImportBatch?> commit() async {
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
      return committedBatch;
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
