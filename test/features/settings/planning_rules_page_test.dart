import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';

/// 触发一次"返回"。
///
/// **不用 	ester.pageBack()**：它要求页面上恰好有一个返回按钮，而本用例的规则页
/// 是挂在一个最简导航栈里的（真实外壳的返回按钮在侧边栏，不在这里）。
/// 直接向 binding 发一次 pop 请求，测的是**同一件事**（PopScope 会不会拦下这次 pop），
/// 但不依赖外壳的按钮长什么样。
Future<void> _goBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

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

  // ─────────────────────────────────────────────────────────────────────────────
  // M8（路线图 §12）："设置子页面返回行为一致，不丢失已保存内容，
  // **也不静默丢弃未保存内容**"。规格：`2026-10-07-m8-onboarding-and-settings.md`
  // ─────────────────────────────────────────────────────────────────────────────

  /// 挂一个**有上一页**的导航栈：`PopScope` 只在真的 pop 时才起作用，
  /// 直接把它当 `home` 是测不出返回行为的。
  Future<void> pumpWithBack(
    WidgetTester tester,
    SettingsService service,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open-rules'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      // 带 AppBar 才会渲染返回按钮——	ester.pageBack() 找的就是它。
                      appBar: AppBar(title: const Text('规划规则')),
                      body: PlanningRulesPage(
                        service: service,
                        localDate: DateTime(2026, 10, 2),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开规则页'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-rules')));
    await tester.pumpAndSettle();
  }

  testWidgets('M8 没改过东西时返回不拦人（不为了省事每次都弹框）', (tester) async {
    // 这一条是关键：`TextEditingController` 分不清"程序填的初值"与"用户敲的字"。
    // 若只看"变过没有"，载入本身就会被当成一次编辑，于是**每次返回都弹确认框**——
    // 那比不提示更烦人，用户会开始无脑点"放弃修改"。
    final service = SettingsService(repository: MemorySettingsRepository());
    await pumpWithBack(tester, service);

    await _goBack(tester);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('planning-rules-unsaved-dialog')),
      findsNothing,
      reason: '什么都没改过就不该弹框',
    );
    expect(
      find.byKey(const Key('open-rules')),
      findsOneWidget,
      reason: '应当已经返回上一页',
    );
  });

  testWidgets('M8 改了还没保存就返回：弹确认框，选「继续编辑」留在原页', (tester) async {
    final service = SettingsService(repository: MemorySettingsRepository());
    await pumpWithBack(tester, service);

    await tester.enterText(find.byKey(const Key('weekday-daily-limit')), '300');
    await tester.pumpAndSettle();

    await _goBack(tester);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('planning-rules-unsaved-dialog')),
      findsOneWidget,
      reason: '有未保存的修改时必须先问一句，不能静默丢掉',
    );

    await tester.tap(find.byKey(const Key('planning-rules-keep-editing')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('open-rules')),
      findsNothing,
      reason: '应当留在规则页',
    );
    // 编辑还在。
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('weekday-daily-limit')))
          .controller!
          .text,
      '300',
    );
  });

  testWidgets('M8 选「放弃修改」才真的离开，且不落库', (tester) async {
    final service = SettingsService(repository: MemorySettingsRepository());
    await pumpWithBack(tester, service);

    await tester.enterText(find.byKey(const Key('weekday-daily-limit')), '300');
    await tester.pumpAndSettle();
    await _goBack(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planning-rules-discard')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('open-rules')),
      findsOneWidget,
      reason: '应当回到上一页',
    );
    // 「放弃修改」就是放弃：**不能**顺手把它存下去。
    final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
    expect(
      resolved.rules.dailyMovableTaskLimitMinutes,
      isNot(300),
      reason: '放弃修改不该产生任何写入',
    );
  });

  testWidgets('M8 保存之后再返回就不该再拦（改动已经落库了）', (tester) async {
    final service = SettingsService(repository: MemorySettingsRepository());
    await pumpWithBack(tester, service);

    await tester.enterText(find.byKey(const Key('weekday-daily-limit')), '300');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    await _goBack(tester);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('planning-rules-unsaved-dialog')),
      findsNothing,
      reason: '已经保存过，返回时不该再问',
    );
    expect(find.byKey(const Key('open-rules')), findsOneWidget);
  });
}
