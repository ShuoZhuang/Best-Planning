abstract interface class TimetableOcrEngine {
  Future<OcrDocument> recognize(OcrImageRequest request);
}

enum TimetableOcrFailureCode {
  platformUnavailable,
  languageUnavailable,
  imageTooLarge,
  decodeFailed,
  recognitionFailed,
}

final class TimetableOcrException implements Exception {
  const TimetableOcrException(this.code, [this.message]);

  final TimetableOcrFailureCode code;
  final String? message;

  @override
  String toString() =>
      'TimetableOcrException($code${message == null ? '' : ': $message'})';
}

final class OcrImageRequest {
  const OcrImageRequest({
    required this.path,
    this.cropRect,
    this.quarterTurns = 0,
    this.languageTag = 'zh-Hans',
  }) : assert(path != ''),
       assert(quarterTurns >= 0 && quarterTurns <= 3),
       assert(languageTag != '');

  final String path;
  final OcrCropRect? cropRect;
  final int quarterTurns;
  final String languageTag;
}

final class OcrCropRect {
  const OcrCropRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  }) : assert(left >= 0 && top >= 0),
       assert(width > 0 && height > 0),
       assert(left + width <= 1),
       assert(top + height <= 1);

  final double left;
  final double top;
  final double width;
  final double height;
}

final class OcrRect {
  const OcrRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;
}

final class OcrWord {
  const OcrWord({required this.text, required this.bounds});

  final String text;
  final OcrRect bounds;
}

final class OcrLine {
  const OcrLine({required this.text, required this.words});

  final String text;
  final List<OcrWord> words;
}

final class OcrDocument {
  const OcrDocument({
    required this.width,
    required this.height,
    required this.textAngle,
    required this.lines,
  }) : assert(width > 0),
       assert(height > 0);

  final int width;
  final int height;
  final double? textAngle;
  final List<OcrLine> lines;
}
