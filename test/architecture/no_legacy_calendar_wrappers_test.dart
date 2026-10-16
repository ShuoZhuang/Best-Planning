// Task 2 Step 6／Task 11 的 **API1**：生产代码的静态扫描门禁。
//
// 计划把"删除而不是继续 deprecate"写成硬要求（§2.0.1）：只要旧的**只传时间**包装器
// 还编译得过，同一个事故就能从另一个入口复发——而那是本计划要封住的起点。
//
// 因此这一条不是"检查有没有调用"，而是"**检查这些符号在 lib/ 里根本不存在**"：
//
// * `CalendarService` 上不得再有 `replaceOccurrence`／`replaceFollowingOccurrences`／
//   `replaceSeries`；它们只收时间与标题，标题与时区靠两张进程内缓存补齐，
//   缓存里没有就写 `未命名事项` 与 `UTC`（计划 §1.1，C01–C03）。
// * 缓存与兜底常量必须一并消失（`_fallbackTitle`、`_fallbackTimeZoneId`、
//   `rememberTitleForLegacyWrappers`、`rememberTimeZoneForLegacyWrappers`）。
// * 完整草稿类型 `CalendarEventEditDraft` 必须被显式 patch 取代（C04–C08）。
// * 固定日期载体 `DateTime(2026, 1, 5)` 不得出现在 lib/ 里：它是"用固定日期承载钟点"
//   的实现，而那个实现会在 Asia/Shanghai 的清晨把课程落到前一天（C10、C11）。
//
// **删除的三个入口现在由这一条门禁守着**：任何人把其中任何一个加回来，测试立刻红。
//
// ## 为什么"防空跑"写在最前面
//
// 朴素的目录扫描有一个致命失效模式：路径写错时一个文件都扫不到，循环一次都不执行，
// 而测试**照样是绿的**。因此先断言"确实扫到了足够多的文件"，再断言"没有命中"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 整个 `lib/` 里都不允许出现的符号（去掉行注释与块注释之后匹配）。
const _forbiddenAnywhere = <String>[
  // 迁移期缓存与兜底常量。
  '_fallbackTitle',
  '_fallbackTimeZoneId',
  'rememberTitleForLegacyWrappers',
  'rememberTimeZoneForLegacyWrappers',
  // 被显式 patch 取代的"完整草稿"。
  'CalendarEventEditDraft',
  // 用固定日期承载钟点的旧做法。
  '_mapToSegmentDay',
  '_addLocalDays',
  'DateTime(2026, 1, 5)',
  // 已被合并掉的两个同义入口。
  'course-edit-time',
  'editWholeCourse',
];

/// 只允许出现在 `CalendarService` 之外（即端口与仓储）的符号。
///
/// **为什么不能一刀切禁掉 `replaceSeries(`**：`CalendarEventDeletion` 是**端口**，
/// 它的方法名就该表达"改写哪一段"；`CalendarService.updateEvent` 会按范围**调用**它。
/// 真正被删除的是 `CalendarService` 上那三个**只收时间的包装器**。
///
/// 因此判据是"**定义**在 calendar_service.dart 里即失败"，而不是"提到名字即失败"：
/// 正则要求方法名前面不是 `.`（排除 `deletion.replaceSeries(` 这种分派调用）。
/// 用按名字全局禁掉的办法会把合法调用一起毙掉，而那种门禁最后只会被人加 ignore。
final _forbiddenInCalendarService = <RegExp>[
  RegExp(r'(?<![.\w])replaceOccurrence\('),
  RegExp(r'(?<![.\w])replaceFollowingOccurrences\('),
  RegExp(r'(?<![.\w])replaceSeries\('),
];

const _scannedDirectory = 'lib';

