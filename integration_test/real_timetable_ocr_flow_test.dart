// 在本机跑真实的"图片 → OCR → 解析 → 预览"链路（M6 退出条件第 1 条）。
//
// **为什么这个文件读的是仓库外面的文件**：
// 真实课表的 OCR 输出里含用户的课程名、教师与教室，属于个人数据。
// `tool/dump_windows_ocr.ps1` 与 `tool/timetable_ocr_probe.dart` 的注释都写着同一件事：
// **图片与 dump 要留在仓库外面**，本文件沿用那条约定，不把 dump 提交进版本库。
//
// **怎么产生它**（在本机跑一次即可）：
//
//   powershell.exe -NoProfile -ExecutionPolicy Bypass `
//     -File tool/dump_windows_ocr.ps1 `
//     -Path G:\best-planing\.flutter-tmp\ocr-sample\ecust-timetable.jpg `
//     -Out  G:\best-planing\.flutter-tmp\ocr-sample\rerun-session.json
//
// 然后：
//
//   flutter test integration_test/real_timetable_ocr_flow_test.dart -d windows
//
// **dump 不存在时整体跳过**（`skip:`）：这个仓库要在别人机器上也能跑测试，
// 而别人不会有这台机器上的课表截图。跳过是**有意的**，不是把失败藏起来——
// 跳过时打印的理由里写清了该跑哪条命令。
//
// **它验的是什么、不验什么**：
// · 验：真实的 Windows OCR 输出能被解析器吃下、能生成可提交的预览、
//   预览阶段一次都不写库；
// · **不验**：在界面上人工改字段那一步（那需要驱动真实 GUI）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/services/timetable_parser.dart';

/// 本机真实 dump 的位置（由上面那条命令产生）。
const _dumpPath = r'G:\best-planing\.flutter-tmp\ocr-sample\rerun-session.json';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final dump = File(_dumpPath);

  testWidgets(
    '真实课表：原生 OCR 输出 → 解析 → 预览，且预览不写库',
    (tester) async {
      final document = _readDump(await dump.readAsString());
      expect(document.lines, isNotEmpty, reason: '真实 dump 里应当有识别到的文字行');

      final draft = const TimetableParser().parse(document);
      expect(draft.courses, isNotEmpty, reason: '真实输出必须能解析出课程，否则用户会被困在上传步骤');
      expect(
        draft.detectedTotalWeeks,
        isNotNull,
        reason: '真实课表页面标着学年学期，学期总周数应当能被识别出来',
      );

      // 真实课表里同时存在整学期、单周、双周与非整学期的课。
      final spans = draft.courses.expand((c) => c.weekSpans).toList();
      expect(spans, isNotEmpty);
      expect(
        spans.map((s) => s.parity).toSet(),
        contains(WeekParity.every),
        reason: '整学期的课占多数',
      );
      for (final span in spans) {
        expect(span.startWeek, greaterThanOrEqualTo(1));
        expect(span.endWeek, greaterThanOrEqualTo(span.startWeek));
        expect(span.endWeek, lessThanOrEqualTo(60), reason: '周次超出学期上限：$span');
      }

      // 接到真正的导入服务上，确认能生成可提交的预览、且预览阶段零写入。
      final repository = _SpyCalendar();
      final service = TimetableImportService(
        calendarRepository: repository,
        zones: TimeZoneDatabase(),
      );
      final preview = await service.preview(
        draft,
        _term(draft.detectedTotalWeeks!),
        _periods(),
      );

      expect(preview.occurrences, isNotEmpty, reason: '预览里没有任何一次上课');
      expect(repository.saveCalls, 0, reason: '§10："识别结果必须经过确认，不能直接写入日历"');
      for (final occurrence in preview.occurrences) {
        expect(occurrence.weekNumber, greaterThanOrEqualTo(1));
      }
    },
    // `skip` 的类型是 `bool?`，因此"跳过并给出理由"只能靠 `dynamic` 绕过静态检查
    // （`package:test` 运行时确实接受字符串理由）。这里显式标注，避免读的人以为写错了。
    // ignore: avoid_dynamic_calls
    skip:
        (dump.existsSync()
                ? null
                : '本机没有真实课表 dump（$_dumpPath）。'
                      '先跑 tool/dump_windows_ocr.ps1 生成它，见本文件顶部注释。')
            as dynamic,
  );
}

OcrDocument _readDump(String raw) {
  final value = jsonDecode(raw) as Map<String, Object?>;
  return OcrDocument(
    width: value['width']! as int,
    height: value['height']! as int,
    textAngle: (value['textAngle'] as num?)?.toDouble(),
    lines: [
      for (final rawLine in value['lines']! as List<Object?>)
        _line(rawLine as Map<String, Object?>),
    ],
  );
}

OcrLine _line(Map<String, Object?> raw) => OcrLine(
  text: raw['text']! as String,
  words: [
    for (final rawWord in raw['words']! as List<Object?>)
      _word(rawWord as Map<String, Object?>),
  ],
);

OcrWord _word(Map<String, Object?> raw) {
  final bounds = raw['bounds']! as Map<String, Object?>;
  return OcrWord(
    text: raw['text']! as String,
    bounds: OcrRect(
      left: (bounds['left']! as num).toDouble(),
      top: (bounds['top']! as num).toDouble(),
      width: (bounds['width']! as num).toDouble(),
      height: (bounds['height']! as num).toDouble(),
    ),
  );
}

AcademicTerm _term(int totalWeeks) => AcademicTerm(
  id: 'term-real',
  name: '真实学期',
  firstWeekMonday: DateTime(2026, 9, 7),
  totalWeeks: totalWeeks,
  timeZoneId: 'Asia/Shanghai',
  createdAtUtc: DateTime.utc(2026, 9, 1),
  updatedAtUtc: DateTime.utc(2026, 9, 1),
);

/// 真实课表有到第 12 节的课（09·10、11·12），因此排到 12 节。
PeriodTemplate _periods() => PeriodTemplate(
  id: 'periods-real',
  name: '主校区',
  isDefault: true,
  entries: [
    for (var period = 1; period <= 12; period++)
      PeriodEntry(
        periodNumber: period,
        startMinute: 8 * 60 + (period - 1) * 55,
        endMinute: 8 * 60 + (period - 1) * 55 + 45,
      ),
  ],
  createdAtUtc: DateTime.utc(2026, 9, 1),
  updatedAtUtc: DateTime.utc(2026, 9, 1),
);

final class _SpyCalendar implements CalendarRepository {
  int saveCalls = 0;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async => saveCalls++;
}
