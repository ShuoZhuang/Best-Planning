import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/platform/ocr/windows_timetable_ocr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_planner/timetable_ocr');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('serializes request and deserializes word bounds', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return <String, Object?>{
            'width': 1000,
            'height': 700,
            'textAngle': 1.5,
            'lines': [
              {
                'text': '大学物理',
                'words': [
                  {
                    'text': '大学物理',
                    'bounds': {
                      'left': 20.0,
                      'top': 30.0,
                      'width': 80.0,
                      'height': 24.0,
                    },
                  },
                ],
              },
            ],
          };
        });
    final engine = WindowsTimetableOcr(
      channel: channel,
      platform: TargetPlatform.windows,
    );

    final result = await engine.recognize(
      const OcrImageRequest(
        path: r'G:\tmp\schedule.png',
        cropRect: OcrCropRect(left: 0.1, top: 0.2, width: 0.7, height: 0.6),
        quarterTurns: 1,
        languageTag: 'zh-Hans',
      ),
    );

    expect(received?.method, 'recognize');
    expect(received?.arguments, {
      'path': r'G:\tmp\schedule.png',
      'cropRect': {'left': 0.1, 'top': 0.2, 'width': 0.7, 'height': 0.6},
      'quarterTurns': 1,
      'languageTag': 'zh-Hans',
    });
    expect(result.textAngle, 1.5);
    expect(result.lines.single.words.single.bounds.width, 80);
  });

  test('keeps a nullable text angle', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'width': 1,
            'height': 1,
            'textAngle': null,
            'lines': <Object?>[],
          },
        );
    final result = await WindowsTimetableOcr(
      channel: channel,
      platform: TargetPlatform.windows,
    ).recognize(const OcrImageRequest(path: 'schedule.png'));

    expect(result.textAngle, isNull);
  });

  for (final entry in const {
    'language_unavailable': TimetableOcrFailureCode.languageUnavailable,
    'image_too_large': TimetableOcrFailureCode.imageTooLarge,
    'decode_failed': TimetableOcrFailureCode.decodeFailed,
    'recognition_failed': TimetableOcrFailureCode.recognitionFailed,
  }.entries) {
    test('maps platform error ${entry.key}', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: entry.key),
          );
      final engine = WindowsTimetableOcr(
        channel: channel,
        platform: TargetPlatform.windows,
      );

      await expectLater(
        engine.recognize(const OcrImageRequest(path: 'schedule.png')),
        throwsA(
          isA<TimetableOcrException>().having(
            (error) => error.code,
            'code',
            entry.value,
          ),
        ),
      );
    });
  }

  test('unsupported platforms return a typed unavailable failure', () async {
    final engine = WindowsTimetableOcr(
      channel: channel,
      platform: TargetPlatform.android,
    );

    await expectLater(
      engine.recognize(const OcrImageRequest(path: 'schedule.png')),
      throwsA(
        isA<TimetableOcrException>().having(
          (error) => error.code,
          'code',
          TimetableOcrFailureCode.platformUnavailable,
        ),
      ),
    );
  });
}
