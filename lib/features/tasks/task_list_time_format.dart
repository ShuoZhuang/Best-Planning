// 任务清单上"时刻"的展示口径。
//
// **为什么单独成文件而不是写在页面里的私有函数**：清单卡片的文案由
// `task_list_filter.dart` 的纯函数拼装，而"13:00–14:30"这种字符串必须与那份纯逻辑
// 一起被测到——若格式器藏在 `_TaskListPageState` 里，文案测试就得先搭起整个页面。
//
// **为什么不是 `DateTime.toLocal()`**：那走的是**系统**时区，而应用自己解析出的
// 时区（`TimeZoneDatabase` + `timeZoneId`）可能与之不同。已有的今日页与周视图都把
// `toLocal` 作为可注入的函数收进来（见 `today_page.dart` 的 `toLocal` 字段），
// 这里沿用同一约定：页面不认识时区，换算由注入方负责。
import 'package:personal_planner/core/time_zone.dart';

/// 把"当前确认计划"里的一个块转成 `13:00–14:30` 这样的本地时间区间。
///
/// 没有 [zones] 时退回系统时区（`toLocal`）：测试与没有时区服务的装配下仍然可用，
/// 而生产装配总会传入。
String formatPlannedRange(
  DateTime startUtc,
  DateTime endUtc, {
  TimeZoneDatabase? zones,
  String? timeZoneId,
}) {
  final resolve = _resolver(zones, timeZoneId);
  return '${_clockTime(resolve(startUtc))}–${_clockTime(resolve(endUtc))}';
}

/// 截止时间的展示：`10月6日 23:59`。
///
/// 与"计划块"用同一套换算，因此同一个截止时间在详情页与清单页不会显示成两个钟点。
String formatTaskDue(
  DateTime dueAtUtc, {
  TimeZoneDatabase? zones,
  String? timeZoneId,
}) {
  final local = _resolver(zones, timeZoneId)(dueAtUtc);
  return '${local.month}月${local.day}日 ${_clockTime(local)}';
}

DateTime Function(DateTime instantUtc) _resolver(
  TimeZoneDatabase? zones,
  String? timeZoneId,
) {
  if (zones == null || timeZoneId == null) return (value) => value.toLocal();
  return (value) => zones.toLocal(value, timeZoneId);
}

String _clockTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
