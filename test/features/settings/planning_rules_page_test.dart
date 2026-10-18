import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
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

  // 用户 2026-10-08 需求："课表课程后十分钟不安排计划，我上完课要离开教室。"
  //
  // 规则本身（只对课表导入的课、只加在结束后）由 `test/scheduling/course_transition_test.dart`
  // 的 9 条用例守着。这里只钉**界面这一层**：数值能不能改、能不能关、关了会不会被当成非法输入。
  group('课后缓冲（用户 2026-10-08）', () {
    Future<SettingsService> pump(WidgetTester tester) async {
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
      return service;
    }

    testWidgets('默认 10 分钟，且输入框在"专注与任务片段"那一组里', (tester) async {
      final service = await pump(tester);

      final field = find.byKey(const Key('course-transition-minutes'));
      await tester.ensureVisible(field);
      expect(field, findsOneWidget);
      // 标签必须写明**只对课表**，否则用户会以为所有日程都被加了缓冲。
      expect(find.text('课后缓冲（分钟，仅课表）'), findsOneWidget);

      final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
      expect(resolved.rules.courseTransitionMinutes, 10);
    });

    testWidgets('改成 20 能保存并落库', (tester) async {
      final service = await pump(tester);

      await tester.enterText(
        find.byKey(const Key('course-transition-minutes')),
        '20',
      );
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
      expect(resolved.rules.courseTransitionMinutes, 20);
    });

    testWidgets('**填 0 是合法的关闭方式**，不报"必须大于 0"', (tester) async {
      final service = await pump(tester);

      await tester.enterText(
        find.byKey(const Key('course-transition-minutes')),
        '0',
      );
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
      expect(
        resolved.rules.courseTransitionMinutes,
        0,
        reason: '0 表示关闭这条规则；用 _positive 校验会让"关闭"变成非法输入',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // Task 1（课程与保护时间管理修复计划 §1.3／§2.4）：**早餐保护**
  //
  // 现状：`ProtectedTimeKind` 只有 `lunch` / `dinner` / `fixedRest`，
  // 因此**不存在**可被界面打开的早餐规则。
  //
  // 计划 §2.4 的兼容策略：设置页**始终**显示"早餐保护"一行，既有用户升级后
  // **默认关闭**——避免装完更新就悄悄改变用户已经确认过的计划。
  // ─────────────────────────────────────────────────────────────────────────────

  /// 早餐必须排在**睡眠之后、午餐之前**（计划 Task 9 Step 2 的顺序要求）。
  ///
  /// 只用 `findsOneWidget` 无法证明顺序，因此把标题行的 `dy` 读出来比较。
  void expectOrderedAfter(WidgetTester tester, String first, String second) {
    final firstY = tester.getTopLeft(find.text(first)).dy;
    final secondY = tester.getTopLeft(find.text(second)).dy;
    expect(secondY, greaterThan(firstY), reason: '「$second」应当排在「$first」之后');
  }

  testWidgets('**早餐保护这一行始终存在，且默认关闭、建议 07:30–08:00**', (tester) async {
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

    final row = find.widgetWithText(SwitchListTile, '早餐保护');
    await tester.ensureVisible(row);
    expect(
      row,
      findsOneWidget,
      reason:
          '计划 §2.4："设置页始终显示『早餐保护』一行"——'
          '连行都没有，用户就没有任何地方能打开它',
    );
    expect(
      tester.widget<SwitchListTile>(row).value,
      isFalse,
      reason:
          '**既有用户升级后默认关闭**：装完更新就悄悄改变已经确认的计划'
          '是这一批最要避免的事（计划 §2.4）',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('protected-breakfast-start')))
          .controller!
          .text,
      '07:30',
      reason: '建议时间 07:30–08:00 必须**显示出来**，用户才知道默认是什么',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('protected-breakfast-end')))
          .controller!
          .text,
      '08:00',
    );
  });

  testWidgets('早餐行排在睡眠之后、午餐之前', (tester) async {
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
    await tester.ensureVisible(find.widgetWithText(SwitchListTile, '早餐保护'));
    await tester.pumpAndSettle();

    expectOrderedAfter(tester, '最低睡眠（分钟）', '早餐保护');
    expectOrderedAfter(tester, '早餐保护', '午餐保护');
  });

  testWidgets('**启用并保存后 `breakfast` 进入规则**', (tester) async {
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

    final row = find.widgetWithText(SwitchListTile, '早餐保护');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(find.text('设置已保存'), findsOneWidget);
    final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
    final breakfast = resolved.rules.protectedTimes
        .where((item) => item.kind.name == 'breakfast')
        .toList();
    expect(breakfast, hasLength(1), reason: '启用之后规则里必须有且只有一条早餐保护');
    expect(breakfast.single.range.startMinute, 7 * 60 + 30);
    expect(breakfast.single.range.endMinute, 8 * 60);
    expect(breakfast.single.enabled, isTrue);
  });

  testWidgets('**关闭再保存时从规则里移除**（不留 enabled=false 的重复表示）', (tester) async {
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

    // 先开再关，然后保存。
    final row = find.widgetWithText(SwitchListTile, '早餐保护');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
    expect(
      resolved.rules.protectedTimes.where(
        (item) => item.kind.name == 'breakfast',
      ),
      isEmpty,
      reason:
          '关掉就是移除。留一条 `enabled: false` 的记录会让"关掉"与'
          '"从没开过"在数据上分叉，而下游只看 enabled 就会得到两种行为',
    );
  });

  testWidgets('**与睡眠重叠时阻止保存并指出重叠分钟**（不静默合并）', (tester) async {
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

    // 把工作日睡眠改成 23:30–08:00（默认结束时间是 07:30 附近，因此这里显式改）。
    await tester.enterText(find.byKey(const Key('weekday-sleep-end')), '08:00');
    await tester.enterText(
      find.byKey(const Key('weekday-sleep-start')),
      '23:30',
    );
    await tester.pumpAndSettle();

    final row = find.widgetWithText(SwitchListTile, '早餐保护');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(
      find.text('设置已保存'),
      findsNothing,
      reason: '计划 §2.4："早餐不与睡眠自动合并；两者重叠时**阻止保存**并指出冲突"',
    );
    expect(
      find.textContaining('重叠'),
      findsWidgets,
      reason:
          '只说"保存失败"用户不知道改哪一个；必须说出重叠了多少分钟'
          '（计划 Task 9 Step 3 的例子："早餐保护 07:30–08:00 与睡眠 23:30–08:00 重叠 30 分钟"）',
    );
    // 旧规则必须完整：被拦下的保存不得留下半条改动。
    final resolved = await service.resolveForDate(DateTime(2026, 10, 2));
    expect(
      resolved.rules.protectedTimes.where(
        (item) => item.kind.name == 'breakfast',
      ),
      isEmpty,
      reason: '被拦下的保存是**零写入**',
    );
  });

  testWidgets('编辑规则时报告未保存编辑，保存后清除（UPD-027 / UPD-028）', (tester) async {
    final service = SettingsService(repository: MemorySettingsRepository());
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanningRulesPage(
            service: service,
            localDate: DateTime(2026, 10, 2),
            updateSafety: safety,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 只是查看：不能误判成"有未保存编辑"。
    expect(safety.status.canInstall, isTrue);

    final field = find.byKey(const Key('weekday-daily-limit'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '300');
    await tester.pumpAndSettle();

    expect(safety.status.blockers, contains(UpdateBlocker.unsavedChanges));
    expect(safety.status.canInstall, isFalse);

    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(safety.status.canInstall, isTrue);
  });
}
