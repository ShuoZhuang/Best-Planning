// 图表类型选择：可选项按数据形状给、非法值回落默认、非法组合拒绝写入。
//
// 用户要求"各个统计的图表类型可以由我来选择"。这里钉住三件容易做错的事：
// ① 占比类不给折线、时间类不给饼图（给得出但看不懂不算自由）；
// ② 设置被手改坏时回默认而不是崩；
// ③ 写入前校验该位置是否允许该类型。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_chart_preference_service.dart';
import 'package:personal_planner/domain/models/chart_kind.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

/// 内存设置仓储，读失败与写失败都可由用例控制。
final class _Settings implements SettingsRepository {
  _Settings([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  test('每个位置都给了允许类型，且默认值一定在允许集合里', () {
    for (final slot in AnalyticsChartSlot.values) {
      expect(slot.allowedKinds, isNotEmpty, reason: '${slot.name} 没有允许类型');
      expect(
        slot.allowedKinds,
        contains(slot.defaultKind),
        reason: '${slot.name} 的默认值不在允许集合里',
      );
      // 同一位置不重复列同一个类型。
      expect(
        slot.allowedKinds.toSet(),
        hasLength(slot.allowedKinds.length),
        reason: '${slot.name} 的允许类型里有重复',
      );
    }
  });

  test('占比类不给折线，时间序列不给饼图', () {
    // "领域占比"是在比构成，折线会让人以为它在讲趋势。
    expect(
      AnalyticsChartSlot.areaShare.allowedKinds,
      isNot(contains(ChartKind.line)),
    );
    // 时间序列画成饼图没有意义。
    expect(
      AnalyticsChartSlot.periodTotal.allowedKinds,
      isNot(contains(ChartKind.pie)),
    );
    // 占比确实可以画饼图。
    expect(AnalyticsChartSlot.areaShare.allowedKinds, contains(ChartKind.pie));
  });

  test('没选过的位置回落到该位置的默认类型，而不是抛', () {
    expect(
      resolveChartKind(AnalyticsChartSlot.areaShare, null),
      AnalyticsChartSlot.areaShare.defaultKind,
    );
    expect(
      resolveChartKind(AnalyticsChartSlot.routine, const {}),
      AnalyticsChartSlot.routine.defaultKind,
    );
  });

  test('选过且合法的位置用用户的选择', () {
    expect(
      resolveChartKind(AnalyticsChartSlot.areaShare, const {
        AnalyticsChartSlot.areaShare: ChartKind.horizontalBar,
      }),
      ChartKind.horizontalBar,
    );
  });

  test('保存之后能读回来', () async {
    final settings = _Settings();
    final service = AnalyticsChartPreferenceService(settings: settings);

    await service.save(AnalyticsChartSlot.areaShare, ChartKind.bar);
    await service.save(AnalyticsChartSlot.periodTotal, ChartKind.line);

    final loaded = await service.load();
    expect(loaded[AnalyticsChartSlot.areaShare], ChartKind.bar);
    expect(loaded[AnalyticsChartSlot.periodTotal], ChartKind.line);
    // 没选过的位置不出现在结果里——默认值将来变时它会跟着变。
    expect(loaded.containsKey(AnalyticsChartSlot.routine), isFalse);
  });

  test('写入不合法的类型会被拒绝，且不改动已有选择', () async {
    final settings = _Settings();
    final service = AnalyticsChartPreferenceService(settings: settings);
    await service.save(AnalyticsChartSlot.areaShare, ChartKind.horizontalBar);

    // 占比类不支持折线。
    await expectLater(
      service.save(AnalyticsChartSlot.areaShare, ChartKind.line),
      throwsArgumentError,
    );
    final loaded = await service.load();
    expect(loaded[AnalyticsChartSlot.areaShare], ChartKind.horizontalBar);
  });

  test('设置被手改坏时回默认，而不是让统计页打不开', () async {
    final settings = _Settings({
      AnalyticsChartPreferenceService.storageKey: '{not json',
    });
    final service = AnalyticsChartPreferenceService(settings: settings);
    expect(await service.load(), isEmpty);
  });

  test('设置里出现不存在的类型名或对该位置不合法的类型时跳过它', () async {
    final settings = _Settings({
      AnalyticsChartPreferenceService.storageKey: jsonEncode({
        'areaShare': 'pie', // 合法
        'periodTotal': 'pie', // 该位置不允许饼图
        'routine': 'sankey', // 根本不存在的类型
        'notASlot': 'bar', // 不存在的位置
      }),
    });
    final service = AnalyticsChartPreferenceService(settings: settings);

    final loaded = await service.load();
    expect(loaded, hasLength(1));
    expect(loaded[AnalyticsChartSlot.areaShare], ChartKind.pie);
    // 不合法的两项各自回落到各自位置的默认值。
    expect(
      resolveChartKind(AnalyticsChartSlot.periodTotal, loaded),
      AnalyticsChartSlot.periodTotal.defaultKind,
    );
    expect(
      resolveChartKind(AnalyticsChartSlot.routine, loaded),
      AnalyticsChartSlot.routine.defaultKind,
    );
  });
}
