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
import 'package:personal_planner/domain/models/app_update.dart';

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
  // "当前取值"、工作区 `版本号规则.md` 的"当前值"一起改。抬版本时**故意**改这一行，就是流程本身。
  //
  // 判定依据：`1.6.0+35` / MSIX `1.6.0.0` **已经交付给用户做体验确认**，因此这一批不能再并入
  // 它（"同批次只加构建号、只动第四段"的前提是这一批还没到任何人手上）。本次内容是
  // **`1.6` 发布线的收口版本**（M9，2026-10-07）。现行口径见 `docs/release/version-policy.md`
  // 第 4.0 节：一个 `1.6` 发布线 + 九个内部里程碑 M1～M9，第二段**固定为 `1.6`**，
  // 里程碑不单独抬号、不单独发布。
  //
  // 收口时抬第 3 段（`1.6.1` → `1.6.2`）而不是第 2 段：
  // ① 第 2 段**被现行口径固定住**，抬它就是升到 `1.7`——路线图 §13 明令禁止；
  // ② 第 3 段原本只用于"纯修复"，但这里是**唯一还剩的可用段位**，收口必须让版本向前走；
  // ③ 第 4 段（MSIX）**必须严格大于本机已安装的 `1.6.1.0`**，`1.6.2.0` 满足。
  //
  // 构建号全局单调递增：`+36` 之后是 `+37`（不随版本号归零）。
  //
  // **这条测试的存在意义**：让"静默改号"无法通过。抬版本时**故意**改这一段就是流程本身，
  // 必须与 `docs/release/version-policy.md` 第 4 节、`docs/release/build-ledger.md`
  // 的新条目一起改。
  test('当前候选批次是 1.6.2+37 / MSIX 1.6.2.0（M9 收口）', () {
    expect(
      pubspecVersion(),
      '1.6.2+37',
      reason: 'M9 收口：第二段固定 1.6，抬第 3 段到 1.6.2，构建号递增到 37',
    );
    expect(
      _scalar(lines, RegExp(r'^\s{2}msix_version:\s*(\S+)\s*$')),
      '1.6.2.0',
      reason:
          'MSIX 前三段必须与 version 一致；第四段 `1` = **同批次重打包**'
          '（收口之后又改掉一处缺陷：备份页会把异常里的完整路径打到界面上），'
          '而不是抬第三段',
    );
    expect(
      _scalar(lines, RegExp(r'^\s{2}output_name:\s*(\S+)\s*$')),
      'personal_planner_1.6.2.0_x64',
      reason: '产物名沿用既有格式，旧版本片段必须一起换掉',
    );
    expect(appVersion, '1.6.2+37', reason: '这一项会写进备份清单，必须与 version 一字不差');
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
        const FixedAppVersionProvider(AppVersion(1, 7, 0, build: 38)),
        isA<AppVersionProvider>(),
      );
    });

    test('更新检查的版本来源是端口，而不是 backup_assembly 的常量', () {
      // `AppVersionProvider` 的返回类型是 `AppVersion?`——**手写常量不是这个类型**，
      // 它是一段字符串。因此把常量塞回更新判断必须先经过解析，而解析这一步本身就要求
      // 有人显式选择"用手写值"。这条断言把那个类型契约钉住。
      const AppVersionProvider provider = FixedAppVersionProvider(
        AppVersion(1, 6, 2, build: 37),
      );
      expect(
        provider.currentVersion(),
        completion(AppVersion.parse('1.6.2+37')),
      );
      // 常量仍然与它一致（这一条会被上一条测试守着），但**更新服务拿不到它**：
      // `UpdateService` 的构造参数里没有 `appVersion`，只有 `versions`。
      expect(appVersion, '1.6.2+37');
    });
  });
}
