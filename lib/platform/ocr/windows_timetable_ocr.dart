import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';

final class WindowsTimetableOcr implements TimetableOcrEngine {
  WindowsTimetableOcr({MethodChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? const MethodChannel(_channelName),
      _platform = platform ?? defaultTargetPlatform;

  static const _channelName = 'personal_planner/timetable_ocr';

  final MethodChannel _channel;
  final TargetPlatform _platform;

  @override
  Future<OcrDocument> recognize(OcrImageRequest request) async {
    if (_platform != TargetPlatform.windows) {
      throw const TimetableOcrException(
        TimetableOcrFailureCode.platformUnavailable,
      );
    }
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'recognize',
        <String, Object?>{
          'path': request.path,
          'cropRect': request.cropRect == null
              ? null
              : <String, double>{
                  'left': request.cropRect!.left,
                  'top': request.cropRect!.top,
                  'width': request.cropRect!.width,
                  'height': request.cropRect!.height,
                },
          'quarterTurns': request.quarterTurns,
          'languageTag': request.languageTag,
        },
      );
      if (response == null) {
        throw const TimetableOcrException(
          TimetableOcrFailureCode.recognitionFailed,
          'The OCR channel returned no document.',
        );
      }
      return _documentFromMap(response);
    } on TimetableOcrException {
      rethrow;
    } on MissingPluginException {
      throw const TimetableOcrException(
        TimetableOcrFailureCode.platformUnavailable,
      );
    } on PlatformException catch (error) {
      throw TimetableOcrException(_failureCode(error.code), error.message);
    } on Object catch (error) {
      throw TimetableOcrException(
        TimetableOcrFailureCode.recognitionFailed,
        error.toString(),
      );
    }
  }

  static OcrDocument _documentFromMap(Map<String, Object?> map) {
    final lines = (map['lines'] as List<Object?>? ?? const <Object?>[])
        .map((value) => _lineFromMap(_stringMap(value)))
        .toList(growable: false);
    return OcrDocument(
      width: (map['width'] as num).toInt(),
      height: (map['height'] as num).toInt(),
      textAngle: (map['textAngle'] as num?)?.toDouble(),
      lines: lines,
    );
  }

  static OcrLine _lineFromMap(Map<String, Object?> map) => OcrLine(
    text: map['text'] as String? ?? '',
    words: (map['words'] as List<Object?>? ?? const <Object?>[])
        .map((value) => _wordFromMap(_stringMap(value)))
        .toList(growable: false),
  );

  static OcrWord _wordFromMap(Map<String, Object?> map) => OcrWord(
    text: map['text'] as String? ?? '',
    bounds: _rectFromMap(_stringMap(map['bounds'])),
  );

  static OcrRect _rectFromMap(Map<String, Object?> map) => OcrRect(
    left: (map['left'] as num).toDouble(),
    top: (map['top'] as num).toDouble(),
    width: (map['width'] as num).toDouble(),
    height: (map['height'] as num).toDouble(),
  );

  static Map<String, Object?> _stringMap(Object? value) =>
      (value as Map<Object?, Object?>).map(
        (key, value) => MapEntry(key as String, value),
      );

  static TimetableOcrFailureCode _failureCode(String code) => switch (code) {
    'language_unavailable' => TimetableOcrFailureCode.languageUnavailable,
    'image_too_large' => TimetableOcrFailureCode.imageTooLarge,
    'decode_failed' => TimetableOcrFailureCode.decodeFailed,
    'recognition_failed' => TimetableOcrFailureCode.recognitionFailed,
    _ => TimetableOcrFailureCode.recognitionFailed,
  };
}
