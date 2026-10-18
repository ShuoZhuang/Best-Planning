// 后台下载器：断点续传、重定向限制、哈希与大小校验（规格 §8 / UPD-010～UPD-014）。
//
// 设计上的三条硬规则：
//   1. 未完成文件永远是 `.partial`，只有"长度与全文件 SHA-256 都对"才原子改名为 `.ready`；
//   2. 服务器不认续传（`200`）时**清空旧分段重下**，绝不把旧字节接在新响应后面；
//   3. 任何失败都保留 `.partial`（除非哈希不符或大小超出），下一次可以接着下。
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/update_network_policy.dart';

const String updatePackageRequestUserAgent =
    'PersonalPlanner-NativeUpdater (+https://github.com/ShuoZhuang/Best-Planning)';

final class ResumablePackageDownloader implements UpdatePackageDownloader {
  ResumablePackageDownloader({
    http.Client? client,
    this.timeout = const Duration(seconds: 60),
    this.maxRedirects = updateMaxRedirects,
    bool Function(Uri)? isAllowedInitial,
    bool Function(Uri)? isAllowedRedirect,
  }) : _client = client ?? http.Client(),
       _isAllowedInitial = isAllowedInitial ?? UpdateNetworkPolicy.isAllowedPackageUri,
       _isAllowedRedirect = isAllowedRedirect ?? UpdateNetworkPolicy.isAllowedRedirect;

  final http.Client _client;
  final Duration timeout;
  final int maxRedirects;
  final bool Function(Uri) _isAllowedInitial;
  final bool Function(Uri) _isAllowedRedirect;

