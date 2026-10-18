// 更新缓存根（实施计划 §9.2）。
//
// **为什么不能直接用 `%LOCALAPPDATA%`**：已安装的 MSIX 会把这套环境变量指向的目录重定向到
// `...\Packages\<PackageFamilyName>\LocalCache\Local\...`，其中的文件可能被标记为
// `Application Protected`。更新器把完整且哈希正确的 `.partial` 提升为 `.ready`、以及替换
// `state.json` 时都会被拒绝（`UPDATE_DOWNLOAD_PERMISSION_DENIED` /
// `UPDATE_STATE_WRITE_FAILED`）。正确的位置是 `ApplicationData.Current.LocalCacheFolder`。
//
// 规则（不可静默回退）：
//   · 已打包：原生返回绝对路径，追加一次 `BestPlanning\Updates`；
//   · 无包身份（便携版 / 纯 Dart 测试）：才允许回退到 `%LOCALAPPDATA%`，且必须标注来源；
//   · 已打包但原生失败：抛 [UpdateStorageException]，**不回退**。
import 'dart:io';

import 'package:flutter/services.dart';

const String updateStorageChannelName = 'personal_planner/update_storage';

/// 原生通道给出的稳定错误码。
abstract final class UpdateStorageErrorCode {
  /// 进程没有包身份：便携版或纯 Dart 测试。
  static const String unpackaged = 'UPDATE_STORAGE_UNPACKAGED';

  /// 有包身份，但拿不到缓存目录（附带 HRESULT）。
  static const String failed = 'UPDATE_STORAGE_FAILED';
}

final class UpdateStorageException implements Exception {
  const UpdateStorageException(this.code, this.message, {this.hresult});

  final String code;
  final String message;

  /// 原生 HRESULT；日志里写成十六进制，界面只显示稳定文案。
  final int? hresult;

  String get diagnostic => hresult == null
      ? '$code: $message'
      : '$code: $message '
            '(0x${hresult!.toUnsigned(32).toRadixString(16)})';

  @override
  String toString() => diagnostic;
}

final class ResolvedUpdateRoot {
  const ResolvedUpdateRoot({
    required this.path,
    required this.source,
    required this.reason,
  });

  /// 已经追加过一次 `BestPlanning\Updates` 的绝对路径。
  final String path;

  /// `local-cache` 或 `unpackaged-fallback`。
  final String source;

  /// 回退原因：`unpackaged` / `no-native-channel` / `non-windows`；正常路径为空。
  final String reason;

  bool get usedUnpackagedFallback => source == 'unpackaged-fallback';
}

final class WindowsUpdateStorage {
  WindowsUpdateStorage({
    MethodChannel? channel,
    Map<String, String>? environment,
    bool? isWindows,
    this.productDirectory = 'BestPlanning',
  }) : _channel = channel ?? const MethodChannel(updateStorageChannelName),
       _environment = environment ?? Platform.environment,
       _isWindows = isWindows ?? Platform.isWindows;

  final MethodChannel _channel;
  final Map<String, String> _environment;
  final bool _isWindows;
  final String productDirectory;

  Future<ResolvedUpdateRoot> resolveRoot() async {
    if (!_isWindows) {
      return _fallback('non-windows');
    }

    final String? cacheRoot;
    try {
      cacheRoot = await _channel.invokeMethod<String>('getLocalCacheRoot');
    } on MissingPluginException {
      // 纯 Dart 测试或没有 runner 的宿主：没有原生通道可问，按未打包处理并如实标注。
      return _fallback('no-native-channel');
    } on PlatformException catch (error) {
      if (error.code == UpdateStorageErrorCode.unpackaged) {
        return _fallback('unpackaged');
      }
      final details = error.details;
      throw UpdateStorageException(
        error.code,
        error.message ?? 'getLocalCacheRoot failed',
        hresult: details is int ? details : null,
      );
    }

    if (cacheRoot == null || cacheRoot.trim().isEmpty) {
      throw const UpdateStorageException(
        UpdateStorageErrorCode.failed,
        'getLocalCacheRoot returned an empty path',
      );
    }
    return ResolvedUpdateRoot(
      path: [
        cacheRoot,
        productDirectory,
        'Updates',
      ].join(Platform.pathSeparator),
      source: 'local-cache',
      reason: '',
    );
  }

  ResolvedUpdateRoot _fallback(String reason) {
    final base =
        _environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return ResolvedUpdateRoot(
      path: [base, productDirectory, 'Updates'].join(Platform.pathSeparator),
      source: 'unpackaged-fallback',
      reason: reason,
    );
  }
}
