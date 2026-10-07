import 'dart:convert';

import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

/// 统计页每张卡片选的可视化类型，持久在设置键 `analytics.chartTypes.v1`。
///
/// 与 `ScheduleColorService` 同一形状（`SettingsRepository` + JSON + 读失败回默认）：设置文件
/// 可能来自旧版本、被手改过或写坏，**读失败一律回默认值**，而不是让统计页打不开。
final class AnalyticsChartPreferenceService {
  const AnalyticsChartPreferenceService({required this.settings});

  static const String storageKey = 'analytics.chartTypes.v1';

  final SettingsRepository settings;

  /// 读出用户选过的类型。未选过的位置**不出现在结果里**——由 `resolveChartKind` 补默认，
  /// 这样默认值将来变了，没选过的卡片会跟着变，而不是被一份陈旧快照钉住。
  Future<Map<AnalyticsChartSlot, ChartKind>> load() async {
    try {
      final raw = await settings.read(storageKey);
      if (raw == null || raw.isEmpty) return const {};
      final json = jsonDecode(raw);
      if (json is! Map) return const {};
      final result = <AnalyticsChartSlot, ChartKind>{};
      for (final slot in AnalyticsChartSlot.values) {
        final value = json[slot.storageKey];
        if (value is! String) continue;
        // 只认这个名字确实存在的类型；同时**检查它对该位置是否合法**——不合法就当作没选过。
        final kind = ChartKind.values
            .where((item) => item.name == value)
            .firstOrNull;
        if (kind == null || !slot.allowedKinds.contains(kind)) continue;
        result[slot] = kind;
      }
      return result;
    } on Object {
      return const {};
    }
  }

  /// 保存一个位置的选择。
  ///
  /// **校验该位置是否允许这个类型**：与 `ScheduleColorService.setSpecialColor` 校验颜色必须不透明
  /// 同一理由——把一个界面根本画不出来的组合写进设置，就是给下次打开埋一个坑。
  Future<void> save(AnalyticsChartSlot slot, ChartKind kind) async {
    if (!slot.allowedKinds.contains(kind)) {
      throw ArgumentError.value(kind, 'kind', '${slot.name} 不支持 ${kind.name}');
    }
    final current = await load();
    final updated = {...current, slot: kind};
    await settings.write(
      storageKey,
      jsonEncode({
        for (final entry in updated.entries)
          entry.key.storageKey: entry.value.name,
      }),
    );
  }
}
