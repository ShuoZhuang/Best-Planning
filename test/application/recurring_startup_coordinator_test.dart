import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/recurring_startup_coordinator.dart';

void main() {
  test('阶段按固定顺序执行，失败即停并保留已完成阶段', () async {
    final calls = <RecurringStartupStage>[];
    final coordinator = RecurringStartupCoordinator(
      stages: {
        RecurringStartupStage.fragmentBackfill: () async {
          calls.add(RecurringStartupStage.fragmentBackfill);
        },
        RecurringStartupStage.creditCheck: () async {
          calls.add(RecurringStartupStage.creditCheck);
          throw StateError('credit mismatch');
        },
        RecurringStartupStage.horizonMaintenance: () async {
          calls.add(RecurringStartupStage.horizonMaintenance);
        },
      },
    );
    final report = await coordinator.run();
    expect(report.succeeded, false);
    expect(report.failedStage, RecurringStartupStage.creditCheck);
    expect(report.completed, [RecurringStartupStage.fragmentBackfill]);
    expect(calls.contains(RecurringStartupStage.horizonMaintenance), false);
  });
}
