// 已安装 MSIX 的更新落盘回归（实施计划 §9.6）。
//
// **它能证明什么**：在 `flutter test`（源码、无包身份）下，它证明"未打包时走明确标注的
// 回退，而不是静默使用被重定向的 `%LOCALAPPDATA%`"，并跑通 `state.json` 覆盖写与
// `.partial → .ready` 提升。
//
// **它不能证明什么**：包身份下的 `LocalCacheFolder` 路径与 ACL。那一条必须由**已安装的**
// 应用进程执行；本仓库用 `lib/platform/update/update_storage_selftest.dart` 在安装态跑同一
// 套代码，证据写在 `docs/testing/v1.10.0-packaged-update-storage-acceptance.md`。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/update/update_storage_selftest.dart';
import 'package:personal_planner/platform/update/windows_update_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('更新落盘链路：状态覆盖写、包提升、重启后可读', (tester) async {
    final root = await WindowsUpdateStorage().resolveRoot();
    // 回退必须是显式的：来源与原因都要能写进日志。
    if (root.usedUnpackagedFallback) {
      expect(root.source, 'unpackaged-fallback');
      expect(root.reason, isNotEmpty);
      // ignore: avoid_print
      print(
        'SKIP packaged assertions: unpackaged fallback '
        '(${root.reason}); root=${root.path}',
      );
    }

    final report = await runUpdateStorageSelfTest(
      root: root,
      requireLocalCache: false,
    );

    expect(report['ok'], isTrue, reason: '${report['error']}');
    expect(report['stateWrite'], 'ok');
    expect(report['promote'], 'ok');
    expect(report['reopenedPhase'], 'ready');
    expect(report['partialExists'], isFalse);
    if (!root.usedUnpackagedFallback) {
      expect(root.source, 'local-cache');
    }
  });
}
