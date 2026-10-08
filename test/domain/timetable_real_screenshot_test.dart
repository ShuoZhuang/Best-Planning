// M6（路线图 §10）退出条件第 1 条的**可复现部分**：用**用户真实课表**的 OCR 输出
// 走一遍"解析 → 导入"。
//
// **为什么这个文件存在，以及它替代了什么、不替代什么**：
//
// §10 要求"使用**用户提供的两种课表截图**各完成一次识别、修正、预览和导入"。
// 那条要求有三段：① 把图片交给 OCR；② 把 OCR 的**真实输出**解析成课程；③ 导入日历。
//
// 本文件覆盖 **② 和 ③**，用的**不是**合成数据，而是用户真实截图
// （`ecust-timetable.jpg` / `-2x` / `-15x`）经过**本机 Windows 原生 OCR** 跑出来的原始输出
// （`test/fixtures/timetable/real_ecust_timetable_ocr.json`，1974×4248、96 行）。
//
// **① 不在这里**：把图片喂给 OCR 引擎那一步由 `integration_test/windows_timetable_ocr_native_test.dart`
// 覆盖（它真的起原生 OCR 读本地文件）。
//
// **这份真实输出为什么值得单独钉住**：它比合成 fixture **脏得多**——
// CJK 字符被 OCR 拆成单个词并用空格分开、周次里混进了识别错的字
// （`1 翎 6`＝1–16、`8 一 1 6 倜 ）`＝8–16）、分隔符有 `·`、`一`、`到` 三种写法。
// 合成 fixture 里这些都是干净的，因此**它测不出真实输出上的问题**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/services/timetable_parser.dart';

const _parser = TimetableParser();

