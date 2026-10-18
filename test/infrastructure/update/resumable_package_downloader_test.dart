// 断点续传下载器（UPD-010～UPD-014）。
//
// 用本机 `HttpServer` 模拟真实的 200/206/416、忽略 Range 与重定向；不依赖外网，也不依赖
// 任何"预览环境恰好支持 Range"的假设。
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/resumable_package_downloader.dart';

void main() {
  late Directory directory;
  late _PackageServer server;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('update_download_test_');
    server = await _PackageServer.start();
  });

  tearDown(() async {
    await server.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  UpdateTarget targetFor(List<int> body, {Uri? uri}) => UpdateTarget(
    version: const SemVer(1, 9, 0),
    buildNumber: 46,
    tag: 'v1.9.0',
    msixVersion: const MsixVersion(1, 9, 0, 0),
    fileName: 'BestPlanning_1.9.0.0_x64.msix',
    downloadUrl: (uri ?? server.uri).toString(),
    sizeBytes: body.length,
    sha256: sha256.convert(body).toString(),
    manifestDigest: 'a' * 64,
    keyId: 'test-key',
  );

  Future<String> partialPath(UpdateTarget target) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${target.msixVersion.value}'
      '${Platform.pathSeparator}package.msix.partial',
    );
    await file.parent.create(recursive: true);
    return file.path;
  }

  String readyPath(UpdateTarget target) =>
      '${directory.path}${Platform.pathSeparator}${target.msixVersion.value}'
      '${Platform.pathSeparator}package.msix.ready';

  ResumablePackageDownloader downloader() => ResumablePackageDownloader(
    isAllowedInitial: (uri) => true,
    isAllowedRedirect: (uri) => uri.host == '127.0.0.1',
    timeout: const Duration(seconds: 5),
  );

  test('全新下载：写入 .partial，校验大小与 SHA-256 后改名为 .ready', () async {
    final body = _bytes(5000);
    server.body = body;
    server.etag = '"v1"';
    final target = targetFor(body);
    final partial = await partialPath(target);
    final progress = <int>[];

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (received, total) => progress.add(received),
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    expect(outcome.sha256, target.sha256);
    expect(outcome.etag, '"v1"');
    expect(await File(partial).exists(), isFalse, reason: '.partial 必须被改名');
    expect(await File(readyPath(target)).length(), body.length);
    expect(progress.last, body.length);
    expect(server.requests.first.value('range'), isNull);
  });

  test('断点续传：有 .partial 时发送 Range 与 If-Range，从正确偏移继续', () async {
    final body = _bytes(5000);
    server.body = body;
    server.etag = '"v1"';
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes(body.sublist(0, 1234));

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      etag: '"v1"',
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    final request = server.requests.single;
    expect(request.value('range'), 'bytes=1234-');
    expect(request.value('if-range'), '"v1"');
    expect(await File(readyPath(target)).readAsBytes(), body);
  });

  test('服务器忽略 Range（200）：清空旧分段重下，不拼接旧字节', () async {
    final body = _bytes(5000);
    server.body = body;
    server.supportRange = false;
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes([1, 2, 3, 4, 5]);

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      etag: '"v1"',
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    expect(await File(readyPath(target)).readAsBytes(), body);
  });

  test('416 且本地文件已完整：直接完成，不再重下', () async {
    final body = _bytes(4096);
    server.body = body;
    server.forceStatus = 416;
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes(body);

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    expect(await File(readyPath(target)).readAsBytes(), body);
  });

  test('416 且本地文件不完整：清空分段后重下', () async {
    final body = _bytes(4096);
    server.body = body;
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes(body.sublist(0, 100));
    // 第一次返回 416，第二次按正常 Range 处理。
    server.failFirst416 = true;

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    expect(await File(readyPath(target)).readAsBytes(), body);
  });

  test('哈希不符：删除分段并报告 downloadHashMismatch', () async {
    final body = _bytes(3000);
    server.body = body;
    final target = UpdateTarget(
      version: const SemVer(1, 9, 0),
      buildNumber: 46,
      tag: 'v1.9.0',
      msixVersion: const MsixVersion(1, 9, 0, 0),
      fileName: 'pkg.msix',
      downloadUrl: server.uri.toString(),
      sizeBytes: body.length,
      sha256: '0' * 64,
      manifestDigest: 'a' * 64,
      keyId: 'test-key',
    );
    final partial = await partialPath(target);

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.failure!.code, UpdateFailureCode.downloadHashMismatch);
    expect(await File(partial).exists(), isFalse);
    expect(await File(readyPath(target)).exists(), isFalse);
  });

  test('大小不符：报告 downloadSizeMismatch 并保留分段', () async {
    final body = _bytes(3000);
    server.body = body;
    final target = UpdateTarget(
      version: const SemVer(1, 9, 0),
      buildNumber: 46,
      tag: 'v1.9.0',
      msixVersion: const MsixVersion(1, 9, 0, 0),
      fileName: 'pkg.msix',
      downloadUrl: server.uri.toString(),
      sizeBytes: body.length + 10,
      sha256: '0' * 64,
      manifestDigest: 'a' * 64,
      keyId: 'test-key',
    );
    final partial = await partialPath(target);

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.failure!.code, UpdateFailureCode.downloadSizeMismatch);
    expect(await File(partial).exists(), isTrue, reason: '下次应能续传');
  });

  test('取消：保留分段，不产生 .ready', () async {
    final body = _bytes(200000);
    server.body = body;
    final target = targetFor(body);
    final partial = await partialPath(target);

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => true,
      onProgress: (_, _) {},
    );

    expect(outcome.cancelled, isTrue);
    expect(await File(readyPath(target)).exists(), isFalse);
  });

  test('允许的重定向会跟随', () async {
    final body = _bytes(2000);
    server.body = body;
    server.redirectFirstTo = 'http://127.0.0.1:${server.port}/real-package';
    final target = targetFor(body);

    final outcome = await downloader().download(
      target: target,
      partialPath: await partialPath(target),
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    expect(server.requests, hasLength(2));
  });

  test('重定向到未知主机会被拒绝', () async {
    final body = _bytes(2000);
    server.body = body;
    server.redirectFirstTo = 'https://evil.example/package.msix';
    final target = targetFor(body);

    final outcome = await downloader().download(
      target: target,
      partialPath: await partialPath(target),
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(
      outcome.failure!.code,
      UpdateFailureCode.manifestSourceNotAllowed,
    );
  });

  // ── 落盘失败与恢复（实施计划 §9.3 / §9.5）─────────────────────────────────

  test('完整且哈希正确的 .partial 提升失败：保留分段、报告细节、不重新下载', () async {
    final body = _bytes(4096);
    server.body = body;
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes(body);
    // `.ready` 位置被目录占住 → 提升必然失败。
    await Directory(readyPath(target)).create();

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isFalse);
    expect(outcome.failure!.code, UpdateFailureCode.downloadPromotionFailed);
    expect(outcome.failure!.detail, contains('op=promote'));
    expect(outcome.failure!.windowsResultCode, isNotNull);
    expect(await File(partial).readAsBytes(), body, reason: '已验证的字节不能被删除');
    expect(
      server.requests,
      isEmpty,
      reason: '提升失败不是重新下载的理由（下一次启动再试）',
    );
  });

  test('重启后只用 .partial 完成提升，不发起任何 HTTP 请求', () async {
    final body = _bytes(2048);
    server.body = body;
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes(body);

    final outcome = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );

    expect(outcome.isSuccess, isTrue, reason: '${outcome.failure?.code}');
    expect(await File(partial).exists(), isFalse);
    expect(await File(readyPath(target)).readAsBytes(), body);
    expect(server.requests, isEmpty);
  });

  test('解除占用后无需重新下载即可恢复', () async {
    final body = _bytes(1024);
    server.body = body;
    final target = targetFor(body);
    final partial = await partialPath(target);
    await File(partial).writeAsBytes(body);
    final blocked = Directory(readyPath(target));
    await blocked.create();

    final first = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );
    expect(first.failure!.code, UpdateFailureCode.downloadPromotionFailed);
    expect(await File(partial).exists(), isTrue);

    await blocked.delete();
    final second = await downloader().download(
      target: target,
      partialPath: partial,
      readyPath: readyPath(target),
      shouldCancel: () => false,
      onProgress: (_, _) {},
    );
    expect(second.isSuccess, isTrue, reason: '${second.failure?.code}');
    expect(await File(readyPath(target)).readAsBytes(), body);
    expect(server.requests, isEmpty);
  });
}

