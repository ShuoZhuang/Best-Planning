import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 发布门禁的结构检查（规范 §17、§24.1、§24.4）。
///
/// 它**不**把 NOT RUN 洗成 PASS：只验证编号连续、无重复、状态合法、PASS 项有真实证据
/// 文件。真正发布前还需要机器报告与安装态证据；本用例的失败不会因为"文档写得完整"而变绿。
void main() {
  final spec = File(
    'docs/superpowers/specs/2026-10-18-v1.11.0-execution-start-and-recovery-design.md',
  );
  final acceptance = File(
    'docs/testing/v1.11.0-execution-start-and-recovery-acceptance.md',
  );

  test('EXE-01..80 在规格与验收记录中各出现一次', () {
    expect(spec.existsSync(), isTrue, reason: '缺少 1.11.0 规格');
    expect(acceptance.existsSync(), isTrue, reason: '缺少验收记录');

    final specIds = _idsIn(spec.readAsStringSync());
    final acceptanceIds = _idsIn(acceptance.readAsStringSync());
    expect(specIds, hasLength(80));
    expect(acceptanceIds, hasLength(80));
    expect(specIds.toSet(), hasLength(80));
    expect(acceptanceIds.toSet(), hasLength(80));
    expect(acceptanceIds, orderedEquals(specIds), reason: '验收记录必须按规格顺序列出全部编号');
  });

  test('验收状态只有 PASS / FAIL / NOT RUN，且 PASS 项有证据文件', () {
    final lines = acceptance.readAsLinesSync();
    var checked = 0;
    for (final line in lines) {
      final match = RegExp(
        r'^\| (EXE-\d{2}) \| .*? \| (PASS|FAIL|NOT RUN) \| (.*?) \|$',
      ).firstMatch(line);
      if (match == null) continue;
      checked++;
      final status = match.group(2)!;
      final evidence = match.group(3)!.trim();
      expect(
        const {'PASS', 'FAIL', 'NOT RUN'},
        contains(status),
        reason: '${match.group(1)} 状态不合法',
      );
      if (status == 'PASS') {
        for (final path in evidence.split(';')) {
          final trimmed = path.trim();
          if (trimmed.isEmpty || trimmed == '未实施或未运行') continue;
          expect(
            File(trimmed).existsSync(),
            isTrue,
            reason: '${match.group(1)} 的证据文件不存在：$trimmed',
          );
        }
      }
    }
    expect(checked, 80, reason: '验收矩阵必须包含 80 个互异编号');
  });

  test('规格中的必需不变量在源码里有落点', () {
    for (final file in [
      'lib/domain/execution/execution_models.dart',
      'lib/domain/execution/execution_result.dart',
      'lib/domain/execution/execution_progress.dart',
      'lib/domain/execution/execution_metrics.dart',
      'lib/application/execution/execution_commands.dart',
      'lib/application/execution/execution_service.dart',
      'lib/application/execution/execution_plan_linker.dart',
      'lib/application/execution/execution_recovery_service.dart',
      'lib/application/execution/execution_metrics_query.dart',
      'lib/application/execution/execution_reminder_coordinator.dart',
      'lib/data/repositories/drift_execution_repository.dart',
      'lib/features/execution/execution_card.dart',
      'lib/features/execution/execution_bar.dart',
      'lib/features/execution/execution_record_editor.dart',
    ]) {
      expect(File(file).existsSync(), isTrue, reason: '缺少 $file');
    }
  });
}

List<String> _idsIn(String content) => [
  for (final match in RegExp(
    r'^\| (EXE-\d{2}) \|',
    multiLine: true,
  ).allMatches(content))
    match.group(1)!,
];
