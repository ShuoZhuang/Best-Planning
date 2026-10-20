// 草稿 Release 的发布门禁（UPD-043 / UPD-INC-030 的发布资产不可变检查）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/package_identity.dart';

import '../support/update_fixtures.dart';
import '../../tool/update_pipeline.dart';
import '../../tool/update_publisher.dart';

const GhResult _notFound = GhResult(1, '', 'gh: Not Found (HTTP 404)');

bool _isReleaseTagProbe(List<String> arguments) =>
    arguments.length >= 2 &&
    arguments[0] == 'api' &&
    arguments[1].contains('/releases/tags/');

bool _isTagRefProbe(List<String> arguments) =>
    arguments.length >= 2 &&
    arguments[0] == 'api' &&
    arguments[1].contains('/git/ref/tags/');

bool _isLatest(List<String> arguments) =>
    arguments.length >= 2 &&
    arguments[0] == 'api' &&
    arguments[1].endsWith('/releases/latest');

bool _isReleaseCommand(List<String> arguments, String subcommand) =>
    arguments.length >= 2 &&
    arguments[0] == 'release' &&
    arguments[1] == subcommand;

String _releaseJson({List<String> assets = const []}) => jsonEncode({
  'tag_name': 'v1.9.0',
  'draft': false,
  'assets': [
    for (final name in assets) {'name': name},
  ],
});

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

  test('新 tag 且远端无资产时允许发布，并完成回读复核与 latest 核对', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (_isReleaseTagProbe(arguments) || _isTagRefProbe(arguments)) {
        return _notFound;
      }
      if (_isLatest(arguments)) {
        return const GhResult(0, '{"tag_name":"v1.9.0"}', '');
      }
      if (_isReleaseCommand(arguments, 'download')) {
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
    // 不可变门禁在创建草稿之前查过 tag：先查 Release，再查裸 tag。
    expect(commands.where(_isReleaseTagProbe), hasLength(1));
    expect(commands.where(_isTagRefProbe), hasLength(1));
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
    // 发布工具**不得**提供覆盖已有资产的入口。
    expect(
      commands.where((command) => command.contains('--clobber')),
      isEmpty,
      reason: '发现资产已存在只能换版本号，不允许 --clobber 覆盖',
    );
  });

  test('目标 tag 下已有同名资产时拒绝发布，且不创建草稿', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (_isReleaseTagProbe(arguments)) {
        return GhResult(
          0,
          _releaseJson(assets: const ['BestPlanning_1.9.0.0_x64.msix']),
          '',
        );
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
      throwsA(
        isA<PublishException>()
            .having((error) => error.message, 'message', contains('同名资产'))
            .having(
              (error) => error.message,
              'message',
              contains('BestPlanning_1.9.0.0_x64.msix'),
            )
            .having((error) => error.message, 'message', contains('新版本号')),
      ),
    );
    expect(
      commands.where((command) => _isReleaseCommand(command, 'create')),
      isEmpty,
      reason: '不可变门禁必须在创建草稿之前中止',
    );
    expect(
      commands.where((command) => _isReleaseCommand(command, 'upload')),
      isEmpty,
    );
  });

  test('tag 已存在但没有同名资产时仍拒绝（tag 不可变）', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (_isReleaseTagProbe(arguments)) {
        // Release 存在，但资产名与本次要上传的都不同。
        return GhResult(0, _releaseJson(assets: const ['SHA256SUMS.txt']), '');
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
      throwsA(
        isA<PublishException>()
            .having(
              (error) => error.message,
              'message',
              contains('tag v1.9.0 已存在'),
            )
            .having((error) => error.message, 'message', contains('不可变')),
      ),
    );
    expect(
      commands.where((command) => _isReleaseCommand(command, 'create')),
      isEmpty,
    );
  });

  test('tag 只是一个裸 tag（没有 Release）时同样拒绝', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (_isReleaseTagProbe(arguments)) return _notFound;
      if (_isTagRefProbe(arguments)) {
        return const GhResult(0, '{"ref":"refs/tags/v1.9.0"}', '');
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
      throwsA(
        isA<PublishException>().having(
          (error) => error.message,
          'message',
          contains('tag v1.9.0 已存在'),
        ),
      ),
    );
    expect(
      commands.where((command) => _isReleaseCommand(command, 'create')),
      isEmpty,
    );
  });

  test('无法确认远端状态时中止发布（探测失败不等于不存在）', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (_isReleaseTagProbe(arguments)) {
        return const GhResult(1, '', 'dial tcp: connect: connection refused');
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
      throwsA(
        isA<PublishException>().having(
          (error) => error.message,
          'message',
          contains('已中止发布'),
        ),
      ),
    );
    expect(
      commands.where((command) => _isReleaseCommand(command, 'create')),
      isEmpty,
    );
    expect(commands.where(_isTagRefProbe), isEmpty, reason: '首个探测就失败，不再猜');
  });

  test('回读的资产被替换时不发布', () async {
    final commands = <List<String>>[];
    final runner = _FakeGh((arguments) async {
      commands.add(arguments);
      if (_isReleaseTagProbe(arguments) || _isTagRefProbe(arguments)) {
        return _notFound;
      }
      if (_isReleaseCommand(arguments, 'download')) {
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
