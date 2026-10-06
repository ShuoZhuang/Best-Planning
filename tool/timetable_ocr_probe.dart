// Runs the timetable parser over a captured OCR dump and prints what it made of
// it, so real screenshots can be diagnosed without launching the app.
//
// Produce a dump first:
//   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/dump_windows_ocr.ps1 `
//     -Path C:\path\to\timetable.jpg -Out C:\path\to\dump.json
// Then:
//   dart run tool/timetable_ocr_probe.dart C:\path\to\dump.json
//
// Course names, teachers and rooms in a real dump are personal data: keep dumps
// outside the repository.
import 'dart:convert';
import 'dart:io';

import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/services/timetable_parser.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/timetable_ocr_probe.dart <dump.json>');
    exit(64);
  }
  final document = _read(args.first);
  final draft = const TimetableParser().parse(document);

  stdout.writeln('OCR lines: ${document.lines.length}');
  stdout.writeln('courses produced: ${draft.courses.length}');
  stdout.writeln('detectedTotalWeeks: ${draft.detectedTotalWeeks}');

  final reasons = <TimetableReviewReason, int>{};
  for (final course in draft.courses) {
    for (final reason in course.reviewReasons) {
      reasons[reason] = (reasons[reason] ?? 0) + 1;
    }
  }
  stdout.writeln(
    'review reason histogram: '
    '${reasons.isEmpty ? '(none)' : reasons.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}',
  );
  stdout.writeln('');
  for (final course in draft.courses) {
    final weeks = course.weekSpans
        .map((span) => '${span.startWeek}-${span.endWeek}:${span.parity.name}')
        .join(',');
    stdout.writeln(
      'wd=${course.weekday ?? '-'} p=${course.startPeriod ?? '-'}..'
      '${course.endPeriod ?? '-'} | name="${course.name}" '
      '| teacher="${course.teacher}" | loc="${course.location}" '
      '| weeks=[$weeks] '
      '| reasons=${course.reviewReasons.map((r) => r.name).join(",")}',
    );
  }
}

OcrDocument _read(String path) {
  final value =
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  return OcrDocument(
    width: (value['width']! as num).toInt(),
    height: (value['height']! as num).toInt(),
    textAngle: (value['textAngle'] as num?)?.toDouble(),
    lines: [for (final line in value['lines']! as List<Object?>) _line(line!)],
  );
}

OcrLine _line(Object raw) {
  final map = raw as Map<Object?, Object?>;
  return OcrLine(
    text: (map['text'] as String?) ?? '',
    words: [
      for (final word in (map['words'] as List<Object?>? ?? const []))
        _word(word!),
    ],
  );
}

OcrWord _word(Object raw) {
  final map = raw as Map<Object?, Object?>;
  final bounds = map['bounds']! as Map<Object?, Object?>;
  return OcrWord(
    text: (map['text'] as String?) ?? '',
    bounds: OcrRect(
      left: (bounds['left']! as num).toDouble(),
      top: (bounds['top']! as num).toDouble(),
      width: (bounds['width']! as num).toDouble(),
      height: (bounds['height']! as num).toDouble(),
    ),
  );
}
