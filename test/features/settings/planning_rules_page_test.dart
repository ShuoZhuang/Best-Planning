import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';

void main() {
  testWidgets('设置页覆盖规则、通知和自动调整并可保存', (tester) async {
    final service = SettingsService(repository: MemorySettingsRepository());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanningRulesPage(
            service: service,
            localDate: DateTime(2026, 10, 2),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('作息与保护时间'), findsOneWidget);
    expect(find.text('精力区间'), findsOneWidget);
    expect(find.text('专注与任务片段'), findsOneWidget);
    expect(find.text('每日上限与生活配额'), findsOneWidget);
    expect(find.text('通知与自动调整'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '信任自动调整'))
          .value,
      isFalse,
    );

    final lunchSwitch = find.widgetWithText(SwitchListTile, '午餐保护');
    await tester.ensureVisible(lunchSwitch);
    await tester.tap(lunchSwitch);
    final taskNotification = find.widgetWithText(SwitchListTile, '任务开始提醒');
    await tester.ensureVisible(taskNotification);
    await tester.tap(taskNotification);

    await tester.enterText(find.byKey(const Key('weekday-daily-limit')), '300');
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(find.text('设置已保存'), findsOneWidget);
    final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
    expect(resolved.rules.dailyMovableTaskLimitMinutes, 300);
    expect(
      resolved.rules.protectedTimes.where((item) => item.kind.name == 'lunch'),
      isEmpty,
    );
    expect(resolved.notifications.taskStartEnabled, isFalse);
  });

  testWidgets('保存前在字段旁显示非法时长错误', (tester) async {
    final service = SettingsService(repository: MemorySettingsRepository());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanningRulesPage(
            service: service,
            localDate: DateTime(2026, 10, 2),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('weekday-daily-limit')),
      '1441',
    );
    await tester.enterText(find.byKey(const Key('min-chunk-minutes')), '0');
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(find.text('不能超过 1440 分钟'), findsOneWidget);
    expect(find.text('必须大于 0'), findsOneWidget);
    expect(find.text('设置已保存'), findsNothing);
  });
}
