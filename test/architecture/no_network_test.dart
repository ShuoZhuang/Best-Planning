// 隐私门禁：这个应用**不上传任何东西**（需求 §14.4 与手工清单 9.7）。
//
// 为什么把它写成测试而不是留在手工清单里：手工清单要求"检查网络行为：无上传、无广告追踪、
// 不依赖在线服务"，而那条**只能由人点一遍、且只能证明当时那一刻**——以后任何一次依赖变更或
// 顺手 import 都可能悄悄把数据送出去，而没人会重跑那条手工项。这里把它变成一条**会失败的**
// 测试：只要有人引入网络依赖或在 `lib/` 里发起网络调用，它立刻红。
//
// **它检查两件事，缺一不可**：
//   1. `pubspec.yaml` 的直接依赖里没有网络／分析类包；
//   2. `lib/` 的源码里没有网络调用（`HttpClient`／`Socket`／`WebSocket`／`HttpServer`／
//      `InternetAddress`）与网络包的 import。
//
// **刻意不做的事**：不禁止 `dart:io` 本身——`File`／`Directory`／`Platform` 是本地存储与
// 平台判断所必需的，一刀切会让这条门禁变成噪音，最后被人加 ignore 绕过去。
//
// **防"空跑即通过"**：本文件开头先断言"确实读到了东西"（依赖数与源码文件数），否则目录换了、
// 路径变了都会让扫描一无所获，而那样测试**照样是绿的**——那正是"不会失败的测试比没有测试更糟"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 网络／遥测类包名。出现任何一个即失败。
///
/// 用**基名匹配**而不是精确相等：像 `firebase_core`／`firebase_analytics` 这类会带后缀，
/// 精确匹配会漏掉。同时把常见的几种"间接上网"也算进来（web socket、gRPC、各家分析 SDK）。
const _forbiddenPackages = <String>[
  'http',
  'dio',
  'chopper',
  'retrofit',
  'web_socket_channel',
  'grpc',
  'googleapis',
  'googleapis_auth',
  'firebase',
  'sentry',
  'posthog',
  'amplitude',
  'mixpanel',
  'segment',
  'appsflyer',
  'adjust',
];

/// `lib/` 里出现即失败的网络调用符号。
const _forbiddenSymbols = <String>[
  'HttpClient(',
  'HttpServer.bind',
  'Socket.connect',
  'SecureSocket.connect',
  'WebSocket.connect',
  'InternetAddress.lookup',
  'RawDatagramSocket.bind',
  'package:http/',
  'package:dio/',
  'package:web_socket_channel/',
  'package:grpc/',
];

/// 不允许出现网络符号的目录：生产代码。
const _scannedDirectory = 'lib';

void main() {
  test('pubspec 的直接依赖里没有网络或分析类包', () {
    final pubspec = File('pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: '读不到 pubspec.yaml——测试的工作目录应当就是包根目录',
    );
    final lines = pubspec.readAsLinesSync();

    // 只扫 dependencies / dev_dependencies 段里的 `名字:` 行，避免把注释里的 URL 当依赖。
    final declared = <String>[];
    var inDependencies = false;
    for (final line in lines) {
      if (RegExp(r'^\S').hasMatch(line)) {
        inDependencies =
            line.startsWith('dependencies:') ||
            line.startsWith('dev_dependencies:');
        continue;
      }
      if (!inDependencies) continue;
      final match = RegExp(r'^\s{2}([A-Za-z0-9_]+):').firstMatch(line);
      if (match != null) declared.add(match.group(1)!);
    }

    // **防空跑**：解析逻辑一旦写错（比如缩进改了），`declared` 会是空表，下面那条断言就
    // 永远通过。因此先钉住"确实解析出了已知依赖"。
    expect(
      declared,
      contains('drift'),
      reason: '依赖解析没有生效（连已知的 drift 都没解析出来），这条门禁会变成空跑',
    );

    final offending = [
      for (final name in declared)
        for (final banned in _forbiddenPackages)
          if (name == banned || name.startsWith('${banned}_')) name,
    ];
    expect(
      offending,
      isEmpty,
      reason:
          '出现网络／分析类依赖：$offending。本应用承诺不上传任何数据；'
          '若确有需要（例如将来做云同步），必须先更新需求 §14.4 与手工清单 9.7，'
          '而不是悄悄加一个包。',
    );
  });

  test('lib/ 的源码里没有网络调用或网络包 import', () {
    final root = Directory(_scannedDirectory);
    expect(
      root.existsSync(),
      isTrue,
      reason: '找不到 $_scannedDirectory 目录——测试的工作目录应当就是包根目录',
    );

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        // 生成代码不参与：它由 build_runner 从声明生成，不表达人的意图。
        .where((file) => !file.path.endsWith('.g.dart'))
        .toList();

    // **防空跑**：路径写错时 `files` 会是空表，下面的循环一次都不执行，测试照样绿。
    expect(
      files.length,
      greaterThan(50),
      reason: '只扫到 ${files.length} 个 .dart 文件，明显不对——扫描路径可能失效了',
    );

    final hits = <String>[];
    for (final file in files) {
      final content = _stripLineComments(file.readAsStringSync());
      for (final symbol in _forbiddenSymbols) {
        if (content.contains(symbol)) {
          hits.add('${file.path} 含 $symbol');
        }
      }
    }

    expect(
      hits,
      isEmpty,
      reason:
          'lib/ 里出现网络调用：$hits。本应用不上传任何数据；'
          '若这是有意的，请先更新需求 §14.4 与手工清单 9.7。',
    );
  });
}

/// 去掉 `//` 之后的内容再扫描。
///
/// **为什么必须做这一步**：这是朴素的子串扫描，而 `lib/` 里的文档注释完全可能写着
/// "这里**不用** `HttpClient(`"之类的说明——那会把它误判成违规。隐私门禁宁可偏保守，但
/// **不能靠"别在注释里提这个词"来维持**：那种门禁迟早被人加 `// ignore` 绕过去。
/// 代价是：字符串字面量里若出现 `//` 之后紧跟违规符号，会漏掉——现实中不成立，可接受。
String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final index = line.indexOf('//');
      return index < 0 ? line : line.substring(0, index);
    })
    .join('\n');
