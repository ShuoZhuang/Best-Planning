import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/platform/ocr/windows_timetable_ocr.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native OCR reads a user-selected ordinary file without broker access',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'personal-planner-native-ocr-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final imagePath = '${directory.path}${Platform.pathSeparator}blank.png';
      await _writeBlankPng(imagePath);

      final document = await WindowsTimetableOcr(
        platform: TargetPlatform.windows,
      ).recognize(OcrImageRequest(path: imagePath));

      expect(document.width, 640);
      expect(document.height, 480);
    },
  );
}

Future<void> _writeBlankPng(String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 640, 480),
    Paint()..color = Colors.white,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(640, 480);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  if (data == null) {
    throw StateError('Flutter could not encode the PNG fixture.');
  }
  await File(path).writeAsBytes(data.buffer.asUint8List(), flush: true);
}
