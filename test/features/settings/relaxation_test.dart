// FR-REPLAN-07 的"临时放宽每日上限"处理入口。
//
// **此前这条入口在真实用户路径上不存在**：`SettingsService.saveDateOverride` 是既有的写入
// 方法，但全库**没有任何调用方**（§13.0 的 C8 记录里它是"唯一写入方"，而那一处写入在 C8
// 修复时被改成提案输入，于是它连一个调用方都没有了）。没有入口的后果是"临时例外"这一层
// 需求 §8.4.1 里排在最优先级的规则——从来没有被用户碰过。
//
// 本文件钉住三件事：
// 1. **只作用于那一天**：例外不得改动长期规则，也不得影响相邻日期；
// 2. **可清除**：C8 的原缺陷正是"有写入方、没有任何清除路径"，放宽的是硬约束，
//    留下一个清不掉的放宽比没有这条入口更糟；
// 3. **可读回**：界面上要能显示"这一天被放宽成了多少"，否则用户只能靠猜（`loadDateOverride`）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/settings/relaxation/relaxation_page.dart';

void main() {
  final day = DateTime(2026, 10, 5);
  final nextDay = DateTime(2026, 10, 6);

  group('设置层', () {
    late SettingsService settings;

    setUp(() => settings = SettingsService(repository: MemorySettingsRepository()));

    Future<int> limitOn(DateTime date) async =>
        (await settings.resolveForDate(date)).rules.dailyMovableTaskLimitMinutes;

    test('放宽只作用于那一天，长期规则与相邻日期都不变', () async {
      final before = await limitOn(day);

      await settings.saveDateOverride(
        day,
        PlanningRulesPatch(dailyMovableTaskLimitMinutes: before + 120),
      );

      expect(await limitOn(day), before + 120);
      expect(
        await limitOn(nextDay),
        before,
        reason: '临时例外不得扩散到相邻日期——那是"永久修改"而不是"临时放宽"',
      );
    });

    test('读取能拿回放宽后的值，未放宽的日子返回 null', () async {
      expect(await settings.loadDateOverride(day), isNull);

      await settings.saveDateOverride(
        day,
        const PlanningRulesPatch(dailyMovableTaskLimitMinutes: 300),
      );

      expect(
        (await settings.loadDateOverride(day))?.dailyMovableTaskLimitMinutes,
        300,
      );
      expect(await settings.loadDateOverride(nextDay), isNull);
    });

    test('清除之后那一天回到常规上限', () async {
      final before = await limitOn(day);
      await settings.saveDateOverride(
        day,
        PlanningRulesPatch(dailyMovableTaskLimitMinutes: before + 120),
      );
      expect(await limitOn(day), before + 120);

      await settings.clearDateOverride(day);

      expect(await limitOn(day), before);
      expect(await settings.loadDateOverride(day), isNull);
    });

    test('清除一个从未放宽过的日子不报错（幂等）', () async {
      await settings.clearDateOverride(day);

      expect(await settings.loadDateOverride(day), isNull);
    });
  });

  group('页面', () {
    Future<void> pump(
      WidgetTester tester, {
      required int effective,
      int? overrideMinutes,
      required Future<bool> Function(int) onSave,
      required Future<bool> Function() onClear,
    }) => tester.pumpWidget(
      MaterialApp(
        home: RelaxationPage(
          localDate: day,
          loadEffectiveLimitMinutes: () async => effective,
          loadOverrideMinutes: () async => overrideMinutes,
          onSave: onSave,
          onClear: onClear,
        ),
      ),
    );

    testWidgets('显示出目标日期与当前生效上限，并预填该值', (tester) async {
      await pump(
        tester,
        effective: 240,
        onSave: (_) async => true,
        onClear: () async => true,
      );
      await tester.pumpAndSettle();

      expect(find.text('2026 年 10 月 5 日'), findsOneWidget);
      expect(find.textContaining('当前上限 240 分钟'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const Key('relaxation-minutes'))).controller!.text,
        '240',
        reason: '预填当前生效值，用户只需在它基础上加；从空开始会让人先删再输',
      );
    });

    testWidgets('未放宽过时"清除"不可点（不给一个作用不到任何对象的按钮）', (tester) async {
      await pump(
        tester,
        effective: 240,
        onSave: (_) async => true,
        onClear: () async => true,
      );
      await tester.pumpAndSettle();

      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('relaxation-clear')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('已放宽过时显示放宽值，"清除"可点并真的调用', (tester) async {
      var cleared = 0;
      await pump(
        tester,
        effective: 360,
        overrideMinutes: 360,
        onSave: (_) async => true,
        onClear: () async {
          cleared++;
          return true;
        },
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('已临时放宽为 360 分钟'), findsOneWidget);
      await tester.tap(find.byKey(const Key('relaxation-clear')));
      await tester.pumpAndSettle();

      expect(cleared, 1);
      expect(find.text('已恢复这一天的常规上限'), findsOneWidget);
    });

    testWidgets('保存把用户填的分钟数交给注入方', (tester) async {
      final saved = <int>[];
      await pump(
        tester,
        effective: 240,
        onSave: (minutes) async {
          saved.add(minutes);
          return true;
        },
        onClear: () async => true,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('relaxation-minutes')), '420');
      await tester.tap(find.byKey(const Key('relaxation-save')));
      await tester.pumpAndSettle();

      expect(saved, <int>[420]);
    });

    testWidgets('非整数与非正值都留在页面上说明，不交给注入方', (tester) async {
      final saved = <int>[];
      await pump(
        tester,
        effective: 240,
        onSave: (minutes) async {
          saved.add(minutes);
          return true;
        },
        onClear: () async => true,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('relaxation-minutes')), 'abc');
      await tester.tap(find.byKey(const Key('relaxation-save')));
      await tester.pumpAndSettle();
      expect(find.text('请输入一个整数分钟数'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('relaxation-minutes')), '0');
      await tester.tap(find.byKey(const Key('relaxation-save')));
      await tester.pumpAndSettle();
      expect(find.text('放宽后的上限必须大于 0 分钟'), findsOneWidget);

      expect(saved, isEmpty);
    });

    testWidgets('保存失败时如实说明，不谎报成功', (tester) async {
      await pump(
        tester,
        effective: 240,
        onSave: (_) async => false,
        onClear: () async => true,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('relaxation-save')));
      await tester.pumpAndSettle();

      expect(find.text('保存失败'), findsOneWidget);
    });
  });
}
