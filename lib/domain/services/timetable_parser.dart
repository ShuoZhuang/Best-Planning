import 'dart:math' as math;

import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';

final class TimetableParser {
  const TimetableParser();

  static final _weekRange = RegExp(
    r'(\d{1,2})\s*[-–—~至]\s*(\d{1,2})\s*(?:\(\s*(单|双)\s*周?\s*\))?\s*\(?\s*周?\s*\)?',
  );
  static final _location = RegExp(
    r'^@?\s*([A-Za-z]\d{3,4})$',
    caseSensitive: false,
  );
  static final _teacher = RegExp(r'^[\u3400-\u9fff]{2,4}$');

  TimetableDraft parse(OcrDocument document) {
    final weekdays = <_PositionedWeekday>[];
    final periods = <_PositionedPeriod>[];
    final ignored = <OcrLine>{};

    for (final line in document.lines) {
      final bounds = _bounds(line);
      if (bounds == null) continue;
      final weekday = _weekday(line.text);
      if (weekday != null) {
        weekdays.add(_PositionedWeekday(weekday, _centerX(bounds)));
        ignored.add(line);
        continue;
      }
      final period = int.tryParse(line.text.trim());
      if (period != null && period >= 1 && period <= 24) {
        periods.add(_PositionedPeriod(period, _centerY(bounds)));
        ignored.add(line);
      }
    }
    weekdays.sort((a, b) => a.x.compareTo(b.x));
    periods.sort((a, b) => a.number.compareTo(b.number));

    final courses = <CourseDraft>[];
    var detectedTotalWeeks = 0;
    for (final line in document.lines) {
      if (ignored.contains(line) || line.text.trim().isEmpty) continue;
      final bounds = _bounds(line);
      if (bounds == null) continue;
      final reasons = <TimetableReviewReason>{};
      final weekday = _nearestWeekday(_centerX(bounds), weekdays);
      if (weekday == null) reasons.add(TimetableReviewReason.ambiguousWeekday);

      final coveredPeriods = [
        for (final period in periods)
          if (period.y >= bounds.top && period.y <= bounds.top + bounds.height)
            period.number,
      ];
      final startPeriod = coveredPeriods.isEmpty
          ? null
          : coveredPeriods.reduce(math.min);
      final endPeriod = coveredPeriods.isEmpty
          ? null
          : coveredPeriods.reduce(math.max);
      if (coveredPeriods.isEmpty) {
        reasons.add(TimetableReviewReason.ambiguousPeriods);
      }

      final parts = _parseText(line.text, reasons);
      if (parts.name.isEmpty) reasons.add(TimetableReviewReason.missingName);
      if (parts.weekSpans.isEmpty) {
        reasons.add(TimetableReviewReason.missingWeeks);
      } else {
        detectedTotalWeeks = math.max(
          detectedTotalWeeks,
          parts.weekSpans.map((span) => span.endWeek).reduce(math.max),
        );
      }
      courses.add(
        CourseDraft(
          id: 'course-${courses.length + 1}',
          name: parts.name,
          teacher: parts.teacher,
          location: parts.location,
          weekday: weekday,
          startPeriod: startPeriod,
          endPeriod: endPeriod,
          weekSpans: List.unmodifiable(parts.weekSpans),
          reviewReasons: Set.unmodifiable(reasons),
          originalText: line.text,
        ),
      );
    }

    courses.sort((a, b) {
      final day = (a.weekday ?? 8).compareTo(b.weekday ?? 8);
      if (day != 0) return day;
      return (a.startPeriod ?? 99).compareTo(b.startPeriod ?? 99);
    });
    return TimetableDraft(
      courses: List.unmodifiable(courses),
      detectedTotalWeeks: detectedTotalWeeks == 0 ? null : detectedTotalWeeks,
    );
  }

