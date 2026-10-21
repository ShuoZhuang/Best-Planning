// 版本号散在三处，其中一处是**硬编码在源码里的常量**——这个文件守它们的一致性。
//
// 背景：本项目此前没有 `package_info` 一类依赖，运行时读不到真实版本，于是
// `lib/app/backup_assembly.dart` 的 `appVersion` 只能手工跟随 `pubspec.yaml`，而它会被写进
// **备份清单**。漂移的后果不是"显示不好看"，而是备份里记着一个对不上任何发布号的版本。
//
// **1.7 起这条手工一致有了第二条防线**（路线图 §3.6 / Task 10）：更新检查的"当前版本"改从
// **安装包元数据**读（`package_info_plus`），手写常量不再参与任何"要不要提示更新"的判断——
// 因为那个数字一旦漂移，表现是"明明有新版本却一直说已是最新"，用户完全看不出原因。
// 下面最后两条用例分别守这两条：**清单里的常量仍与 pubspec 一致**，且
// **更新检查不再依赖那个常量**。
//
// 规则见 `docs/release/version-policy.md`：`pubspec.yaml` 是唯一数值来源；`msix_version` 必须是
// 四段式且前三段与它一致（`Add-AppxPackage` 只认四段式，且不接受降级）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/application/app_version_provider.dart';
import 'package:personal_planner/domain/models/app_version.dart';

