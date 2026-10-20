// 已安装 MSIX 内的更新落盘自检（实施计划 §9.6）。
//
// 这个文件**只服务验收**：安装器与正式运行路径都不调用它。它存在的理由是不能用"源码运行"
// 代替真实安装态——包身份会把 `%LOCALAPPDATA%` 重定向到受保护目录，只有真正以包身份跑的
// 进程才能证明 `state.json`、`.partial`、`.ready` 都在 `LocalCacheFolder` 下写入成功。
//
// 用法：给已安装的进程设置环境变量 `PLANNER_UPDATE_STORAGE_SELFTEST=<报告路径>`，
// 进程启动后会跑完自检、写 JSON 报告并退出（0=通过，1=失败），不启动界面。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';
import 'package:personal_planner/infrastructure/update/file_update_state_store.dart';
import 'package:personal_planner/infrastructure/update/update_storage_layout.dart';
import 'package:personal_planner/platform/update/windows_update_storage.dart';

const String updateStorageSelfTestEnvironmentKey =
    'PLANNER_UPDATE_STORAGE_SELFTEST';

/// 自检专用版本号：`1.10.0.99` 不会出现在任何真实发布里，避免与真实目标目录冲突。
const MsixVersion _selfTestVersion = MsixVersion(1, 10, 0, 99);

/// 在**当前进程的包身份**下跑一遍真实落盘链路；返回报告并写入 [reportPath]。
Future<Map<String, Object?>> runUpdateStorageSelfTest({
  required ResolvedUpdateRoot root,
  String? reportPath,
  bool requireLocalCache = true,
}) async {
  final layout = UpdateStorageLayout.fromResolvedRoot(root.path);
  final report = <String, Object?>{
    'ok': false,
    'source': root.source,
    'reason': root.reason,
    'root': root.path,
    'stateFile': layout.stateFile.path,
    'processId': pid,
  };
  final body = List<int>.generate(4096, (index) => (index * 7) % 251);
  final digest = sha256.convert(body).toString();
  final target = UpdateTarget(
    version: const SemVer(1, 10, 0),
    buildNumber: 47,
    tag: 'v1.10.0',
    msixVersion: _selfTestVersion,
    fileName: 'update-storage-selftest.msix',
    downloadUrl: 'https://example.invalid/update-storage-selftest.msix',
    sizeBytes: body.length,
    sha256: digest,
    manifestDigest: 'a' * 64,
    keyId: 'selftest',
  );
  final partial = layout.partialPackage(target);
  final ready = layout.readyPackage(target);
  try {
    final store = FileUpdateStateStore(file: layout.stateFile);
    await store.save(const UpdateState(phase: UpdatePhase.updateAvailable));
    // 覆盖写：第二次必须替换第一次的内容，而不是留下半份 JSON。
    await store.save(
      const UpdateState(phase: UpdatePhase.ready, receivedBytes: 4096),
    );
    report['stateWrite'] = 'ok';
    report['statePhase'] = (await store.load()).phase.name;

    await partial.parent.create(recursive: true);
    if (await ready.exists()) await ready.delete();
    await partial.writeAsBytes(body);
    await promoteVerifiedFile(partial, ready);
    report['promote'] = 'ok';
    report['readyPath'] = ready.path;
    report['readyBytes'] = await ready.length();
    report['readySha256'] = sha256
        .convert(await ready.readAsBytes())
        .toString();
    report['partialExists'] = await partial.exists();

    // "重启"后仍能读回：重新构造存储，只有真实落盘才可能成立。
    final reopened = FileUpdateStateStore(file: layout.stateFile);
    report['reopenedPhase'] = (await reopened.load()).phase.name;
    report['insideLocalCache'] = root.source == 'local-cache';
    report['ok'] =
        report['readySha256'] == digest &&
        report['readyBytes'] == body.length &&
        report['partialExists'] == false &&
        report['reopenedPhase'] == UpdatePhase.ready.name &&
        (!requireLocalCache || root.source == 'local-cache');
  } on Object catch (error) {
    report['error'] = error.toString();
    report['ok'] = false;
  } finally {
    // 自检产物不留在用户的更新目录里。
    for (final file in [ready, partial, layout.stateFile]) {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // 清理失败不影响自检结论。
      }
    }
  }
  if (reportPath != null && reportPath.isNotEmpty) {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  }
  return report;
}

/// 启动入口：解析根 → 自检 → 写报告 → 返回退出码。
Future<int> runPackagedUpdateStorageSelfTest(String reportPath) async {
  try {
    final root = await WindowsUpdateStorage().resolveRoot();
    final report = await runUpdateStorageSelfTest(
      root: root,
      reportPath: reportPath,
    );
    return report['ok'] == true ? 0 : 1;
  } on UpdateStorageException catch (error) {
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'ok': false,
        'error': error.diagnostic,
        'processId': pid,
      }),
    );
    return 1;
  }
}
