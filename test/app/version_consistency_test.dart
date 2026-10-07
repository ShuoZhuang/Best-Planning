// 版本号散在三处，其中一处是**硬编码在源码里的常量**——这个文件守它们的一致性。
//
// 背景：本项目没有 `package_info` 一类依赖，运行时读不到真实版本，于是
// `lib/app/backup_assembly.dart` 的 `appVersion` 只能手工跟随 `pubspec.yaml`，而它会被写进
// **备份清单**。漂移的后果不是"显示不好看"，而是备份里记着一个对不上任何发布号的版本。
//
// 规则见 `docs/release/version-policy.md`：`pubspec.yaml` 是唯一数值来源；`msix_version` 必须是
// 四段式且前三段与它一致（`Add-AppxPackage` 只认四段式，且不接受降级）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/backup_assembly.dart';

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
  // 判定依据：批次仍是 **`1.5.0`**，且它**尚未对外发布**。第四段 `5` → `6`：
  // 本批次在本机已经装过 `1.5.0.0`，而同一个号不能重发不同内容（`Add-AppxPackage` 只升不降），
  // 因此按"同批次重打包"抬第四段。构建号全局单调递增 → `+28` 之后是 `+29`。
  //
  // **为什么不再抬第 2 段**：这次的内容（移除计划/实际、拆横向占比与纵向总计、图型可选、
  // 休息时长/作息规律性/工作休息比例、领域覆盖缺口）与 `1.5.0` 是**同一件事**——"统计复盘改版"，
  // 只是这一批还没交付出去。第 2 节的规则按"批次里含新功能"定段，`1.5.0` 已经因此抬过一次；
  // 同一批次里的后续改动只加构建号与第四段。**一旦 `1.5.0.x` 交付给任何人**，后续改动就必须
  // 抬第 2 段或第 3 段，不能再拿第四段当补丁计数器（`version-policy.md` 第 4 节的边界）。
  test('当前候选批次是 1.5.0+34 / MSIX 1.5.0.6', () {
    expect(
      pubspecVersion(),
      '1.5.0+34',
      reason: '仍是同一批次：第二段保持 1.5.0，构建号在 33 之后继续递增',
    );
    expect(
      _scalar(lines, RegExp(r'^\s{2}msix_version:\s*(\S+)\s*$')),
      '1.5.0.6',
      reason: 'MSIX 前三段必须与 version 一致；同批次改了内容重打包，第四段 +1',
    );
    expect(
      _scalar(lines, RegExp(r'^\s{2}output_name:\s*(\S+)\s*$')),
      'personal_planner_1.5.0.6_x64',
      reason: '产物名沿用既有格式，旧版本片段必须一起换掉',
    );
    expect(appVersion, '1.5.0+34', reason: '这一项会写进备份清单，必须与 version 一字不差');
  });
}