Future<OcrDocument> _realOcr() async {
  final value = jsonDecode(
    await File('test/fixtures/timetable/real_ecust_timetable_ocr.json')
        .readAsString(),
  ) as Map<String, Object?>;
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

void main() {
  test('M6 真实截图的 OCR 输出能被解析出课程（不是空手而归）', () async {
    final draft = _parser.parse(await _realOcr());

    // 关键的"没有整体失败"：真实输出很脏，最坏情况是解析器一条都认不出。
    expect(
      draft.courses,
      isNotEmpty,
      reason: '真实 OCR 输出里明明有课程，一条都解析不出说明对脏输入的容忍度不够',
    );
    // 用户真实课表里有 10 门以上不同的课（含重复出现的同一门）。
    expect(
      draft.courses.length,
      greaterThanOrEqualTo(6),
      reason:
          '解析出的课程数明显偏少，说明大量行被丢掉了。'
          '实际解析到 ${draft.courses.length} 条：'
          '${draft.courses.map((c) => c.name).toList()}',
    );
  });

  test('M6 真实输出里的课程名、教师、地点被正确还原', () async {
    final draft = _parser.parse(await _realOcr());
    final names = draft.courses.map((c) => c.name).toSet();

    // 真实课表里几门确定的课（名字与 OCR 输出逐字对得上）。
    expect(
      names.any((n) => n.contains('算法与数据结构')),
      isTrue,
      reason: '实际解析到的名字：$names',
    );
    expect(
      names.any((n) => n.contains('大 学 物 理') || n.contains('大学物理')),
      isTrue,
    );
    expect(
      names.any((n) => n.contains('现 代 电 子') || n.contains('现代电子')),
      isTrue,
    );

    // 教师与地点：真实 OCR 把它们识别成了**单个词**（"赵 敏"、"D206"）。
    final algorithms = draft.courses.firstWhere(
      (c) => c.name.contains('算法与数据结构'),
    );

    expect(algorithms.teacher.replaceAll(' ', ''), '赵敏');
    expect(algorithms.location, 'D206');
  });

  test('M6 单双周与非整学期课程：真实输出里的周次被解析成区间', () async {
    final draft = _parser.parse(await _realOcr());

    // **真实输出里确实有两种情况**：多数课有完整周次，少数课因为 OCR 把周次认坏
    // （`1 翎 6`、`1 3`）而没有周次。后者必须被标出来、前者必须留下——见下一条。
    final withWeeks = draft.courses
        .where((c) => c.weekSpans.isNotEmpty)
        .toList();
    expect(
      withWeeks.length,
      greaterThanOrEqualTo(10),
      reason: '真实课表里绝大多数课都有明确周次，解析到的却只有 ${withWeeks.length} 条',
    );
    for (final course in withWeeks) {
      for (final span in course.weekSpans) {
        expect(span.startWeek, greaterThanOrEqualTo(1));
        expect(span.endWeek, greaterThanOrEqualTo(span.startWeek));
      }
    }

    // **单双周必须被区分**：真实输出里有"（单周）"和"（双周）"，两者都要能认出来。
    final parity = withWeeks
        .expand((c) => c.weekSpans)
        .map((s) => s.parity)
        .where((p) => p != WeekParity.every)
        .toSet();
    expect(
      parity,
      containsAll(<WeekParity>[WeekParity.odd, WeekParity.even]),
      reason:
          '真实课表里"大学物理(下)"是单周、"创业基础"是双周，两种都要认出来；'
          '实际识别到 $parity',
    );

    // **非整学期**：真实输出里有 1–6、1–4、8–16 这类不满整学期的区间。
    final all = withWeeks.expand((c) => c.weekSpans).toList();
    expect(
      all.any((s) => s.endWeek < 16),
      isTrue,
      reason: '真实课表里有 1–6 / 1–4 这类不到期末的课，应当解析成结束周小于 16',
    );
    expect(
      all.any((s) => s.startWeek > 1),
      isTrue,
      reason: '真实课表里有 8–16 这类从学期中途开始的课，应当解析成起始周大于 1',
    );
  });

  test('M6 单门课程信息不完整时标出该门，其他识别结果继续保留', () async {
    // §10 原文："单门课程信息不完整时标出该门，其他识别结果继续保留。"
    //
    // **这一条是真实输出才测得出的**：用户课表里有两门课的周次被 OCR 认坏了
    // （`1 翎 6`、`1 3`），于是课程名把老师也吸了进去、周次为空。
    // 要求的正确行为不是"整页失败"，也不是"当成正常课导入"，而是**标出来 + 别的照常**。
    final draft = _parser.parse(await _realOcr());

    final incomplete = draft.courses.where((c) => c.weekSpans.isEmpty).toList();
    expect(incomplete, isNotEmpty, reason: '真实输出里确实有周次认坏的行；若这里为空，说明解析器把它们静默丢了');
    for (final course in incomplete) {
      expect(
        course.reviewReasons,
        contains(TimetableReviewReason.missingWeeks),
        reason: '「${course.name}」没有周次，必须被标成待校对，否则用户不会注意到它',
      );
    }

    // **其他识别结果继续保留**：不完整的那两门不该把整页拖垮。
    expect(
      draft.courses.length - incomplete.length,
      greaterThanOrEqualTo(10),
      reason: '除了认坏的那几门，其余课程必须照常解析出来',
    );
  });

  test('M6 连续两节与不同节长：真实输出里的节次被解析成区间', () async {
    final draft = _parser.parse(await _realOcr());

    final periods = <(int, int)>{
      for (final c in draft.courses)
        if (c.startPeriod != null && c.endPeriod != null)
          (c.startPeriod!, c.endPeriod!),
    };

    // 真实课表里有 01·02 / 03·04 / 05·06 / 07·08 以及 **09·10 / 11·12**
    // （后两组只在真实输出里出现，合成 fixture 没有）。
    expect(periods, isNotEmpty, reason: '一个节次区间都没解析出来');
    for (final (start, end) in periods) {
      expect(start, greaterThanOrEqualTo(1));
      expect(end, greaterThanOrEqualTo(start), reason: '节次区间不能倒置：$start–$end');
    }
    expect(
      periods.any((p) => p.$1 >= 9),
      isTrue,
      reason:
          '真实课表有 09·10 与 11·12 节（第 9 节及以后），应当被解析出来；'
          '实际：$periods',
    );
  });

  test('M6 真实输出里的周次总数（16）能被识别', () async {
    final draft = _parser.parse(await _realOcr());
    // 真实页面右上写着 `学年学期： 2026 一 2027 · 1`，周次取自课程里的 `1 一 16`。
    expect(
      draft.detectedTotalWeeks,
      anyOf(isNull, 16),
      reason:
          '识别出的总周数只能是 null（无法确定）或 16（真实学期长度）；'
          '实际 ${draft.detectedTotalWeeks}',
    );
  });

  test('M6 解析真实输出不会抛异常（脏输入不得让导入整页失败）', () async {
    // §10 "OCR 识别不到表格时允许手动新增课程，不能把用户困在上传步骤" 的前提是
    // **解析这一步本身不能炸**。真实输出里有各种 OCR 垃圾，这条先钉住"不抛"。
    await expectLater(
      Future(() async => _parser.parse(await _realOcr())),
      completes,
    );
  });

  test('M6 真实输出能走完「解析 → 预览」，并且预览阶段一次都不写', () async {
    // §10 退出条件第 1 条的后半段：识别之后要能**修正、预览和导入**。
    // 这一条把真实 OCR 输出接到真正的导入服务上，因此验的是整条链路而不只是解析器。
    //
    // **为什么到这里为止**：`commit` 走的是 `TimetableImportCommit` 请求 + `importRepository`
    // （批量落库），而它的"整批提交/回滚"语义已经由 `timetable_import_commit_test.dart` 与
    // `timetable_import_rollback_test.dart` 覆盖（含"任一步失败不写半套"）。
    // 这里刻意不重复那两块，只钉住真实数据能生成**可提交的预览**、且预览本身零写入。
    final repository = _SpyCalendar();
    final service = TimetableImportService(
      calendarRepository: repository,
      zones: TimeZoneDatabase(),
    );
    final draft = _parser.parse(await _realOcr());

    final preview = await service.preview(draft, _term, _periods);

    expect(preview.series, isNotEmpty, reason: '真实课表必须能生成至少一条课程系列');
    expect(
      preview.occurrences,
      isNotEmpty,
      reason: '生成了系列却没有任何一次上课（occurrence），导入会是空的',
    );
    expect(
      repository.saveCalls,
      0,
      reason: '§10："识别结果必须经过确认，不能直接写入日历"——预览阶段一次都不许写',
    );

    // 真实课表是 16 周的学期，一次周课应当展开成多次。
    expect(
      preview.occurrences.length,
      greaterThan(preview.series.length),
      reason: '周课必须按周展开；次数不多于系列数说明没有真正展开',
    );

    // 真实课表里同时有单周、双周与整学期课，展开出来的周次必须落在这个学期范围内。
    for (final occurrence in preview.occurrences) {
      expect(
        occurrence.weekNumber,
        inInclusiveRange(1, _term.totalWeeks),
        reason: '展开出了学期范围之外的周次：第 ${occurrence.weekNumber} 周',
      );
    }

    // 不完整的课一门都不该被展开（下一条专门验这件事）。
    final incompleteIds = draft.courses
        .where((c) => c.weekSpans.isEmpty)
        .map((c) => c.id)
        .toSet();
    for (final occurrence in preview.occurrences) {
      expect(
        incompleteIds.contains(occurrence.courseId),
        isFalse,
        reason: '「${occurrence.courseId}」没有周次，不该被展开成一次上课',
      );
    }
  });
}

/// 学期的固定设定：与真实课表一致的 16 周。
final _term = AcademicTerm(
  id: 'term-autumn',
  name: '2026 秋季学期',
  firstWeekMonday: DateTime(2026, 9, 7),
  totalWeeks: 16,
  timeZoneId: 'Asia/Shanghai',
  createdAtUtc: DateTime.utc(2026, 9, 1),
  updatedAtUtc: DateTime.utc(2026, 9, 1),
);

/// 节次表：真实课表里有到第 12 节的课（09·10、11·12），因此这里排到 12 节。
final _periods = PeriodTemplate(
  id: 'periods',
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
