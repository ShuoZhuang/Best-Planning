import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/services/timetable_parser.dart';

void main() {
  const parser = TimetableParser();

  test('parses desktop grid weeks, geometry, teacher and location', () async {
    final draft = parser.parse(await _fixture('desktop_grid_ocr.json'));

    expect(draft.courses, hasLength(4));
    expect(draft.detectedTotalWeeks, 16);
    final electronics = draft.courses.firstWhere(
      (course) => course.name == '现代电子技术与系统',
    );
    expect(electronics.teacher, '刘笛');
    expect(electronics.location, 'D206');
    expect(electronics.weekday, DateTime.monday);
    expect((electronics.startPeriod, electronics.endPeriod), (1, 2));
    expect(
      electronics.weekSpans.single,
      const WeekSpan(startWeek: 1, endWeek: 16),
    );

    final optimization = draft.courses.firstWhere(
      (course) => course.name == '最优化方法及应用',
    );
    expect(optimization.teacher, '王孟');
    expect(optimization.weekSpans.single.parity, WeekParity.even);
    expect((optimization.startPeriod, optimization.endPeriod), (5, 6));

    final politics = draft.courses.firstWhere(
      (course) => course.name.startsWith('毛泽东思想'),
    );
    expect(politics.weekday, DateTime.saturday);
    expect(politics.weekSpans.single, const WeekSpan(startWeek: 1, endWeek: 4));
  });

  test('parses mobile grid and keeps ambiguous courses for review', () async {
    final draft = parser.parse(await _fixture('mobile_grid_ocr.json'));

    final complex = draft.courses.firstWhere(
      (course) => course.name == '复变函数与积分变换',
    );
    expect((complex.startPeriod, complex.endPeriod), (7, 8));
    expect(complex.weekSpans.single.endWeek, 16);

    final ambiguous = draft.courses.firstWhere(
      (course) => course.name == '待确认课程',
    );
    expect(
      ambiguous.reviewReasons,
      contains(TimetableReviewReason.missingWeeks),
    );
    expect(ambiguous.originalText, contains('B101'));
  });

  test('parses a phone screenshot grid and discards page chrome', () async {
    // Shaped like what Windows OCR really returns for a phone screenshot: one
    // line per visual row, one word per CJK character, range dashes read as
    // '．'/'一', period labels shaped '01 · 02 节', plus browser chrome, a
    // separator row and a remark block.
    final draft = parser.parse(await _fixture('screenshot_grid_ocr.json'));

    expect(draft.courses, hasLength(5));
    expect(draft.detectedTotalWeeks, 16);
    // Nothing outside the grid may survive as a course: no status bar, no
    // breadcrumb, no 中午休, no 备注 block, no browser URL.
    for (final course in draft.courses) {
      expect(course.reviewReasons, isEmpty, reason: course.originalText);
    }
    expect(
      draft.courses.map((course) => course.name),
      everyElement(
        isNot(
          anyOf(
            contains('课表'),
            contains('周次'),
            contains('备注'),
            contains('inquiry'),
            equals('休'),
          ),
        ),
      ),
    );

    final software = draft.courses.firstWhere((c) => c.name == '软件工程');
    expect(software.teacher, '陈一');
    expect(software.location, 'D206');
    expect(software.weekday, DateTime.monday);
    expect((software.startPeriod, software.endPeriod), (1, 2));
    expect(
      software.weekSpans.single,
      const WeekSpan(startWeek: 1, endWeek: 16),
    );

    final algorithms = draft.courses.firstWhere((c) => c.name == '数据结构与算法');
    expect(algorithms.weekday, DateTime.tuesday);
    expect((algorithms.startPeriod, algorithms.endPeriod), (3, 4));
    expect(algorithms.weekSpans.single.endWeek, 13);

    final english = draft.courses.firstWhere((c) => c.name == '大学英语(下)');
    expect(english.weekday, DateTime.wednesday);
    expect((english.startPeriod, english.endPeriod), (3, 4));
    expect(english.weekSpans.single.parity, WeekParity.odd);

    // Multi-line names are joined, and an even-week shortcut keeps its anchor.
    final statistics = draft.courses.firstWhere((c) => c.name == '概率论与数理统计');
    expect(
      statistics.weekSpans.single,
      const WeekSpan(startWeek: 2, endWeek: 6, parity: WeekParity.even),
    );

    final ai = draft.courses.firstWhere((c) => c.name == '人工智能导论');
    expect(ai.weekday, DateTime.sunday);
    expect((ai.startPeriod, ai.endPeriod), (7, 8));
    expect(ai.weekSpans.single.endWeek, 4);
  });

  test('reads weekday headers that OCR merged into a single line', () {
    // A wide grid can come back with all seven names on one OCR line; the
    // header must still yield seven columns.
    final names = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    final headerWords = <OcrWord>[];
    for (var i = 0; i < names.length; i++) {
      final left = 200.0 + i * 150;
      for (var c = 0; c < names[i].length; c++) {
        headerWords.add(
          OcrWord(
            text: names[i][c],
            bounds: OcrRect(
              left: left + c * 20,
              top: 100,
              width: 20,
              height: 22,
            ),
          ),
        );
      }
    }

    final draft = parser.parse(
      _document([
        OcrLine(
          text: headerWords.map((word) => word.text).join(' '),
          words: headerWords,
        ),
        _textLine('01 · 02 节', 40, 200),
        _textLine('高等数学', 175, 190),
        _textLine('张三', 190, 215),
        _textLine('1一16（周）', 180, 240),
        _textLine('B101', 190, 265),
      ]),
    );

    expect(draft.courses, hasLength(1));
    final course = draft.courses.single;
    expect(course.name, '高等数学');
    expect(course.teacher, '张三');
    expect(course.location, 'B101');
    expect(course.weekday, DateTime.monday);
    expect((course.startPeriod, course.endPeriod), (1, 2));
    expect(course.weekSpans.single.endWeek, 16);
  });

  test('accepts the dash substitutions real OCR produces', () {
    expect(parser.parseWeekSpans('1．16（单周）'), [
      const WeekSpan(startWeek: 1, endWeek: 16, parity: WeekParity.odd),
    ]);
    expect(parser.parseWeekSpans('2一6（双周）'), [
      const WeekSpan(startWeek: 2, endWeek: 6, parity: WeekParity.even),
    ]);
    expect(parser.parseWeekSpans('8一16（周）'), [
      const WeekSpan(startWeek: 8, endWeek: 16),
    ]);
    expect(parser.parseWeekSpans('1 一 4 周'), [
      const WeekSpan(startWeek: 1, endWeek: 4),
    ]);
    // Fullwidth digits as well.
    expect(parser.parseWeekSpans('１－１６周'), [
      const WeekSpan(startWeek: 1, endWeek: 16),
    ]);
  });

  test('week parser supports non-contiguous and odd spans', () {
    final spans = parser.parseWeekSpans('1-4周, 8-16(单周)');

    expect(spans, [
      const WeekSpan(startWeek: 1, endWeek: 4),
      const WeekSpan(startWeek: 8, endWeek: 16, parity: WeekParity.odd),
    ]);
  });
}

