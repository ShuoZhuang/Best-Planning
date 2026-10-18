// 自动更新总开关（规格 §7.2）。
//
// 这个开关只决定"是否自动联网"，不改变签名、验证、安装与回退的任何要求。它默认开启，
// 关闭后仍允许用户手动检查；手动发现更新后，用户可以显式开始下载。
//
// 键名带 `.v2`：旧版 `update.check.v1` 保存的是"自动检查"，语义与新开关不完全相同
// （旧版没有自动下载）。读取时做一次单向迁移，避免用户升上来之后被悄悄改成另一种行为。
import 'dart:convert';

import 'package:personal_planner/domain/repositories/settings_repository.dart';

const String updateSettingsStorageKey = 'update.native.v2';
const String legacyUpdateCheckSettingsKey = 'update.check.v1';

final class UpdateSettings {
  const UpdateSettings({this.autoUpdateEnabled = true});

  /// 自动检查并自动下载。默认开启（规格 §7.2）。
  final bool autoUpdateEnabled;

  UpdateSettings copyWith({bool? autoUpdateEnabled}) => UpdateSettings(
    autoUpdateEnabled: autoUpdateEnabled ?? this.autoUpdateEnabled,
  );
}

abstract interface class UpdateSettingsStore {
  Future<UpdateSettings> load();

  Future<void> save(UpdateSettings settings);
}

final class JsonUpdateSettingsStore implements UpdateSettingsStore {
  const JsonUpdateSettingsStore({required this.settings});

  final SettingsRepository settings;

  @override
  Future<UpdateSettings> load() async {
    try {
      final raw = await settings.read(updateSettingsStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw);
        if (json is Map && json['autoUpdateEnabled'] is bool) {
          return UpdateSettings(
            autoUpdateEnabled: json['autoUpdateEnabled'] as bool,
          );
        }
      }
      // 迁移：旧键存在时沿用用户的"自动检查"选择；缺失则保持默认开启。
      final legacy = await settings.read(legacyUpdateCheckSettingsKey);
      if (legacy != null && legacy.isNotEmpty) {
        final json = jsonDecode(legacy);
        if (json is Map && json['autoCheckEnabled'] is bool) {
          return UpdateSettings(
            autoUpdateEnabled: json['autoCheckEnabled'] as bool,
          );
        }
      }
      return const UpdateSettings();
    } on Object {
      // 设置读不出来只该回默认（开启），不该让更新页打不开。
      return const UpdateSettings();
    }
  }

  @override
  Future<void> save(UpdateSettings settings) => this.settings.write(
    updateSettingsStorageKey,
    jsonEncode({'autoUpdateEnabled': settings.autoUpdateEnabled}),
  );
}
