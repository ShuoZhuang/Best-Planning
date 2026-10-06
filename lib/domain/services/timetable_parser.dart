import 'dart:math' as math;

import 'package:personal_planner/domain/models/timetable_import.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';

/// Turns a raw OCR document into reviewable course drafts.
///
/// Real Windows OCR does **not** hand back one tidy line per timetable cell:
///
/// * a cell arrives as one line per *visual* row (name / teacher / weeks / room);
/// * CJK text is split into one **word per character** (`星 期 一`), so headers
///   and period labels can only be recognised from a line's joined text;
/// * a week range's dash is often recognised as `．` or `一`
///   (`1 ． 16 （ 单 周 ）`, `2 一 6 （ 双 周 ）`);
/// * period labels are ranges, not bare numbers (`01 · 02 节`).
///
/// Parsing therefore reads the table's own grid — weekday header columns from
/// line text, period-row bands from gutter labels — and then assigns **word
/// geometry** to cells. Everything outside the grid (page chrome, browser bars,
/// the remark block) is discarded instead of becoming a bogus course.
final class TimetableParser {
  const TimetableParser();

  /// Dashes come back as `．`, `.`, `·`, `一`, `至` or `到`, not just `-`.
  static final RegExp _weekRange = RegExp(
    r'(\d{1,2})\s*[-–—~～．.·一至到]\s*(\d{1,2})\s*'
    r'(?:\(\s*(单|双)\s*周?\s*\))?\s*\(?\s*周?\s*\)?',
  );
  static final RegExp _location = RegExp(
    r'^@?\s*([A-Za-z]\d{3,4})$',
    caseSensitive: false,
  );
  static final RegExp _teacher = RegExp(r'^[\u3400-\u9fff]{2,4}$');

  /// `01·02节`, `11·12节`, `1-2`, `第3节`, `3`.
  static final RegExp _periodLabel = RegExp(
    r'^(?:第)?(\d{1,2})(?:[-–—~～．.·一至到](\d{1,2}))?节?$',
  );
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Generous, because real cells lose a line to OCR and leave a bigger gap than
  /// the cell's own line spacing; row boundaries do the precise separating.
  static const double cellGapFactor = 2.5;

  TimetableDraft parse(OcrDocument document) {
    final lines = _collect(document);
    final grid = _Grid.detect(lines);
    if (grid == null) return _parseWithoutGrid(document);
    return _parseWithGrid(lines, grid);
  }