Future<OcrDocument> _fixture(String name) async {
  final value = jsonDecode(
    await File('test/fixtures/timetable/$name').readAsString(),
  ) as Map<String, Object?>;
  return OcrDocument(
    width: value['width']! as int,
    height: value['height']! as int,
    textAngle: (value['textAngle'] as num?)?.toDouble(),
    lines: [
      for (final rawLine in value['lines']! as List<Object?>) _line(rawLine),
    ],
  );
}

OcrLine _line(Object? value) {
  final line = value! as Map<String, Object?>;
  return OcrLine(
    text: line['text']! as String,
    words: [
      for (final rawWord in line['words']! as List<Object?>) _word(rawWord),
    ],
  );
}

OcrWord _word(Object? value) {
  final word = value! as Map<String, Object?>;
  return OcrWord(
    text: word['text']! as String,
    bounds: _rect(word['bounds']! as Map<String, Object?>),
  );
}

OcrRect _rect(Map<String, Object?> value) => OcrRect(
  left: (value['left']! as num).toDouble(),
  top: (value['top']! as num).toDouble(),
  width: (value['width']! as num).toDouble(),
  height: (value['height']! as num).toDouble(),
);

OcrDocument _document(List<OcrLine> lines) =>
    OcrDocument(width: 1400, height: 900, textAngle: 0, lines: lines);

/// Builds one OCR line the way the engine emits it: an ASCII run stays a word,
/// each CJK character becomes its own word.
OcrLine _textLine(String text, double left, double top) {
  final words = <OcrWord>[];
  var x = left;
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    final token = buffer.toString();
    final width = token.length * 12.0;
    words.add(
      OcrWord(
        text: token,
        bounds: OcrRect(left: x, top: top, width: width, height: 22),
      ),
    );
    x += width;
    buffer.clear();
  }

  for (final rune in text.runes) {
    if (rune == 0x20) continue;
    if (rune < 128) {
      buffer.writeCharCode(rune);
    } else {
      flush();
      words.add(
        OcrWord(
          text: String.fromCharCode(rune),
          bounds: OcrRect(left: x, top: top, width: 20, height: 22),
        ),
      );
      x += 20;
    }
  }
  flush();
  return OcrLine(text: text, words: words);
}
