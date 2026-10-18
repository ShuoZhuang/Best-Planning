// 原生更新助手的 Dart 侧（规格 §12）。
//
// Dart 不直接调用 WinRT/COM：包身份、签名验证与 MSIX 部署都在 `windows/update_helper` 里。
// 这个文件只负责三件事：找到助手、用 `--probe`/`--verify` 询问事实、把一次性请求写成文件
// 并等待助手握手。
//
// **握手是安全边界**：助手没有确认取得请求之前，主程序不得退出（§12.3 第 8～9 步）。
//
// **部署时必须从包外运行助手**：助手默认位于已安装包内（`WindowsApps`），直接从那里启动
// 会让它自己占住包文件，Windows 随即以 `ERROR_PACKAGES_IN_USE (0x80073D02)` 拒绝原位升级
// （2026-10-18 在真实 1.9.1 → 1.9.2 的应用内更新中复现）。因此 `launch` 先把它复制到
// 临时目录再启动；复制失败按启动失败处理，不会退回包内路径。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';

final class WindowsUpdateHelper implements UpdateHelper {
  WindowsUpdateHelper({
    required this.layout,
    String? helperPath,
    this.handshakeTimeout = const Duration(seconds: 15),
    DateTime Function()? nowUtc,
  }) : helperPath = helperPath ??
            Platform.environment['BEST_PLANNING_UPDATE_HELPER'] ??
            _defaultHelperPath(),
       _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final UpdateStorageLayout layout;
  final String helperPath;
  final Duration handshakeTimeout;
  final DateTime Function() _nowUtc;
  String? _stagedHelper;

