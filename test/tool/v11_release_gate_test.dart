import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 1.11.0 发布门禁的**结构性**检查（原 1.12 计划 Task 19 的自动化部分）。
///
/// 它不能替代安装态/真实迁移演练；但能阻止“验收文档缺项、版本漂移、把 FAIL 混进
/// 通过状态”这类发布记录错误。安装态阻断见 `v1.11.0-release-gate.md`。
void main() {
  test('版本、验收矩阵与发布门禁记录一致，且没有 FAIL 混入', () async {
    final pubspec = await File('pubspec.yaml').readAsString();
    expect(pubspec, contains('version: 1.11.0+52'));
    expect(pubspec, contains('msix_version: 1.11.0.0'));
    expect(pubspec, contains('output_name: personal_planner_1.11.0.0_x64'));

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
