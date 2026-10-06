import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';

void main() {
  test('OCR request validates normalized crop and quarter turns', () {
    expect(
      () => OcrImageRequest(
        path: 'schedule.png',
        cropRect: OcrCropRect(left: -0.1, top: 0, width: 1, height: 1),
      ),
      throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
    );
    expect(
      () => OcrImageRequest(path: 'schedule.png', quarterTurns: 4),
      throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
    );
  });

  test('OCR document keeps nullable angle and word geometry', () {
    const document = OcrDocument(
      width: 1200,
      height: 800,
      textAngle: null,
      lines: [
        OcrLine(
          text: '算法与数据结构',
          words: [
            OcrWord(
              text: '算法',
              bounds: OcrRect(left: 100, top: 80, width: 60, height: 24),
            ),
          ],
        ),
      ],
    );

    expect(document.textAngle, isNull);
    expect(document.lines.single.words.single.bounds.left, 100);
  });
}
