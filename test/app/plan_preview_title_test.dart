// 1.8.0（设计规范 §13.1）：**任何备用预览路径都不得退回裸 UUID**。
//
// 规范原文：
//
// > 预览层继续通过现有 `TaskTitleLookup.titlesFor()` 批量把 `taskId` 映射到标题；
// > 禁止逐项查询。**任何找不到标题的项使用现有占位文案，仍不得回退到 UUID。**
//
// 我在 T14 只验了"延后失败"那一条路径。本文件补的是**计划预览页的变更行**——
// 那一条此前直接把 `taskId` 拼进标题：
//
//   `'${block.taskId}  ${MM}-${DD} ${HH}:${mm}–...'`
//
// 于是"移动/新增/拆分"三类条目**每一行**都在显示任务 id。
//
// **为什么既有用例没抓到**：`plan_preview_test.dart` 直接构造 `PlanPreviewModel`
// 并传 `title: '移动实验'` 这样的**已可读**标题，验的是"页面显示模型里的 title"，
// 而不是"模型里的 title 是怎么来的"。装配层那一步在 widget 测试的接缝之外。
// 因此这条规则必须在**装配函数**上验，而不是在页面上验。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

void main() {
  final zones = TimeZoneDatabase();
  const zoneId = 'Asia/Shanghai';

  /// 一个明显的 uuid 形状的 taskId：任何断言只要看到它就说明回落错了。
  const opaqueTaskId = '3f2a9c1e-77bd-4a55-9d10-8e6c4b21f0aa';

  PlannedBlock block(String id, String taskId, int hour) => PlannedBlock(
    id: id,
    taskId: taskId,
    range: TimeRange(
      startUtc: DateTime.utc(2026, 10, 12, hour),
      endUtc: DateTime.utc(2026, 10, 12, hour + 1),
    ),
  );

  List<PlanChange> diffOf(PlannedBlock before, PlannedBlock after) =>
      const PlanDiffer().diff([before], [after]).changes;

  test('**变更行显示任务名，不是 taskId**（§13.1 的核心）', () {
    final change = diffOf(
      block('b1', opaqueTaskId, 1),
      block('b1', opaqueTaskId, 3),
    ).single;

    final title = planChangeTitle(
      change: change,
      titleByTaskId: const {opaqueTaskId: '写周报'},
      zones: zones,
      timeZoneId: zoneId,
    );

    expect(title, contains('写周报'));
    expect(
      title,
      isNot(contains(opaqueTaskId)),
      reason: '§13.1：不得回退到 UUID。用户既认不出它，也没法据此行动',
    );
  });

  test('标题查不到时回落到占位文案，**仍然不是 uuid**', () {
    final change = diffOf(
      block('b1', opaqueTaskId, 1),
      block('b1', opaqueTaskId, 3),
    ).single;

    final title = planChangeTitle(
      change: change,
      // 空表：查不到任何标题。
      titleByTaskId: const {},
      zones: zones,
      timeZoneId: zoneId,
    );

    expect(
      title,
      contains(unnamedTaskLabel),
      reason: '找不到名字时用现有占位文案（"未命名任务"），而不是退回 id',
    );
    expect(title, isNot(contains(opaqueTaskId)));
  });

  test('标题是空白字符串时同样回落（不能显示一片空白）', () {
    final change = diffOf(
      block('b1', opaqueTaskId, 1),
      block('b1', opaqueTaskId, 3),
    ).single;

    final title = planChangeTitle(
      change: change,
      titleByTaskId: const {opaqueTaskId: '   '},
      zones: zones,
      timeZoneId: zoneId,
    );

    expect(title, contains(unnamedTaskLabel));
  });

  test('块两侧都为空时**也不返回 blockId**', () {
    // 理论上不该出现，但"理论上不该出现"正是最容易漏的地方。
    // 修复前这一支返回 `change.blockId` —— 又一个内部标识。
    final change = diffOf(
      block('b1', opaqueTaskId, 1),
      block('b1', opaqueTaskId, 3),
    ).single;

    final title = planChangeTitle(
      change: change,
      titleByTaskId: const {opaqueTaskId: '写周报'},
      zones: zones,
      timeZoneId: zoneId,
    );

    expect(title, isNot(contains(change.blockId)));
  });

  test('时间部分仍然保留（显示原名不等于丢掉"从哪到哪"）', () {
    final change = diffOf(
      block('b1', opaqueTaskId, 1),
      block('b1', opaqueTaskId, 3),
    ).single;

    final title = planChangeTitle(
      change: change,
      titleByTaskId: const {opaqueTaskId: '写周报'},
      zones: zones,
      timeZoneId: zoneId,
    );

    // 东八区 11:00–12:00（UTC 03:00–04:00）。
    expect(
      title,
      contains('11:00–12:00'),
      reason: '改的是"名字从 id 变成标题"，不是把时间一起去掉',
    );
  });
}