  /// 把助手复制到包外的临时目录，返回可执行路径。
  ///
  /// 同一个实例只复制一次；复制失败会抛出异常（调用方按启动失败处理），
  /// **不会**退回包内路径，否则部署必然被 Windows 以“包正在使用”拒绝。
  Future<String> stageHelperForLaunch() async {
    final cached = _stagedHelper;
    if (cached != null && File(cached).existsSync()) return cached;
    final source = File(helperPath);
    if (!await source.exists()) return helperPath;
    final parent = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}BestPlanningUpdateHelper',
    );
    await parent.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final directory = Directory(
      '${parent.path}${Platform.pathSeparator}$pid-$stamp',
    );
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}update_helper.exe',
    );
    await source.copy(target.path);
    if (await target.length() != await source.length()) {
      throw const FileSystemException('helper copy size mismatch');
    }
    _stagedHelper = target.path;
    unawaited(_pruneStagedHelpers(parent, except: directory.path));
    return target.path;
  }

  Future<void> _pruneStagedHelpers(
    Directory parent, {
    required String except,
  }) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final entry in parent.list()) {
        if (entry is! Directory || entry.path == except) continue;
        try {
          if ((await entry.stat()).modified.isBefore(cutoff)) {
            await entry.delete(recursive: true);
          }
        } on Object {
          // 清理失败不影响本次更新。
        }
      }
    } on Object {
      // 目录不存在或被占用时忽略。
    }
  }

  static String _defaultHelperPath() {
    final executable = Platform.resolvedExecutable;
    final separator = executable.lastIndexOf(Platform.pathSeparator);
    final directory = separator <= 0
        ? Directory.current.path
        : executable.substring(0, separator);
    return '$directory${Platform.pathSeparator}update_helper.exe';
  }

  bool get exists => File(helperPath).existsSync();

  @override
  Future<HelperProbe?> probe() async {
    if (!exists) return null;
    final result = await _run(['--probe']);
    if (result == null) return null;
    try {
      final json = jsonDecode(result) as Map<String, Object?>;
      final version = json['helperVersion'];
      final protocol = json['protocolVersion'];
      if (version is! String || protocol is! int) return null;
      final packageJson = json['installedPackage'];
      return HelperProbe(
        helperVersion: version,
        protocolVersion: protocol,
        installedPackage: packageJson is Map
            ? _parseInstalledPackage(packageJson.cast<String, Object?>())
            : null,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<PackageVerification> verifyPackage({required String path}) async {
    if (!exists) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.helperMissing),
      );
    }
    final result = await _run(['--verify', path]);
    if (result == null) {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.helperLaunchFailed),
      );
    }
    try {
      final json = jsonDecode(result) as Map<String, Object?>;
      if (json['ok'] == true) {
        final identity = json['identity'] is Map
            ? _parseInstalledPackage(
                (json['identity']! as Map).cast<String, Object?>(),
              )
            : null;
        return PackageVerification.valid(
          path: path,
          sizeBytes: json['sizeBytes'] is int ? json['sizeBytes'] as int : 0,
          sha256: json['sha256'] is String ? json['sha256'] as String : '',
          identity: identity,
          nativeSignatureVerified: true,
        );
      }
      final code = UpdateFailureCode.fromCode(json['failureCode'] as String?);
      return PackageVerification.invalid(
        UpdateFailure(code ?? UpdateFailureCode.packageSignatureInvalid),
      );
    } on Object {
      return const PackageVerification.invalid(
        UpdateFailure(UpdateFailureCode.packageSignatureInvalid),
      );
    }
  }

  @override
  Future<HelperLaunchResult> launch(UpdateHelperRequest request) async {
    if (!exists) {
      return const HelperLaunchResult.failed(
        UpdateFailure(UpdateFailureCode.helperMissing),
      );
    }
    final requestFile = layout.requestFile(request.toVersion);
    final statusFile = layout.helperStatusFile(request.toVersion);
    try {
      // 清掉上一次的状态，避免把旧事务的握手当成这一次的。
      if (await statusFile.exists()) await statusFile.delete();
      await writeJsonAtomically(requestFile, request.toJson());
      // 必须从包外启动，否则助手自己会把安装包锁住（0x80073D02）。
      final launchPath = await stageHelperForLaunch();
      final process = await Process.start(
        launchPath,
        ['--apply', requestFile.path],
        mode: ProcessStartMode.detached,
      );
      // 助手会立即读取请求并写入 helper-status.json；等待它写下本次事务号。
      final deadline = _nowUtc().add(handshakeTimeout);
      while (_nowUtc().isBefore(deadline)) {
        final status = await readJsonOrNull(statusFile);
        if (status is Map &&
            status['transactionId'] == request.transactionId &&
            status['state'] is String) {
          return const HelperLaunchResult.started();
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      // 助手进程仍应继续运行；握手超时只说明主程序看不到状态，
      // 因此按失败处理并保留进程（用户可重试）。
      unawaited(process.exitCode.then((_) {}));
      return const HelperLaunchResult.handshakeFailed(
        'UPDATE_HELPER_LAUNCH_FAILED',
      );
    } on Object {
      return const HelperLaunchResult.failed(
        UpdateFailure(UpdateFailureCode.helperLaunchFailed),
      );
    }
  }

  Future<String?> _run(List<String> arguments) async {
    try {
      final result = await Process.run(
        helperPath,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) return null;
      final output = result.stdout;
      return output is String ? output.trim() : null;
    } on Object {
      return null;
    }
  }

  InstalledPackage? _parseInstalledPackage(Map<String, Object?> json) {
    final identity = json['identityName'] ?? json['packageIdentityName'];
    final publisher = json['publisher'];
    final family = json['familyName'] ?? json['packageFamilyName'];
    final architecture = PackageArchitecture.tryParse(
      json['architecture'] as String?,
    );
    final version = MsixVersion.tryParse(json['version'] as String?);
    if (identity is! String ||
        publisher is! String ||
        family is! String ||
        architecture == null ||
        version == null) {
      return null;
    }
    return InstalledPackage(
      identityName: identity,
      publisher: publisher,
      familyName: family,
      architecture: architecture,
      version: version,
      isPackaged: json['isPackaged'] != false,
    );
  }
}
