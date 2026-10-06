// Regenerates test/fixtures/timetable/screenshot_grid_ocr.json.
//
// The fixture mirrors what Windows OCR really returns for a phone screenshot of
// a course grid — one line per visual row, one word per CJK character, range
// dashes recognised as '．' or '一', period labels shaped '01 · 02 节', plus
// browser chrome, a lunch separator row and a remark block. Course and teacher
// names are invented so no real timetable data enters the repository.
//
//   dart run tool/make_timetable_ocr_fixture.dart
import 'dart:convert';
import 'dart:io';

class _Word {
  _Word(this.text, this.left, this.top, this.width, this.height);

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  Map<String, Object?> toJson() => {
    'text': text,
    'bounds': {'left': left, 'top': top, 'width': width, 'height': height},
  };
}

final _words = <_Word>[];

/// Splits text the way the engine does: an ASCII run stays one token, each CJK
/// character becomes its own token. Words never carry surrounding whitespace —
/// only a line's `text` field is space separated.
List<String> _tokens(String text) {
  final out = <String>[];
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x20) continue;
    if (rune < 128) {
      buffer.writeCharCode(rune);
    } else {
      if (buffer.isNotEmpty) {
        out.add(buffer.toString());
        buffer.clear();
      }
      out.add(String.fromCharCode(rune));
    }
  }
  if (buffer.isNotEmpty) out.add(buffer.toString());
  return out;
}

void _addLine(double left, double top, String text, {double charWidth = 20}) {
  var x = left;
  for (final token in _tokens(text)) {
    var width = 0.0;
    for (final rune in token.runes) {
      width += rune < 128 ? charWidth * 0.6 : charWidth;
    }
    _words.add(_Word(token, x, top, width, 22));
    x += width;
  }
}

void main() {
  const colCenters = <double>[150, 300, 450, 600, 750, 900, 1050];
  const weekdayNames = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  const rowTops = <double>[290, 410, 590, 710];
  const rowLabels = ['01 · 02 节', '03 · 04 节', '05 · 06 节', '07 · 08 节'];

  for (var i = 0; i < weekdayNames.length; i++) {
    _addLine(colCenters[i] - 30, 190, weekdayNames[i]);
  }
  for (var i = 0; i < rowLabels.length; i++) {
    _addLine(30, rowTops[i], rowLabels[i]);
  }
  _addLine(40, 500, '中午休');

  void course(
    int col,
    int row,
    List<String> nameLines,
    String teacher,
    String weeks,
    String location,
  ) {
    var top = <double>[215, 380, 530, 690][row];
    final x = colCenters[col] - 70;
    for (final name in nameLines) {
      _addLine(x, top, name);
      top += 30;
    }
    _addLine(x + 30, top, teacher);
    top += 30;
    _addLine(x + 15, top, weeks);
    top += 30;
    if (location.isNotEmpty) _addLine(x + 30, top, location);
  }

  course(0, 0, ['软件工程'], '陈一', '1．16（周）', 'D206');
  course(1, 1, ['数据结构与算法'], '林二', '1．13（周）', 'D206');
  course(2, 1, ['大学英语（下）'], '赵敏', '1．16（单周）', 'A402');
  course(2, 2, ['概率论与', '数理统计'], '钱六', '2一6（双周）', 'A304');
  course(6, 3, ['人工智能', '导论'], '李八', '1一4（周）', '');

  // Page chrome and the remark block, none of which is a course.
  _addLine(85, 20, '10：08');
  _addLine(40, 90, '首页 » 我的课表 » 学期个人课表');
  _addLine(40, 120, '周次：（全部） 学年学期： 2026-2027-1');
  _addLine(40, 1480, '碳中和技术概论 田程程 1一16周；形势与政策（3） 1一16周；思政课实践教学（2）');
  _addLine(30, 1510, '备注：');
  _addLine(380, 1560, 'inquiry.example.edu.cn');

  // Rebuild OCR lines the way the engine segments them: a new line starts when
  // the vertical position changes or a horizontal gap opens up.
  const gapThreshold = 8.0;
  final sorted = [..._words]
    ..sort((a, b) {
      final byTop = a.top.compareTo(b.top);
      return byTop != 0 ? byTop : a.left.compareTo(b.left);
    });
  final lines = <Map<String, Object?>>[];
  var current = <_Word>[];
  var currentTop = double.nan;
  var currentRight = double.nan;
  void flush() {
    if (current.isEmpty) return;
    lines.add({
      'text': current.map((word) => word.text).join(' '),
      'words': [for (final word in current) word.toJson()],
    });
    current = <_Word>[];
  }

  for (final word in sorted) {
    final startsLine =
        current.isEmpty ||
        (word.top - currentTop).abs() > 1 ||
        word.left - currentRight > gapThreshold;
    if (startsLine) flush();
    currentTop = word.top;
    currentRight = word.left + word.width;
    current.add(word);
  }
  flush();

  const path = 'test/fixtures/timetable/screenshot_grid_ocr.json';
  File(path).writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'width': 1200,
      'height': 1600,
      'textAngle': 0,
      'lines': lines,
    }),
  );
  stdout.writeln('wrote $path : ${lines.length} lines, ${_words.length} words');
}
