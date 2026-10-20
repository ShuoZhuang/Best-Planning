import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/repositories/drift_export_data_source.dart';

import '../application/execution/execution_test_support.dart';

void main() {
  test('导出事实包含周期、片段、证据与预排，不丢新身份链', () async {
    final harness = await ExecutionTestHarness.create();
    addTearDown(harness.close);
    final facts = await DriftExportDataSource(harness.database).loadAllFacts();
    expect(
      facts.keys,
      containsAll([
        'recurringTaskTemplates',
        'recurringTaskCycles',
        'recurringCycleSnapshots',
        'recurringCompletionEvidence',
        'executionOccurrences',
        'executionFragments',
        'executionBlockLinks',
        'executionActivitySegments',
        'pendingPlanPreviews',
        'pendingPlanPreviewBlocks',
      ]),
    );
  });
}
