// Task 12A Step 6（用户 2026-10-08 的接口决定）：预览显示标题与结构化原因，不显示裸 UUID。
//
// 这个文件钉住那五条实施约束里属于展示侧的三条：
//
// 1. 标题由 `TaskTitleLookup` 提供，**查不到时回落"未命名任务"，绝不回落裸 UUID**；
// 2. 预览只**翻译**引擎给的原因，不自己推测（`unscheduledReasonLabel` 的入参就是
//    `UnscheduledReason`，拿不到任务属性，因此"猜"在类型上就做不到）；
// 3. 同一条缺口在"未安排"与"冲突"两组里必须叫同一个名字。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/repositories/task_title_lookup.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 一个可编程的标题来源。`known` 里没有的 id 返回 `null`——模拟"任务已被删除"。
final class _Lookup implements TaskTitleLookup {
  _Lookup(this.known);

  final Map<String, String> known;
  final List<List<String>> batchCalls = [];

  @override
  Future<String?> titleFor(String taskId) async => known[taskId];

  @override
  Future<Map<String, String>> titlesFor(Iterable<String> taskIds) async {
    final ids = taskIds.toList();
    batchCalls.add(ids);
    return {
      for (final id in ids)
        if (known[id] != null) id: known[id]!,
    };
  }
}

void main() {
  group('标题解析：绝不回落裸 UUID', () {
    test('查得到就用真名', () async {
      final infos = await resolveTaskDisplayInfos(
        _Lookup({'task-1': '贫困生材料提交'}),
        ['task-1'],
      );

      expect(infos.single.title, '贫困生材料提交');
    });

    test('查不到 ⇒ 未命名任务（不是空串、更不是 id）', () async {
      final infos = await resolveTaskDisplayInfos(_Lookup(const {}), ['ghost']);

      expect(infos.single.title, unnamedTaskLabel);
      expect(
        infos.single.title,
        isNot(contains('ghost')),
        reason: '裸 UUID 对用户毫无意义，而空串会让他不知道那里本该有字',
      );
    });

    test('标题只有空白 ⇒ 同样回落到未命名任务', () async {
      final infos = await resolveTaskDisplayInfos(_Lookup({'task-1': '   '}), [
        'task-1',
      ]);

      expect(infos.single.title, unnamedTaskLabel);
    });

    test('标题两侧空白被去掉（用户很容易多打一个空格）', () async {
      final infos = await resolveTaskDisplayInfos(
        _Lookup({'task-1': '  每周英语  '}),
        ['task-1'],
      );

      expect(infos.single.title, '每周英语');
    });

    test('用批量接口，而且是**一次**调用（不是逐条查）', () async {
      final lookup = _Lookup({'a': 'A', 'b': 'B', 'c': 'C'});
      await resolveTaskDisplayInfos(lookup, ['a', 'b', 'c']);

      expect(
        lookup.batchCalls,
        hasLength(1),
        reason: '逐条查询在真实数据库上就是 N 次往返，列表长度由用户的任务数决定',
      );
      expect(lookup.batchCalls.single, hasLength(3));
    });

    test('空输入不发起查询', () async {
      final lookup = _Lookup(const {});
      expect(await resolveTaskDisplayInfos(lookup, const []), isEmpty);
      expect(lookup.batchCalls, isEmpty);
    });

    test('重复 id 只查一次', () async {
      final lookup = _Lookup({'a': 'A'});
      final infos = await resolveTaskDisplayInfos(lookup, ['a', 'a', 'a']);

      expect(infos, hasLength(1));
      expect(lookup.batchCalls.single, hasLength(1));
    });
  });

  group('原因翻译：只说引擎给的那一条，不推测', () {
    test('连续空档不足带上"需要/可用"两个数字', () {
      final label = unscheduledReasonLabel(
        const UnscheduledReason(
          code: UnscheduledReasonCode.continuousGapTooShort,
          requiredMinutes: 30,
          availableMinutes: 20,
        ),
      );

      expect(label, contains('30'));
      expect(label, contains('20'));
    });

    test('缺少数字时不编造数字', () {
      final label = unscheduledReasonLabel(
        const UnscheduledReason(code: UnscheduledReasonCode.dailyLimitReached),
      );

      expect(label, isNotEmpty);
      expect(RegExp(r'\d').hasMatch(label), isFalse);
    });

    test('枚举里的每一个取值都能翻出一句非空的话', () {
      // 漏一个的后果是那种原因在界面上显示成空行，而用户看到的是"这里什么都没说"。
      for (final code in UnscheduledReasonCode.values) {
        final label = unscheduledReasonLabel(UnscheduledReason(code: code));
        expect(label.trim(), isNotEmpty, reason: '$code 没有对应文案');
      }
    });
  });

  group('页面上不出现裸 UUID', () {
    Future<void> pump(WidgetTester tester, PlanPreviewModel model) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanPreviewPage(
              model: model,
              autoAdjustStore: MemoryAutoAdjustStore(),
              onConfirm: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('未安排那一行显示标题与主原因，而不是 id', (tester) async {
      const uuid = '3f1c9a4e-7b2d-4c8f-9a11-0d5e6b7c8d9e';
      await pump(
        tester,
        PlanPreviewModel(
          proposalId: 'p1',
          changes: [
            const PreviewChange(
              kind: PreviewChangeKind.unplanned,
              title: '贫困生材料提交 还缺 15 分钟',
              reason: '这件事需要一次做完：需要 30 分钟，可用 20 分钟。',
            ),
          ],
          conflicts: const ['「贫困生材料提交」还缺 15 分钟'],
          isStale: false,
        ),
      );

      expect(find.textContaining('贫困生材料提交'), findsWidgets);
      // 这一条是关键：整个渲染树里不得出现那串 UUID。
      expect(
        find.textContaining(uuid),
        findsNothing,
        reason: '裸 UUID 是这一步要消灭的东西',
      );
    });
  });
}
