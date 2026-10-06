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
