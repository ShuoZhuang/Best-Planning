import 'dart:convert';

import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/scheduling/extension_day_policy.dart';

/// 持久化的延长日拒绝记忆（算法 20，ALG20-049）。
///
/// 键里已经包含输入哈希与候选参数，因此任务、截止、日程或规则变化后哈希改变，
/// 同一建议会重新出现；只有**相同输入**下的相同建议被抑制。
final class SettingsExtensionRejectionStore implements ExtensionRejectionStore {
  SettingsExtensionRejectionStore(this.repository);

  static const String storageKey = 'planning.extensionRejections.v1';

  final SettingsRepository repository;

  @override
  Future<bool> isRejected(String key) async {
    final keys = await _load();
    return keys.contains(key);
  }

  @override
  Future<void> rememberRejected(String key) async {
    final keys = await _load()
      ..add(key);
    await repository.write(storageKey, jsonEncode(keys.toList()..sort()));
  }

  Future<Set<String>> _load() async {
    final raw = await repository.read(storageKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return {
          for (final item in decoded)
            if (item is String) item,
        };
      }
    } on FormatException {
      // 损坏的记忆不应让页面打不开；当作"没有拒绝过"。
    }
    return <String>{};
  }
}
