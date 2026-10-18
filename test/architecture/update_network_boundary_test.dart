// 联网边界（2026-10-18 原生自更新规格 §7.6 / UPD-001 / UPD-008 / UPD-048）。
//
// 旧实现（GitHub Releases API + 打开网页）已被删除。这一条门禁现在守的是新链路：
//   · 整个 `lib/` 只有三个文件 import 网络包：清单仓库、下载器、外链适配器；
//   · 不调用任何 Releases API；清单地址是固定的两个 HTTPS 路径；
//   · 不发送 cookie/授权头/本地版本号；
//   · 重定向白名单、Range 续传与 304 条件请求的关键字确实存在（防止有人"简化"掉它们）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许 import 网络包的文件。每个只做一件事：
///   · 清单仓库：读取固定地址的签名清单；
///   · 下载器：下载 MSIX（Range/If-Range）；
///   · 外链适配器：只把已验证的 Release 页面交给系统浏览器。
const _allowedNetworkFiles = <String>{
  'lib/infrastructure/update/http_update_manifest_repository.dart',
  'lib/infrastructure/update/resumable_package_downloader.dart',
  'lib/platform/update/url_launcher_adapter.dart',
};

/// 旧实现的三个文件。它们必须**不存在**（UPD-048）。
const _deletedLegacyFiles = <String>[
  'lib/platform/update/github_release_client.dart',
  'lib/application/update_service.dart',
  'lib/domain/models/app_update.dart',
];

List<File> _dartSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .where((file) => !file.path.endsWith('.g.dart'))
    .toList();

String _normalized(File file) => file.path.replaceAll(r'\', '/');

String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final index = line.indexOf('//');
      return index < 0 ? line : line.substring(0, index);
    })
    .join('\n');

void main() {
  test('lib/ 里只有被批准的三个文件 import 网络包', () {
    final files = _dartSources();
    expect(files.length, greaterThan(50), reason: '扫描路径可能失效');

    final offenders = <String>[];
    final seen = <String>{};
    for (final file in files) {
      final path = _normalized(file);
      final importsNetwork = file.readAsLinesSync().any(
        (line) =>
            line.startsWith('import ') &&
            (line.contains('package:http/') ||
                line.contains('package:url_launcher/')),
      );
      if (!importsNetwork) continue;
      if (_allowedNetworkFiles.contains(path)) {
        seen.add(path);
        continue;
      }
      offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件也 import 了网络包：$offenders。新链路只有三个出网相关的文件'
          '（${_allowedNetworkFiles.join('、')}）。',
    );
    expect(
      seen,
      containsAll(_allowedNetworkFiles),
      reason: '允许名单失效：只看到 $seen',
    );
  });

  test('不再调用 GitHub Releases API（UPD-001）', () {
    for (final file in _dartSources()) {
      final code = _stripLineComments(file.readAsStringSync());
      expect(
        code.contains('api.github.com'),
        isFalse,
        reason: '${_normalized(file)} 仍在调用 Releases API',
      );
      expect(
        code.contains('releases?per_page'),
        isFalse,
        reason: '${_normalized(file)} 仍在构造 Releases 列表请求',
      );
    }
  });

  test('旧更新实现已删除（UPD-048）', () {
    for (final path in _deletedLegacyFiles) {
      expect(
        File(path).existsSync(),
        isFalse,
        reason: '$path 应当被删除；两套更新逻辑不得并存',
      );
    }
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('GithubReleaseClient')));
    expect(main, isNot(contains('UpdateService(')));
  });

  test('清单地址固定为两个 HTTPS 路径，可执行代码里没有明文 HTTP', () {
    final manifest = File(
      'lib/domain/update/update_manifest.dart',
    ).readAsStringSync();
    expect(
      manifest,
      contains(
        'https://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json',
      ),
    );
    expect(manifest, contains("isScheme('https')"));

    for (final path in _allowedNetworkFiles) {
      final code = _stripLineComments(File(path).readAsStringSync());
      expect(
        code.contains("'http://"),
        isFalse,
        reason: '$path 出现明文 HTTP',
      );
    }
  });

  test('出网口不发送 cookie、授权头或本地版本号', () {
    for (final path in _allowedNetworkFiles) {
      final code = _stripLineComments(File(path).readAsStringSync());
      for (final forbidden in const ['cookie', 'Cookie', 'Authorization', 'Bearer']) {
        expect(
          code.contains(forbidden),
          isFalse,
          reason: '$path 不该出现 $forbidden',
        );
      }
      expect(code.contains(r'?version='), isFalse);
    }
  });

  test('条件请求与断点续传的关键头仍然存在', () {
    final repository = File(
      'lib/infrastructure/update/http_update_manifest_repository.dart',
    ).readAsStringSync();
    expect(repository, contains('If-None-Match'));
    expect(repository, contains('status == 304'));
    expect(repository, contains('followRedirects = false'));
    expect(repository, contains('updateMaxRedirects'));

    final downloader = File(
      'lib/infrastructure/update/resumable_package_downloader.dart',
    ).readAsStringSync();
    expect(downloader, contains("headers['Range']"));
    expect(downloader, contains('If-Range'));
    expect(downloader, contains('416'));
    expect(downloader, contains('FileMode.append'));
    expect(downloader, contains('sha256'));
  });

  test('外链只交给系统浏览器，不在应用内下载或启动安装程序', () {
    final launcher = File(
      'lib/platform/update/url_launcher_adapter.dart',
    ).readAsStringSync();
    expect(launcher, contains('LaunchMode.externalApplication'));
    for (final forbidden in const ['download', 'HttpClient', 'Process.start']) {
      expect(
        launcher.contains(forbidden),
        isFalse,
        reason: '外链适配器里不该出现 $forbidden',
      );
    }
  });

  test('原生更新助手不调用 PowerShell、批处理或远端下载（§12.4）', () {
    final helper = Directory('windows/update_helper');
    if (!helper.existsSync()) return;
    final sources = helper
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.cpp') ||
              file.path.endsWith('.h') ||
              file.path.endsWith('.hpp'),
        );
    for (final file in sources) {
      final code = file.readAsStringSync().toLowerCase();
      for (final forbidden in const [
        'powershell',
        'cmd.exe',
        'invoke-expression',
        'winhttp',
        'wininet',
        'urlmon',
      ]) {
        expect(
          code.contains(forbidden),
          isFalse,
          reason: '${file.path} 出现 $forbidden：助手不得执行命令或联网',
        );
      }
    }
  });

  test('自动下载不按网络类型分支（UPD-009）', () {
    final directories = [
      Directory('lib/application/update'),
      Directory('lib/infrastructure/update'),
    ];
    final hits = <String>[];
    var scanned = 0;
    for (final directory in directories) {
      if (!directory.existsSync()) continue;
      for (final file in directory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))) {
        scanned++;
        final code = _stripLineComments(file.readAsStringSync());
        for (final forbidden in const [
          'connectivity_plus',
          'NetworkType',
          'metered',
          'isWifi',
          'cellular',
        ]) {
          if (code.contains(forbidden)) {
            hits.add('${_normalized(file)} 含 $forbidden');
          }
        }
      }
    }
    expect(scanned, greaterThan(10), reason: '扫描路径可能失效');
    expect(
      hits,
      isEmpty,
      reason: '自动更新不应按 Wi-Fi/计费网络分支（规格 §7.3）：$hits',
    );
  });
}
