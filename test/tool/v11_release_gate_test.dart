import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 发布门禁的**结构性**检查（原 1.12 计划 Task 19 的自动化部分）。
///
/// 它不能替代安装态/真实迁移演练；但能阻止“验收文档缺项、版本漂移、把 FAIL 混进
/// 通过状态”这类发布记录错误。
///
/// 2026-10-20 起：`1.11.0` 已发布，当前候选批次是 `1.11.1+53`（更新清单缓存与回退基线修复）。
/// 因此版本断言跟随 `pubspec.yaml` 的当前候选，而下方针对 `1.11.0` 的验收文档检查保持
/// **历史记录原样**——`1.11.0` 的未执行项不因后续版本发布而改写为通过。
void main() {
  test('版本、验收矩阵与发布门禁记录一致，且没有 FAIL 混入', () async {
    final pubspec = await File('pubspec.yaml').readAsString();
    expect(pubspec, contains('version: 1.11.1+53'));
    expect(pubspec, contains('msix_version: 1.11.1.0'));
    expect(pubspec, contains('output_name: personal_planner_1.11.1.0_x64'));

    final acceptance = await File(
      'docs/testing/v1.11.0-recurring-execution-and-lookahead-acceptance.md',
    ).readAsString();
    for (var task = 1; task <= 19; task++) {
      expect(acceptance, contains('| $task |'), reason: '周期验收矩阵缺 Task $task');
    }
    expect(acceptance, isNot(contains('| FAIL |')));

    final executionAcceptance = await File(
      'docs/testing/v1.11.0-execution-start-and-recovery-acceptance.md',
    ).readAsString();
    for (var exe = 1; exe <= 80; exe++) {
      expect(
        executionAcceptance,
        contains('EXE-${exe.toString().padLeft(2, '0')}'),
      );
    }

    final gate = await File('docs/testing/v1.11.0-release-gate.md')
        .readAsString();
    expect(gate, contains('不通过'));
    expect(gate, contains('已签名 MSIX'));
    expect(gate, contains('真实 v11 数据副本'));
  });
}