List<int> _bytes(int length) =>
    List<int>.generate(length, (index) => index % 251);

final class _PackageServer {
  _PackageServer._(this._server);

  final HttpServer _server;
  List<int> body = const [];
  String etag = '"v1"';
  bool supportRange = true;
  bool failFirst416 = false;
  int? forceStatus;
  String? redirectFirstTo;
  final List<HttpHeaders> requests = [];

  int get port => _server.port;

  Uri get uri => Uri.parse('http://127.0.0.1:$port/package.msix');

  static Future<_PackageServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _PackageServer._(server);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.headers);
    final response = request.response;
    try {
      if (redirectFirstTo != null && !request.uri.path.contains('real-package')) {
        response.statusCode = HttpStatus.found;
        response.headers.set('location', redirectFirstTo!);
        await response.close();
        return;
      }
      if (forceStatus != null) {
        response.statusCode = forceStatus!;
        await response.close();
        return;
      }
      if (failFirst416 && request.headers.value('range') != null) {
        failFirst416 = false;
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set('content-range', 'bytes */${body.length}');
        await response.close();
        return;
      }

      final range = request.headers.value('range');
      final ifRange = request.headers.value('if-range');
      if (supportRange &&
          range != null &&
          (ifRange == null || ifRange == etag)) {
        final match = RegExp(r'bytes=(\d+)-').firstMatch(range);
        final start = match == null ? 0 : int.parse(match.group(1)!);
        if (start >= body.length) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('content-range', 'bytes */${body.length}');
          await response.close();
          return;
        }
        response.statusCode = HttpStatus.partialContent;
        response.headers.set('etag', etag);
        response.headers.set(
          'content-range',
          'bytes $start-${body.length - 1}/${body.length}',
        );
        response.add(Uint8List.fromList(body.sublist(start)));
      } else {
        response.statusCode = HttpStatus.ok;
        response.headers.set('etag', etag);
        response.add(Uint8List.fromList(body));
      }
      await response.close();
    } on Object {
      // 客户端取消会让写入失败，测试不关心。
    }
  }
}

