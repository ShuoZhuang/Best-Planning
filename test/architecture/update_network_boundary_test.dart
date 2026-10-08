// 联网边界（路线图 §3.6 / §12：「本地优先不变，除用户允许的更新检查外，数据不得离开本机」）。
//
// `no_network_test.dart` 是这条承诺的**门禁**：它禁止 `lib/` 里出现任何网络调用。1.7 加入更新
// 检查等于在这条门禁上开一个口子，而这个文件负责证明**口子只有一个，且它只发版本信息**。
//
// 为什么不能只改那条门禁就完事：把 `package:http/` 从禁用符号里删掉，等于从此以后任何文件都
// 可以发请求，"只有一个出网口"就退化成一句注释。这里改成"**恰好一个文件**可以 import 它，
// 其余任何地方出现都是失败"——口子的大小由测试守着，而不是由记性守着。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许 import `package:http` 的**唯一**文件。
const _sanctionedClient = 'lib/platform/update/github_release_client.dart';

/// 生产代码里被检查的目录。与 `no_network_test.dart` 一致，因此两个门禁看的是同一片地方。
const _scannedDirectory = 'lib';

List<File> _dartSources() =>
    Directory(_scannedDirectory)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        // 生成代码不参与：它由 build_runner 从声明生成，不表达人的意图。
        .where((file) => !file.path.endsWith('.g.dart'))
        .toList();

void main() {
  test('整个 lib/ 里只有更新客户端一个文件 import 网络包', () {
    final files = _dartSources();
    // **防空跑**：路径写错时下面一次都不执行，而测试照样绿。
    expect(
      files.length,
      greaterThan(50),
      reason: '只扫到 ${files.length} 个 .dart 文件，扫描路径可能失效了',
    );

    final offenders = <String>[];
    var sanctionedSeen = false;
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      final importsHttp = file.readAsLinesSync().any(
        (line) => line.startsWith('import ') && line.contains('package:http/'),
      );
      if (!importsHttp) continue;
      if (path.endsWith(_sanctionedClient)) {
        sanctionedSeen = true;
        continue;
      }
      offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件也 import 了 package:http：$offenders。'
          '本应用只有一个出网口（$_sanctionedClient），'
          '新增一个就等于把"数据不出本机"变成一句没人守的注释。',
    );
    // **反向断言**：如果那个文件不再 import http（例如换成了 dart:io），这条门禁就变成空跑。
    expect(
      sanctionedSeen,
      isTrue,
      reason: '在那份允许名单里没找到 $_sanctionedClient——允许名单本身失效了',
    );
  });

  test('出网口只对固定的 HTTPS 仓库地址发请求', () {
    final source = File(_sanctionedClient).readAsStringSync();

    // 请求地址是**常量**而不是参数：做成参数就有第二个地方能把它指向别的仓库。
    expect(
      source,
      contains('https://api.github.com/repos/'),
      reason: 'GitHub API 的地址必须是写死的',
    );
    expect(
      source,
      contains("'ShuoZhuang/Best-Planning'"),
      reason: '被检查的仓库是固定值，不做成参数',
    );
    // **不接受明文 HTTP**：它会让"只请求公开元数据"变成"任何中间人都能改这次响应"。
    expect(source.contains("'http://"), isFalse, reason: '更新检查不允许明文 HTTP');
    // 请求头上必须报名字：GitHub 对没有 User-Agent 的请求直接回 403，而 403 在这里与"限流"
    // 是同一个状态码，用户会看到一条由我们自己造成的失败原因。
    expect(source, contains('User-Agent'));
  });

  test('出网口不发任何本地数据：没有 cookie、授权头，也没有带参数的查询串', () {
    // **先去掉行注释再扫**：这个文件里有大量"**不发 cookie**"这样的说明，朴素的子串扫描会把
    // 说明本身当成违规（`no_network_test.dart` 开头也处理过同一个坑）。这里扫的是**代码**。
    final source = _stripLineComments(
      File(_sanctionedClient).readAsStringSync(),
    );
    for (final forbidden in const [
      'cookie',
      'Cookie',
      'Authorization',
      'Bearer',
    ]) {
      expect(
        source.contains(forbidden),
        isFalse,
        reason: '请求里不该出现 $forbidden——更新检查只读公开元数据',
      );
    }
    // 版本号**不做成查询参数**：把"我装的是哪一版"发出去，超出了"只请求版本信息"这句话。
    expect(source.contains(r'?version='), isFalse, reason: '不要把本地版本拼进请求地址');
  });
}

/// 去掉 `//` 之后的内容，只留代码。
String _stripLineComments(String source) => source
    .split('\n')
    .map((line) {
      final index = line.indexOf('//');
      return index < 0 ? line : line.substring(0, index);
    })
    .join('\n');
