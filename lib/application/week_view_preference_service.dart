import 'package:personal_planner/domain/repositories/settings_repository.dart';

/// 七日日历的展示模式。
///
/// **紧凑模式是默认**：§9 明确要求"紧凑模式保留，不能强迫用户接受时间轴密度"，
/// 因此默认值必须是 `compact`——老用户升级后看到的界面不该突然变样。
enum WeekViewMode {
  /// 现有卡片模式（每个事项一张等高卡片）。
  compact,

  /// 按真实时间比例排列的时间轴。
  timeline,
}

/// 记住用户在本机选的展示模式（§9："记住本机选择"）。
///
/// 与 `AnalyticsChartPreferenceService` 同一形状（`SettingsRepository` + 读失败回默认）：
/// 设置文件可能来自旧版本、被手改过或写坏，**读失败一律回默认**，而不是让日历打不开。
final class WeekViewPreferenceService {
  const WeekViewPreferenceService({required this.settings});

  static const String storageKey = 'calendar.weekViewMode.v1';

  final SettingsRepository settings;

  /// 读出用户选过的模式；没选过或值不认识时回 [WeekViewMode.compact]。
  Future<WeekViewMode> load() async {
    try {
      final raw = await settings.read(storageKey);
      if (raw == null || raw.isEmpty) return WeekViewMode.compact;
      // 只认确实存在的枚举名——旧版本写下的名字、或被手改的值都当作没选过。
      for (final mode in WeekViewMode.values) {
        if (mode.name == raw) return mode;
      }
      return WeekViewMode.compact;
    } on Object {
      return WeekViewMode.compact;
    }
  }

  /// 保存选择。写失败不抛：模式已经生效在界面上，为一次设置写入失败把页面打崩不值得
  /// （与 `AnalyticsChartPreferenceService` 同一取舍）。
  Future<void> save(WeekViewMode mode) async {
    try {
      await settings.write(storageKey, mode.name);
    } on Object {
      // 忽略：下次进入会回到默认模式，但界面不会因此崩掉。
    }
  }
}