  List<WeekSpan> parseWeekSpans(String text) {
    final normalized = _canonical(text);
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

  // --- grid parsing -------------------------------------------------------

  TimetableDraft _parseWithGrid(List<_LineBox> lines, _Grid grid) {
    final courses = <CourseDraft>[];
    var detectedTotalWeeks = 0;

    for (final column in grid.columns) {
      final inColumn = <_Box>[];
      for (final line in lines) {
        if (grid.isHeaderLine(line)) continue;
        if (grid.isGutterLine(line)) continue;
        if (grid.isWideLine(line)) continue;
        for (final box in line.boxes) {
          if (box.centerX < column.left || box.centerX >= column.right) {
            continue;
          }
          if (box.centerY < grid.top || box.centerY > grid.bottom) continue;
          inColumn.add(box);
        }
      }
      if (inColumn.isEmpty) continue;
      inColumn.sort((a, b) => a.top.compareTo(b.top));

      for (final cell in _splitCells(inColumn, grid)) {
        final text = _cellText(cell);
        if (text.trim().isEmpty) continue;
        final reasons = <TimetableReviewReason>{};
        final parts = _parseText(text, reasons);
        if (parts.name.isEmpty) reasons.add(TimetableReviewReason.missingName);
        if (parts.weekSpans.isEmpty) {
          reasons.add(TimetableReviewReason.missingWeeks);
        } else {
          detectedTotalWeeks = math.max(
            detectedTotalWeeks,
            parts.weekSpans.map((span) => span.endWeek).reduce(math.max),
          );
        }

        final rows = grid.rowsCovering(_Bounds.of(cell));
        if (rows.isEmpty) reasons.add(TimetableReviewReason.ambiguousPeriods);

        courses.add(
          CourseDraft(
            id: 'course-${courses.length + 1}',
            name: parts.name,
            teacher: parts.teacher,
            location: parts.location,
            weekday: column.weekday,
            startPeriod: rows.isEmpty
                ? null
                : rows.map((row) => row.startPeriod).reduce(math.min),
            endPeriod: rows.isEmpty
                ? null
                : rows.map((row) => row.endPeriod).reduce(math.max),
            weekSpans: List.unmodifiable(parts.weekSpans),
            reviewReasons: Set.unmodifiable(reasons),
            originalText: text,
          ),
        );
      }
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

  /// Splits one column's boxes into cells: a new cell starts at a large vertical
  /// gap or wherever a period-row boundary falls between two boxes.
  static List<List<_Box>> _splitCells(List<_Box> sorted, _Grid grid) {
    final cells = <List<_Box>>[];
    var current = <_Box>[];
    var previousBottom = double.negativeInfinity;
    for (final box in sorted) {
      if (current.isNotEmpty) {
        final gap = box.top - previousBottom;
        if (gap > grid.cellGap ||
            grid.crossesRowBoundary(previousBottom, box.top)) {
          cells.add(current);
          current = <_Box>[];
        }
      }
      current.add(box);
      previousBottom = math.max(previousBottom, box.bottom);
    }
    if (current.isNotEmpty) cells.add(current);
    return cells;
  }

  static String _cellText(List<_Box> cell) {
    final sorted = [...cell]..sort((a, b) => a.top.compareTo(b.top));
    final lines = <List<_Box>>[];
    for (final box in sorted) {
      if (lines.isNotEmpty && _sameVisualLine(lines.last, box)) {
        lines.last.add(box);
      } else {
        lines.add([box]);
      }
    }
    return lines
        .map((line) {
          final ordered = [...line]..sort((a, b) => a.left.compareTo(b.left));
          return ordered.map((box) => box.text).join();
        })
        .join('\n');
  }

  static bool _sameVisualLine(List<_Box> line, _Box box) {
    for (final other in line) {
      final overlap =
          math.min(other.bottom, box.bottom) - math.max(other.top, box.top);
      final shortest = math.min(other.rect.height, box.rect.height);
      if (shortest > 0 && overlap >= shortest * 0.5) return true;
    }
    return false;
  }

  // --- fallback for input with no detectable table grid -------------------

  TimetableDraft _parseWithoutGrid(OcrDocument document) {
    final weekdays = <_PositionedWeekday>[];
    final periods = <_PositionedPeriod>[];
    final ignored = <OcrLine>{};

    for (final line in document.lines) {
      final bounds = _lineBounds(line);
      if (bounds == null) continue;
      final weekday = _weekdayOf(_compact(line.text));
      if (weekday != null) {
        weekdays.add(_PositionedWeekday(weekday, _centerX(bounds)));
        ignored.add(line);
        continue;
      }
      final label = _periodLabel.firstMatch(_compact(line.text));
      if (label != null) {
        periods.add(
          _PositionedPeriod(int.parse(label.group(1)!), _centerY(bounds)),
        );
        ignored.add(line);
      }
    }
    weekdays.sort((a, b) => a.x.compareTo(b.x));
    periods.sort((a, b) => a.number.compareTo(b.number));

    final courses = <CourseDraft>[];
    var detectedTotalWeeks = 0;
    for (final line in document.lines) {
      if (ignored.contains(line) || line.text.trim().isEmpty) continue;
      final bounds = _lineBounds(line);
      if (bounds == null) continue;
      final reasons = <TimetableReviewReason>{};
      final weekday = _nearestWeekday(_centerX(bounds), weekdays);
      if (weekday == null) reasons.add(TimetableReviewReason.ambiguousWeekday);

      final covered = [
        for (final period in periods)
          if (period.y >= bounds.top && period.y <= bounds.top + bounds.height)
            period.number,
      ];
      if (covered.isEmpty) reasons.add(TimetableReviewReason.ambiguousPeriods);

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
          startPeriod: covered.isEmpty ? null : covered.reduce(math.min),
          endPeriod: covered.isEmpty ? null : covered.reduce(math.max),
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

  // --- text parsing -------------------------------------------------------

  _ParsedText _parseText(String original, Set<TimetableReviewReason> reasons) {
    final normalized = _canonical(original);
    final weekSpans = parseWeekSpans(normalized);
    if (weekSpans.isEmpty && _weekRange.hasMatch(normalized)) {
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
      } else if (_weekRange.hasMatch(candidate)) {
        // Week ranges travel in weekSpans, not in the course name.
      } else {
        content.add(candidate);
      }
    }
    var teacher = '';
    if (content.length > 1 && _teacher.hasMatch(content.last)) {
      teacher = content.removeLast();
    }
    final name = content.join().replaceAll(_whitespace, '');
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

  // --- helpers ------------------------------------------------------------

  static List<_LineBox> _collect(OcrDocument document) {
    final lines = <_LineBox>[];
    for (var index = 0; index < document.lines.length; index++) {
      final line = document.lines[index];
      final bounds = _lineBounds(line);
      if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
      final boxes = <_Box>[];
      for (final word in line.words) {
        if (word.bounds.width <= 0 || word.bounds.height <= 0) continue;
        final compact = _compact(word.text);
        if (compact.isEmpty) continue;
        boxes.add(_Box(text: word.text, compact: compact, rect: word.bounds));
      }
      if (boxes.isEmpty) continue;
      lines.add(
        _LineBox(index: index, bounds: bounds, boxes: List.unmodifiable(boxes)),
      );
    }
    return lines;
  }

  static String _compact(String text) => text.replaceAll(_whitespace, '');

  /// Fullwidth forms that real OCR emits where the source had ASCII.
  static String _canonical(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      buffer.write(switch (rune) {
        0xFF08 => '(',
        0xFF09 => ')',
        0xFF0E => '.',
        0xFF0D => '-',
        0xFF5E => '~',
        >= 0xFF10 && <= 0xFF19 => String.fromCharCode(rune - 0xFF10 + 0x30),
        _ => String.fromCharCode(rune),
      });
    }
    return buffer.toString();
  }

  static int? _weekdayOf(String compact) => const {
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
  }[compact];

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

  static OcrRect? _lineBounds(OcrLine line) {
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

final class _LineBox {
  const _LineBox({
    required this.index,
    required this.bounds,
    required this.boxes,
  });

  final int index;
  final OcrRect bounds;
  final List<_Box> boxes;

  /// Line text rebuilt from words: `line.text` may be inconsistent across
  /// platforms, while the word texts are what the geometry is computed from.
  String get compact => boxes.map((box) => box.compact).join();

  double get width => bounds.width;
  double get top => bounds.top;
}

final class _HeaderCandidate {
  const _HeaderCandidate({
    required this.weekday,
    required this.centerX,
    required this.top,
  });

  final int weekday;
  final double centerX;
  final double top;
}

final class _Box {
  const _Box({required this.text, required this.compact, required this.rect});

  final String text;
  final String compact;
  final OcrRect rect;

  double get left => rect.left;
  double get top => rect.top;
  double get bottom => rect.top + rect.height;
  double get centerX => rect.left + rect.width / 2;
  double get centerY => rect.top + rect.height / 2;
}

final class _Bounds {
  const _Bounds(this.top, this.bottom);

  factory _Bounds.of(List<_Box> boxes) {
    var top = double.infinity;
    var bottom = double.negativeInfinity;
    for (final box in boxes) {
      top = math.min(top, box.top);
      bottom = math.max(bottom, box.bottom);
    }
    return _Bounds(top, bottom);
  }

  final double top;
  final double bottom;
}

final class _Column {
  const _Column({
    required this.weekday,
    required this.left,
    required this.right,
  });
  final int weekday;
  final double left;
  final double right;
}

final class _PeriodRow {
  const _PeriodRow({
    required this.startPeriod,
    required this.endPeriod,
    required this.centerY,
  });
  final int startPeriod;
  final int endPeriod;
  final double centerY;
}

final class _Grid {
  const _Grid({
    required this.columns,
    required this.rows,
    required this.headerLines,
    required this.gutterLines,
    required this.top,
    required this.bottom,
    required this.cellGap,
    required this.columnWidth,
  });

  final List<_Column> columns;
  final List<_PeriodRow> rows;
  final Set<int> headerLines;

  /// Lines that begin in the gutter: period labels, 中午休/下午休, 备注 markers.
  final Set<int> gutterLines;
  final double top;
  final double bottom;
  final double cellGap;
  final double columnWidth;

  bool isHeaderLine(_LineBox line) => headerLines.contains(line.index);

  bool isGutterLine(_LineBox line) => gutterLines.contains(line.index);

  /// A course cell lives in one column; text that covers three or more columns
  /// is the remark block or page chrome. Two adjacent cells may legitimately
  /// share a visual line, so a merely wide line is still parsed.
  bool isWideLine(_LineBox line) {
    var overlapped = 0;
    for (final column in columns) {
      if (line.bounds.left < column.right &&
          line.bounds.left + line.bounds.width > column.left) {
        overlapped++;
      }
    }
    return overlapped >= 3;
  }

  bool crossesRowBoundary(double from, double to) {
    for (var i = 1; i < rows.length; i++) {
      final boundary = (rows[i - 1].centerY + rows[i].centerY) / 2;
      if (boundary > from && boundary < to) return true;
    }
    return false;
  }

  List<_PeriodRow> rowsCovering(_Bounds bounds) {
    final covering = [
      for (final row in rows)
        if (row.centerY >= bounds.top && row.centerY <= bounds.bottom) row,
    ];
    if (covering.isNotEmpty) return covering;
    if (rows.isEmpty) return const [];
    final center = (bounds.top + bounds.bottom) / 2;
    var nearest = rows.first;
    for (final row in rows.skip(1)) {
      if ((row.centerY - center).abs() < (nearest.centerY - center).abs()) {
        nearest = row;
      }
    }
    final rowHeight = rows.length < 2
        ? 200.0
        : (rows.last.centerY - rows.first.centerY) / (rows.length - 1);
    return (nearest.centerY - center).abs() <= rowHeight * 0.75
        ? [nearest]
        : const [];
  }

  static _Grid? detect(List<_LineBox> lines) {
    if (lines.isEmpty) return null;

    // Weekday headers are found by sliding over word runs, because OCR may put
    // each character in its own word (`星 期 一`) and may merge the whole header
    // row — all seven names — into a single line.
    final headers = <int, _HeaderCandidate>{};
    for (final line in lines) {
      for (final candidate in _weekdayCandidates(line)) {
        final existing = headers[candidate.weekday];
        if (existing == null ||
            candidate.top < existing.top - 1 ||
            ((candidate.top - existing.top).abs() <= 1 &&
                candidate.centerX < existing.centerX)) {
          headers[candidate.weekday] = candidate;
        }
      }
    }
    if (headers.length < 3) return null;

    final ordered = headers.values.toList()
      ..sort((a, b) => a.centerX.compareTo(b.centerX));
    final centers = [for (final candidate in ordered) candidate.centerX];
    final gaps = [
      for (var i = 1; i < centers.length; i++) centers[i] - centers[i - 1],
    ];
    if (gaps.isEmpty || gaps.any((gap) => gap <= 0)) return null;
    final sortedGaps = [...gaps]..sort();
    final gap = sortedGaps[sortedGaps.length ~/ 2];

    final columns = <_Column>[];
    for (var i = 0; i < ordered.length; i++) {
      final left = i == 0
          ? centers[i] - gap / 2
          : (centers[i - 1] + centers[i]) / 2;
      final right = i == ordered.length - 1
          ? centers[i] + gap / 2
          : (centers[i] + centers[i + 1]) / 2;
      columns.add(
        _Column(weekday: ordered[i].weekday, left: left, right: right),
      );
    }
    final gutterRight = columns.first.left;
    final headerTop = ordered
        .map((candidate) => candidate.top)
        .reduce(math.min);
    final headerLines = <int>{};
    for (final line in lines) {
      if (_weekdayCandidates(line).isNotEmpty) headerLines.add(line.index);
    }

    // Period rows are labelled by the words in the gutter left of column one.
    // The label may be wider than the gutter, so match the longest run of words
    // starting at the line's left edge rather than trusting a per-word cut.
    final rows = <_PeriodRow>[];
    for (final line in lines) {
      final ordered = [...line.boxes]..sort((a, b) => a.left.compareTo(b.left));
      if (ordered.isEmpty || ordered.first.left >= gutterRight) continue;
      for (var size = math.min(6, ordered.length); size >= 1; size--) {
        final run = ordered.sublist(0, size);
        final match = TimetableParser._periodLabel.firstMatch(
          run.map((box) => box.compact).join(),
        );
        if (match == null) continue;
        final start = int.parse(match.group(1)!);
        final end = match.group(2) == null ? start : int.parse(match.group(2)!);
        if (start < 1 || end < start || end > 24) continue;
        final centersY = [for (final box in run) box.centerY];
        rows.add(
          _PeriodRow(
            startPeriod: start,
            endPeriod: end,
            centerY: centersY.reduce((a, b) => a + b) / centersY.length,
          ),
        );
        break;
      }
    }

    // Anything starting in the gutter is a label — a period, 中午休/下午休 or the
    // remark marker — so none of its glyphs may end up inside a course cell,
    // even when the label is wider than the gutter itself.
    final gutterLines = <int>{};
    for (final line in lines) {
      final leftmost = line.boxes
          .map((box) => box.left)
          .reduce((a, b) => math.min(a, b));
      if (leftmost < gutterRight) gutterLines.add(line.index);
    }
    rows.sort((a, b) => a.centerY.compareTo(b.centerY));
    final deduped = <_PeriodRow>[];
    for (final row in rows) {
      if (deduped.isNotEmpty &&
          (row.centerY - deduped.last.centerY).abs() < 6 &&
          row.startPeriod == deduped.last.startPeriod) {
        continue;
      }
      deduped.add(row);
    }

    // The remark block and everything below it is not part of the grid.
    var noteTop = double.infinity;
    for (final line in lines) {
      if (line.compact.contains('备注')) {
        noteTop = math.min(noteTop, line.top);
      }
    }
    final rowHeight = deduped.length < 2
        ? 200.0
        : (deduped.last.centerY - deduped.first.centerY) / (deduped.length - 1);
    final bottom = noteTop.isFinite
        ? noteTop
        : deduped.isEmpty
        ? double.infinity
        : deduped.last.centerY + rowHeight;

    final heights = [
      for (final line in lines)
        for (final box in line.boxes) box.rect.height,
    ]..sort();
    final medianHeight = heights.isEmpty ? 20.0 : heights[heights.length ~/ 2];

    // With a known row height, distance is measured against the table's own
    // rhythm: a cell's lines can be spread out (OCR drops a line), while two
    // rows are always a boundary apart.
    final cellGap = deduped.length >= 2
        ? rowHeight * 0.6
        : math.max(TimetableParser.cellGapFactor * medianHeight, 16.0);

    return _Grid(
      columns: List.unmodifiable(columns),
      rows: List.unmodifiable(deduped),
      headerLines: headerLines,
      gutterLines: gutterLines,
      top: headerTop,
      bottom: bottom,
      cellGap: cellGap,
      columnWidth: gap,
    );
  }

  /// Weekday names inside one OCR line, matched over runs of 1–3 words.
  static List<_HeaderCandidate> _weekdayCandidates(_LineBox line) {
    final found = <_HeaderCandidate>[];
    final boxes = line.boxes;
    for (var i = 0; i < boxes.length; i++) {
      for (final size in const [3, 2, 1]) {
        if (i + size > boxes.length) continue;
        final text = [for (var k = i; k < i + size; k++) boxes[k].compact]
            .join();
        final weekday = TimetableParser._weekdayOf(text);
        if (weekday == null) continue;
        final first = boxes[i];
        final last = boxes[i + size - 1];
        found.add(
          _HeaderCandidate(
            weekday: weekday,
            centerX: (first.left + last.left + last.rect.width) / 2,
            top: first.top,
          ),
        );
        break;
      }
    }
    return found;
  }
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