  List<WeekSpan> parseWeekSpans(String text) {
    final normalized = text
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('－', '-');
    final spans = <WeekSpan>[];
    for (final match in _weekRange.allMatches(normalized)) {
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      if (start < 1 || end < start || end > 60) continue;
      final parity = switch (match.group(3)) {
        '单' => WeekParity.odd,
        '双' => WeekParity.even,
        _ => WeekParity.every,
      };
      spans.add(WeekSpan(startWeek: start, endWeek: end, parity: parity));
    }
    return List.unmodifiable(spans);
  }

  _ParsedText _parseText(String original, Set<TimetableReviewReason> reasons) {
    final normalized = original
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('－', '-');
    final weekSpans = parseWeekSpans(normalized);
    if (_weekRange.hasMatch(normalized) && weekSpans.isEmpty) {
      reasons.add(TimetableReviewReason.invalidRange);
    }
    final candidates = normalized
        .split(RegExp(r'[\r\n]+'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    var location = '';
    final content = <String>[];
    for (final candidate in candidates) {
      final locationMatch = _location.firstMatch(candidate);
      if (locationMatch != null) {
        location = locationMatch.group(1)!.toUpperCase();
      } else if (!_weekRange.hasMatch(candidate)) {
        content.add(candidate);
      }
    }
    var teacher = '';
    if (content.length > 1 && _teacher.hasMatch(content.last)) {
      teacher = content.removeLast();
    }
    final name = content.join().replaceAll(RegExp(r'\s+'), '');
    if (name.isEmpty && normalized.trim().isNotEmpty) {
      reasons.add(TimetableReviewReason.unparsedText);
    }
    return _ParsedText(
      name: name,
      teacher: teacher,
      location: location,
      weekSpans: weekSpans,
    );
  }

  static int? _weekday(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    const names = {
      '星期一': DateTime.monday,
      '周一': DateTime.monday,
      '星期二': DateTime.tuesday,
      '周二': DateTime.tuesday,
      '星期三': DateTime.wednesday,
      '周三': DateTime.wednesday,
      '星期四': DateTime.thursday,
      '周四': DateTime.thursday,
      '星期五': DateTime.friday,
      '周五': DateTime.friday,
      '星期六': DateTime.saturday,
      '周六': DateTime.saturday,
      '星期日': DateTime.sunday,
      '星期天': DateTime.sunday,
      '周日': DateTime.sunday,
      '周天': DateTime.sunday,
    };
    return names[compact];
  }

  static int? _nearestWeekday(double x, List<_PositionedWeekday> weekdays) {
    if (weekdays.isEmpty) return null;
    var nearest = weekdays.first;
    var distance = (x - nearest.x).abs();
    for (final candidate in weekdays.skip(1)) {
      final candidateDistance = (x - candidate.x).abs();
      if (candidateDistance < distance) {
        nearest = candidate;
        distance = candidateDistance;
      }
    }
    final typicalGap = weekdays.length < 2
        ? double.infinity
        : [
            for (var i = 1; i < weekdays.length; i++)
              weekdays[i].x - weekdays[i - 1].x,
          ].reduce(math.min);
    return distance <= typicalGap * 0.6 ? nearest.weekday : null;
  }

  static OcrRect? _bounds(OcrLine line) {
    if (line.words.isEmpty) return null;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final word in line.words) {
      left = math.min(left, word.bounds.left);
      top = math.min(top, word.bounds.top);
      right = math.max(right, word.bounds.left + word.bounds.width);
      bottom = math.max(bottom, word.bounds.top + word.bounds.height);
    }
    return OcrRect(
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
    );
  }

  static double _centerX(OcrRect rect) => rect.left + rect.width / 2;
  static double _centerY(OcrRect rect) => rect.top + rect.height / 2;
}

final class _PositionedWeekday {
  const _PositionedWeekday(this.weekday, this.x);
  final int weekday;
  final double x;
}

final class _PositionedPeriod {
  const _PositionedPeriod(this.number, this.y);
  final int number;
  final double y;
}

final class _ParsedText {
  const _ParsedText({
    required this.name,
    required this.teacher,
    required this.location,
    required this.weekSpans,
  });
  final String name;
  final String teacher;
  final String location;
  final List<WeekSpan> weekSpans;
}
