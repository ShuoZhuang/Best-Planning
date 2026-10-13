import 'package:personal_planner/domain/models/planning_rules.dart';

/// 保护时间类别的**唯一**用户文案（日历与预览共用）。
///
/// 为什么必须只有一份：它此前散在 `schedule_view_source._protectedLabel`（按 id 字符串
/// 推断、且漏了 breakfast）与 `plan_preview_page._protectedLabel`（typed，但只覆盖预览）
/// 两处，于是同一个类别在两个页面显示不同的话。
///
/// **数据层不 import 本文件**（`lib/data/` 不得反向依赖界面层）：`AnalyticsDao` 继续把
/// 统计窗口投影成字符串标签，两边的映射由契约测试保证一致（见计划 §2.5）。
String protectedTimeKindLabel(ProtectedTimeKind kind) => switch (kind) {
  ProtectedTimeKind.breakfast => '早餐',
  ProtectedTimeKind.lunch => '午餐',
  ProtectedTimeKind.dinner => '晚餐',
  ProtectedTimeKind.fixedRest => '固定休息',
};