void main() {
  test('API1：lib/ 里不存在旧 replace 包装器、legacy 缓存或 fallback 常量', () {
    final root = Directory(_scannedDirectory);
    expect(root.existsSync(), isTrue, reason: '测试的工作目录应当就是包根目录');

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        // 生成代码不参与：它由 build_runner 从声明生成，不表达人的意图。
        .where((file) => !file.path.endsWith('.g.dart'))
        .toList();

    // **防空跑**。
    expect(
      files.length,
      greaterThan(50),
      reason: '只扫到 ${files.length} 个 .dart 文件——扫描路径可能失效了，那样这条门禁是空转',
    );

    final hits = <String>[];
    for (final file in files) {
      final content = _stripComments(file.readAsStringSync());
      for (final symbol in _forbiddenAnywhere) {
        if (content.contains(symbol)) {
          hits.add('${file.path} 含 $symbol');
        }
      }
      if (file.path.endsWith(
            'application${Platform.pathSeparator}calendar_service.dart',
          ) ||
          file.path.endsWith('application/calendar_service.dart')) {
        for (final pattern in _forbiddenInCalendarService) {
          final match = pattern.firstMatch(content);
          if (match != null) {
            hits.add('${file.path} 定义了 ${match.group(0)}');
          }
        }
      }
    }

    expect(
      hits,
      isEmpty,
      reason:
          'lib/ 里出现了已被删除的旧接口或兜底符号：$hits。\n'
          '这些符号正是"只改时间却覆盖资料"事故的来源；'
          '请改用 CalendarEventPatch（单次／以后／整条系列）或课程快照事务'
          '（previewCourseEdit → saveCourse → replaceCourseSeries）。',
    );
  });

  test('API1：lib/ 里的旧占位标题只剩**检测用的常量**一处', () {
    final files = Directory(_scannedDirectory)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.path.endsWith('.g.dart'))
        .toList();

    final hits = <String>[];
    for (final file in files) {
      final content = _stripComments(file.readAsStringSync());
      if (content.contains('未命名事项')) hits.add(file.path);
    }

    expect(
      hits,
      [
        '$_scannedDirectory${Platform.pathSeparator}domain'
            '${Platform.pathSeparator}models'
            '${Platform.pathSeparator}course_series.dart',
      ],
      reason:
          '「未命名事项」只允许作为**检测旧数据的常量**'
          '（legacyPlaceholderCourseTitle）出现一次。'
          '任何写入路径再出现它，就等于把"缺字段"伪装成合法数据（§16 第一条捷径）。',
    );
  });

  test('API1：course_detail_page 只有「编辑课程」入口', () {
    final page = File(
      '$_scannedDirectory${Platform.pathSeparator}features'
      '${Platform.pathSeparator}calendar${Platform.pathSeparator}courses'
      '${Platform.pathSeparator}course_detail_page.dart',
    );
    expect(page.existsSync(), isTrue);

    final content = _stripComments(page.readAsStringSync());
    expect(
      content.contains("Key('course-edit-course')"),
      isTrue,
      reason: '整门课程的唯一入口必须还在',
    );
    expect(
      content.contains("Key('course-edit-time')"),
      isFalse,
      reason: '两个实现不同、文案重叠的整门课程入口必须合并成一个安全事务入口',
    );
  });
}

/// 去掉 `//` 行注释、`///` 文档注释与 `/* … */` 块注释之后再扫描。
///
/// **为什么必须做这一步**：本文件的用例名与实现注释里会提到这些符号（例如
/// "不得再出现 `_fallbackTitle`"），而朴素的子串扫描会把说明文字误判成违规。
/// 隐私门禁那边出于"不靠别在注释里提这个词来维持"的理由选择了保守做法；
/// 这里相反——**被删掉的方法名一定要能出现在注释里**，否则代码里就没法解释
/// 为什么它被删了，而"为什么"正是防止它被加回来的东西。
String _stripComments(String source) {
  final withoutBlock = source.replaceAll(
    RegExp(r'/\*.*?\*/', dotAll: true),
    '',
  );
  return withoutBlock
      .split('\n')
      .map((line) {
        final index = line.indexOf('//');
        return index < 0 ? line : line.substring(0, index);
      })
      .join('\n');
}