  @override
  Future<DownloadOutcome> download({
    required UpdateTarget target,
    required String partialPath,
    required String readyPath,
    String? etag,
    String? lastModified,
    required bool Function() shouldCancel,
    required void Function(int receivedBytes, int? totalBytes) onProgress,
  }) async {
    final partial = File(partialPath);
    final ready = File(readyPath);
    try {
      await partial.parent.create(recursive: true);
    } on FileSystemException {
      return const DownloadOutcome.failed(
        UpdateFailure(UpdateFailureCode.downloadPermissionDenied),
      );
    }

    var existing = await _lengthOrZero(partial);
    if (existing > target.sizeBytes) {
      await _deleteQuietly(partial);
      existing = 0;
    }

    var current = target.downloadUri;
    var redirects = 0;
    var followedRedirect = false;
    var retriedWithoutRange = false;
    final validator = (etag != null && etag.isNotEmpty)
        ? etag
        : (lastModified != null && lastModified.isNotEmpty ? lastModified : null);

    while (true) {
      if (!followedRedirect && !_isAllowedInitial(current)) {
        return DownloadOutcome.failed(
          UpdateFailure(
            UpdateFailureCode.manifestSourceNotAllowed,
            detail: current.host,
          ),
        );
      }

      final http.StreamedResponse response;
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['Accept'] = 'application/octet-stream'
          ..headers['User-Agent'] = updatePackageRequestUserAgent;
        if (existing > 0) {
          request.headers['Range'] = 'bytes=$existing-';
          if (validator != null) request.headers['If-Range'] = validator;
        }
        response = await _client.send(request).timeout(timeout);
      } on TimeoutException {
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkTimeout),
        );
      } on HandshakeException {
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkTlsFailed),
        );
      } on SocketException {
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkOffline),
        );
      } on http.ClientException {
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkOffline),
        );
      } on FileSystemException {
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.downloadPermissionDenied),
        );
      } on Object {
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.internalError),
        );
      }

      final status = response.statusCode;
      if (_isRedirect(status)) {
        final next = UpdateNetworkPolicy.resolveLocation(
          current,
          response.headers['location'],
        );
        if (next == null || !_isAllowedRedirect(next)) {
          await _drain(response);
          return DownloadOutcome.failed(
            UpdateFailure(
              UpdateFailureCode.manifestSourceNotAllowed,
              detail: 'redirect=${next ?? 'invalid'}',
            ),
          );
        }
        redirects++;
        if (redirects > maxRedirects) {
          await _drain(response);
          return DownloadOutcome.failed(
            UpdateFailure(
              UpdateFailureCode.manifestSourceNotAllowed,
              detail: 'redirects=$redirects',
            ),
          );
        }
        await _drain(response);
        current = next;
        followedRedirect = true;
        continue;
      }

      if (status == 416) {
        await _drain(response);
        // 本地文件可能已经完整（上一次下完但没来得及改名）。先判长度+哈希，再决定重下。
        if (existing == target.sizeBytes) {
          final digest = await _sha256(partial);
          if (digest == target.sha256) {
            return _finalize(
              partial: partial,
              ready: ready,
              target: target,
              etag: etag,
              lastModified: lastModified,
            );
          }
        }
        await _deleteQuietly(partial);
        existing = 0;
        if (retriedWithoutRange) {
          return const DownloadOutcome.failed(
            UpdateFailure(UpdateFailureCode.downloadRangeRejected),
          );
        }
        retriedWithoutRange = true;
        continue;
      }

      if (status != 200 && status != 206) {
        await _drain(response);
        return DownloadOutcome.failed(
          UpdateFailure(
            UpdateFailureCode.networkHttpFailed,
            detail: 'HTTP $status',
          ),
        );
      }

      if (status == 206) {
        final contentRange = response.headers['content-range'];
        final start = _contentRangeStart(contentRange);
        if (start != existing) {
          await _drain(response);
          await _deleteQuietly(partial);
          return DownloadOutcome.failed(
            UpdateFailure(
              UpdateFailureCode.downloadRangeRejected,
              detail: 'content-range=$contentRange expected=$existing',
            ),
          );
        }
      }

      // 200 表示服务器忽略了 Range（或本来就没有分段）：必须清空旧文件，
      // 否则旧字节会和新响应的开头拼在一起——那是一个"大小对、哈希错"的包。
      var mode = FileMode.write;
      if (status == 206 && existing > 0) {
        mode = FileMode.append;
      } else {
        existing = 0;
      }

      RandomAccessFile? handle;
      try {
        handle = await partial.open(mode: mode);
        var received = existing;
        final total = target.sizeBytes;
        onProgress(received, total);
        await for (final chunk in response.stream.timeout(timeout)) {
          if (shouldCancel()) {
            await handle.close();
            return const DownloadOutcome.cancelled();
          }
          await handle.writeFrom(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await handle.flush();
        await handle.close();
        handle = null;
        if (received > total) {
          await _deleteQuietly(partial);
          return DownloadOutcome.failed(
            UpdateFailure(
              UpdateFailureCode.downloadSizeMismatch,
              detail: 'received=$received expected=$total',
            ),
          );
        }
      } on TimeoutException {
        await handle?.close();
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkTimeout),
        );
      } on SocketException {
        await handle?.close();
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkOffline),
        );
      } on http.ClientException {
        await handle?.close();
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.networkOffline),
        );
      } on FileSystemException {
        await handle?.close();
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.downloadPermissionDenied),
        );
      } on Object {
        await handle?.close();
        return const DownloadOutcome.failed(
          UpdateFailure(UpdateFailureCode.internalError),
        );
      }

      final length = await _lengthOrZero(partial);
      if (length != target.sizeBytes) {
        return DownloadOutcome.failed(
          UpdateFailure(
            UpdateFailureCode.downloadSizeMismatch,
            detail: 'size=$length expected=${target.sizeBytes}',
          ),
        );
      }

      final digest = await _sha256(partial);
      if (digest != target.sha256) {
        // 哈希不符的包**不能**留在磁盘上冒充"可续传分段"。
        await _deleteQuietly(partial);
        return DownloadOutcome.failed(
          UpdateFailure(
            UpdateFailureCode.downloadHashMismatch,
            detail: 'sha256=$digest',
          ),
        );
      }

      return _finalize(
        partial: partial,
        ready: ready,
        target: target,
        etag: response.headers['etag'] ?? etag,
        lastModified: response.headers['last-modified'] ?? lastModified,
      );
    }
  }

  Future<DownloadOutcome> _finalize({
    required File partial,
    required File ready,
    required UpdateTarget target,
    String? etag,
    String? lastModified,
  }) async {
    try {
      await ready.parent.create(recursive: true);
      if (await ready.exists()) await ready.delete();
      await partial.rename(ready.path);
    } on FileSystemException {
      return const DownloadOutcome.failed(
        UpdateFailure(UpdateFailureCode.downloadPermissionDenied),
      );
    }
    return DownloadOutcome.success(
      path: ready.path,
      sizeBytes: target.sizeBytes,
      sha256: target.sha256,
      etag: etag,
      lastModified: lastModified,
    );
  }

  Future<int> _lengthOrZero(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } on FileSystemException {
      return 0;
    }
  }

  Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // 删除失败不影响"这次下载失败"这个结论；下一次会按 200 重下。
    }
  }

  Future<void> _drain(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>().timeout(timeout);
    } on Object {
      // 连接本来就要关闭。
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  /// 解析 `Content-Range: bytes start-end/total` 里的 start；格式不对返回 `null`。
  static int? _contentRangeStart(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(value.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// 释放内部创建的 HTTP 客户端。
  void close() => _client.close();
}


