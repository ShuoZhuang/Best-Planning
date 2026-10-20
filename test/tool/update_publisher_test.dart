// 草稿 Release 的发布门禁（UPD-043）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/package_identity.dart';

import '../support/update_fixtures.dart';
import '../../tool/update_pipeline.dart';
import '../../tool/update_publisher.dart';

void main() {
  late Directory directory;
  late File msix;
  late File manifest;
  late Map<String, String> publicKeys;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('update_publish_test_');
    msix = await _writeMsix(directory);
    final signer = await createTestSigner();
    publicKeys = {testSigningKeyId: await signer.publicKeyHex()};
    final payload = await buildManifestPayload(
      msix: msix,
      version: '1.9.0',
      buildNumber: 46,
      msixVersion: '1.9.0.0',
    );
    manifest = File(
      '${directory.path}${Platform.pathSeparator}update-manifest.json',
    );
    await manifest.writeAsString(
      jsonEncode(await signer.signEnvelope(payload)),
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('草稿上传后从 GitHub 回读复核，通过才发布并核对 latest', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (arguments.first == 'release' && arguments[1] == 'download') {
        final dirIndex = arguments.indexOf('--dir');
        final target = Directory(arguments[dirIndex + 1]);
        await target.create(recursive: true);
        await File(
          '${target.path}${Platform.pathSeparator}update-manifest.json',
        ).writeAsBytes(await manifest.readAsBytes());
        await File(
          '${target.path}${Platform.pathSeparator}BestPlanning_1.9.0.0_x64.msix',
        ).writeAsBytes(await msix.readAsBytes());
        return const GhResult(0, '', '');
      }
      if (arguments.first == 'api') {
        return const GhResult(0, '{"tag_name":"v1.9.0"}', '');
      }
      return const GhResult(0, '', '');
    });

    final publisher = UpdatePublisher(
      repository: 'ShuoZhuang/Best-Planning',
      workspace: directory,
      runner: runner.call,
      publicKeys: publicKeys,
    );
    final result = await publisher.publish(
      tag: 'v1.9.0',
      manifestFile: manifest,
      msixFile: msix,
      title: 'Best Planning 1.9.0',
    );

    expect(result.latestTag, 'v1.9.0');
    expect(result.packageSha256, hasLength(64));
    expect(
      commands.map((command) => command.take(2).join(' ')),
      containsAllInOrder([
        'release create',
        'release upload',
        'release download',
        'release edit',
        'api repos/ShuoZhuang/Best-Planning/releases/latest',
      ]),
    );
    // 草稿创建与正式发布分开。
    expect(
      commands.where((command) => command.contains('--draft=false')),
      hasLength(1),
    );
  });

  test('回读的资产被替换时不发布', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (arguments.first == 'release' && arguments[1] == 'download') {
        final dirIndex = arguments.indexOf('--dir');
        final target = Directory(arguments[dirIndex + 1]);
        await target.create(recursive: true);
        await File(
          '${target.path}${Platform.pathSeparator}update-manifest.json',
        ).writeAsBytes(await manifest.readAsBytes());
        await File(
          '${target.path}${Platform.pathSeparator}BestPlanning_1.9.0.0_x64.msix',
        ).writeAsBytes([...await msix.readAsBytes(), 0]);
        return const GhResult(0, '', '');
      }
      return const GhResult(0, '', '');
    });

    final publisher = UpdatePublisher(
      repository: 'ShuoZhuang/Best-Planning',
      workspace: directory,
      runner: runner.call,
      publicKeys: publicKeys,
    );

    await expectLater(
      publisher.publish(
        tag: 'v1.9.0',
        manifestFile: manifest,
        msixFile: msix,
        title: 'Best Planning 1.9.0',
      ),
      throwsA(isA<PublishException>()),
    );
    expect(
      commands.where((command) => command.contains('--draft=false')),
      isEmpty,
    );
  });

  test('本地清单与成品不一致时不上传', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      return const GhResult(0, '', '');
    });
    final publisher = UpdatePublisher(
      repository: 'ShuoZhuang/Best-Planning',
      workspace: directory,
      runner: runner.call,
      publicKeys: publicKeys,
    );

    await File(manifest.path).writeAsString('{"payload":{},"signature":{}}');

    await expectLater(
      publisher.publish(
        tag: 'v1.9.0',
        manifestFile: manifest,
        msixFile: msix,
        title: 't',
      ),
      throwsA(isA<PublishException>()),
    );
    expect(commands, isEmpty);
  });
}

final class _FakeGh {
  const _FakeGh(this._handler);

  final Future<GhResult> Function(List<String> arguments) _handler;

  Future<GhResult> call(List<String> arguments) => _handler(arguments);
}

Future<File> _writeMsix(Directory directory) async {
  final archive = Archive()
    ..add(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
    ..add(ArchiveFile.string('AppxBlockMap.xml', '<BlockMap/>'))
    ..add(ArchiveFile.string('AppxSignature.p7x', 'signature'))
    ..add(
      ArchiveFile.string('AppxManifest.xml', '''<?xml version="1.0"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$appPackageIdentityName" Publisher="$appPublisher" Version="1.9.0.0" ProcessorArchitecture="x64" />
</Package>'''),
    );
  final file = File('${directory.path}${Platform.pathSeparator}package.msix');
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}