/// 在 pubspec.yaml 里按行取一个标量。用"整行匹配"而不是全局搜，避免命中同名键或注释。
String? _scalar(List<String> lines, RegExp pattern) {
  for (final line in lines) {
    final match = pattern.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

void main() {
  late List<String> lines;

  setUpAll(() {
    final pubspec = File('pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: '读不到 pubspec.yaml——测试的工作目录应当就是包根目录',
    );
    lines = pubspec.readAsLinesSync();
  });

  /// 顶层 `version:`（0 缩进）。
  String? pubspecVersion() => _scalar(lines, RegExp(r'^version:\s*(\S+)\s*$'));

  test('备份清单里的 appVersion 与 pubspec.yaml 的 version 一致', () {
    final version = pubspecVersion();
    expect(version, isNotNull, reason: '没有从 pubspec.yaml 顶层解析出 version');

    expect(
      appVersion,
      version,
      reason:
          'backup_assembly.dart 的 appVersion 会被写进备份清单，必须与 pubspec.yaml 的 version '
          '一字不差；改版本时两处一起改（见 docs/release/version-policy.md 第 6 节）',
    );
  });

  test('msix_version 是四段式，且前三段与 version 一致', () {
    final version = pubspecVersion();
    expect(version, isNotNull, reason: '没有从 pubspec.yaml 顶层解析出 version');

    final msix = _scalar(lines, RegExp(r'^\s{2}msix_version:\s*(\S+)\s*$'));
    expect(
      msix,
      isNotNull,
      reason: '没有从 pubspec.yaml 的 msix_config 里解析出 msix_version',
    );

    // `1.4.0+19` 里的 `+19` 是构建号，不参与语义比较。
    final semantic = version!.split('+').first;
    final segments = msix!.split('.');
    expect(segments.length, 4, reason: 'MSIX 只接受四段式版本号');
    expect(
      segments.take(3).join('.'),
      semantic,
      reason:
          'msix_version 的前三段必须等于 pubspec.yaml 的 version——否则安装包的文件属性、'
          '已安装版本与"关于"里看到的号会互相矛盾',
    );
    expect(
      int.tryParse(segments[3]),
      isNotNull,
      reason: 'MSIX 的第四段必须是数字；同一批次重打包时在这里 +1，而不是抬第三段',
    );
  });

  test('version 写成"语义版本+构建号"，且构建号是正整数', () {
    final version = pubspecVersion();
    expect(version, isNotNull, reason: '没有从 pubspec.yaml 顶层解析出 version');

    final parts = version!.split('+');
    expect(
      parts.length,
      2,
      reason: 'version 应当写成 <major>.<minor>.<patch>+<构建号>',
    );
    expect(
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(parts[0]),
      isTrue,
      reason: '前三段必须是三个数字：实际为 ${parts[0]}',
    );
    final build = int.tryParse(parts[1]);
    expect(build, isNotNull, reason: '构建号必须是数字：实际为 ${parts[1]}');
    expect(build! >= 1, isTrue, reason: '构建号从 1 起算，且全局单调递增（不随版本号归零）');
  });

  // 上面三条守的是"三处彼此一致"，它们对**任何**取值都成立——包括一次忘了记录的静默改号。
  // 这一条把**当前候选批次**本身钉住：改版本是一个有后果的动作（MSIX 只升不降），必须是有意的，
  // 并且要与 `docs/release/build-ledger.md` 的新条目、`docs/release/version-policy.md` 的
  // 对应批次一起改。抬版本时**故意**改这一行，就是流程本身。
  //
  // 当前批次是 `1.11.1+53` / MSIX `1.11.1.0`（2026-10-20，更新清单缓存与回退基线修复）。
  // 判定依据见 `docs/release/version-policy.md` 第 2 节与第 11 节：批次里只有修复、不改包身份、
  // 数据库 schema 仍为 11 ⇒ 抬第 3 段；本批**改了代码** ⇒ MSIX 第 4 段不能当"重打包"计数，
  // 必须归零。构建号全局单调递增：`+52` 之后是 `+53`（`+52` 已用于已发布的 `1.11.0`）。
  //
  // **这条测试的存在意义**：让"静默改号"无法通过。
  test('当前候选批次是 1.11.1+53 / MSIX 1.11.1.0（更新清单缓存与回退基线修复）', () {
    expect(
      pubspecVersion(),
      '1.11.1+53',
      reason:
          '**2026-10-20：`1.11.0+52` → `1.11.1+53`，抬第 3 段。**'
          '这一批只修缺陷：latest 与 tag 共用一份清单缓存，导致 304 把 1.10.2 的历史清单'
          '当成最新、已下载的 1.11.0 被降格成"已是最新版"；回退基线准备没有 single-flight '
          '且失败后永久阻塞；状态被清空后不收养磁盘上已验证的 `.ready`。'
          '按版本策略第 2 节判据，这是纯修复（不改包身份、发布者、数据库兼容），因此抬第 3 段；'
          '构建号继续全局单调递增到 `+53`（`+52` 已用于 1.11.0）。'
          '它**不是** `1.11.0.1`：本批改了代码，MSIX 第 4 段只留给"同一批代码重打包"。',
    );
    expect(
      _scalar(lines, RegExp(r'^\s{2}msix_version:\s*(\S+)\s*$')),
      '1.11.1.0',
      reason:
          'MSIX 前三段必须与 version 一致。第四段**归零为 `0`**：本批改了代码（更新清单/基线/恢复），'
          '不是"同一批代码重新打包"；只抬第四段等于把修复伪装成重打包。',
    );
    expect(
      _scalar(lines, RegExp(r'^\s{2}output_name:\s*(\S+)\s*$')),
      'personal_planner_1.11.1.0_x64',
      reason: '产物名沿用既有格式，旧版本片段必须一起换掉',
    );
    expect(appVersion, '1.11.1+53', reason: '这一项会写进备份清单，必须与 version 一字不差');
  });

  // ── 1.7 新增（路线图 §3.6 / Task 10）────────────────────────────────────────────
  //
  // 这一条守的是"**更新判断不再以手写常量为依据**"这件事本身。它不能靠"读代码确认"来守：
  // 那种确认只在写下的那一刻成立，以后有人图省事把 `appVersion` 传回 `UpdateService`，没有
  // 任何东西会红。这里用**两句话同时成立**把它钉住：
  //   ① 安装包元数据读出来的版本确实被解析成 `AppVersion`（前缀、构建号都对）；
  //   ② 备份清单的常量**与安装包元数据无关**——它是构建期抄的一行，两者可以不一致，
  //      而更新检查只认前者。
  group('更新检查的版本来源（Task 10）', () {
    test('安装包元数据读出的版本被解析成 AppVersion（含构建号）', () {
      // `package_info_plus` 在纯 Dart 测试里读不到平台通道，`PackageInfoAppVersionProvider`
      // 因此按约定返回 null（不抛）。这一条钉的是"读不出来时的契约"：**返回 null，不抛**，
      // 因为更新服务据此按"未知版本"处理，而抛异常会让更新页打不开。
      expect(
        const FixedAppVersionProvider(AppVersion(1, 7, 1, build: 42)),
        isA<AppVersionProvider>(),
      );
    });

    test('更新检查的版本来源是端口，而不是 backup_assembly 的常量', () {
      // `AppVersionProvider` 的返回类型是 `AppVersion?`——**手写常量不是这个类型**，
      // 它是一段字符串。因此把常量塞回更新判断必须先经过解析，而解析这一步本身就要求
      // 有人显式选择"用手写值"。这条断言把那个类型契约钉住。
      const AppVersionProvider provider = FixedAppVersionProvider(
        AppVersion(1, 11, 1, build: 53),
      );
      expect(
        provider.currentVersion(),
        completion(AppVersion.parse('1.11.1+53')),
      );
      // 常量此刻恰好也是这个值（上一条测试守着它），但**更新服务拿不到它**：
      // `UpdateService` 的构造参数里没有 `appVersion`，只有 `versions`。
      // 换句话说这条用例证明的是"来源是端口"，而不是"两者相等"——它们可以不一致，
      // 因为常量只是构建期抄下的一行。
      expect(appVersion, '1.11.1+53');
    });
  });
}
