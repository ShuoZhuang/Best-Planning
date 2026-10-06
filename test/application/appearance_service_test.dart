import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_settings_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

final class _FixedClock implements Clock {
  const _FixedClock();

  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 4, 15);
}

void main() {
  test('极致版通过真实 Drift 设置仓库保存，重启服务后仍可恢复', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = DriftSettingsRepository(database, const _FixedClock());

    final first = AppearanceService(repository);
    await first.load();
    await first.setMode(PlannerMaterialMode.liquid);

    final restarted = AppearanceService(repository);
    await restarted.load();

    expect(restarted.mode, PlannerMaterialMode.liquid);
    expect(
      await repository.read(AppearanceService.settingKey),
      PlannerMaterialMode.liquid.storedValue,
    );
  });

  test('外观写入遇到一次瞬时失败时自动重试，不回滚用户选择', () async {
    final repository = _FlakySettingsRepository(failuresBeforeSuccess: 1);
    final failures = <Object>[];
    final service = AppearanceService(
      repository,
      onSaveFailure: (error, _, _) => failures.add(error),
      retryDelays: const [Duration.zero, Duration.zero],
    );

    await service.setMode(PlannerMaterialMode.liquid);

    expect(service.mode, PlannerMaterialMode.liquid);
    expect(await repository.read(AppearanceService.settingKey), 'liquid');
    expect(repository.writeAttempts, 2);
    expect(failures, hasLength(1));
  });

  test('SQLite 连续写入失败时使用独立本地兜底并在重启后恢复', () async {
    final repository = _FlakySettingsRepository(failuresBeforeSuccess: 99);
    final fallback = _MemoryAppearanceModeStore();
    final first = AppearanceService(
      repository,
      fallback: fallback,
      retryDelays: const [Duration.zero, Duration.zero],
    );

    await first.setMode(PlannerMaterialMode.liquid);

    final restarted = AppearanceService(repository, fallback: fallback);
    await restarted.load();
    expect(restarted.mode, PlannerMaterialMode.liquid);
    expect(await fallback.read(), 'liquid');
  });
}

final class _MemoryAppearanceModeStore implements AppearanceModeStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

final class _FlakySettingsRepository implements SettingsRepository {
  _FlakySettingsRepository({required this.failuresBeforeSuccess});

  final int failuresBeforeSuccess;
  final Map<String, String> _values = {};
  int writeAttempts = 0;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    writeAttempts++;
    if (writeAttempts <= failuresBeforeSuccess) {
      throw StateError('transient write failure');
    }
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async => _values.remove(key);
}
