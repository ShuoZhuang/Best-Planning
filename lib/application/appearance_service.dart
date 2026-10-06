import 'package:flutter/foundation.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

enum PlannerMaterialMode { off, restrained, aggressive, liquid }

extension PlannerMaterialModeValue on PlannerMaterialMode {
  String get storedValue => switch (this) {
    PlannerMaterialMode.off => 'off',
    PlannerMaterialMode.restrained => 'restrained',
    PlannerMaterialMode.aggressive => 'aggressive',
    PlannerMaterialMode.liquid => 'liquid',
  };

  static PlannerMaterialMode fromStored(String? value) => switch (value) {
    'off' => PlannerMaterialMode.off,
    'aggressive' => PlannerMaterialMode.aggressive,
    'liquid' => PlannerMaterialMode.liquid,
    _ => PlannerMaterialMode.restrained,
  };
}

typedef AppearanceSaveFailureReporter = void Function(
  Object error,
  StackTrace stackTrace,
  int attempt,
);

abstract interface class AppearanceModeStore {
  Future<String?> read();

  Future<void> write(String value);
}

final class AppearanceService extends ChangeNotifier {
  AppearanceService(
    this._repository, {
    this.onSaveFailure,
    this.fallback,
    this.retryDelays = const [
      Duration(milliseconds: 80),
      Duration(milliseconds: 200),
    ],
  });

  static const settingKey = 'appearance.glass-mode';

  final SettingsRepository _repository;
  final AppearanceSaveFailureReporter? onSaveFailure;
  final AppearanceModeStore? fallback;
  final List<Duration> retryDelays;
  PlannerMaterialMode _mode = PlannerMaterialMode.restrained;

  PlannerMaterialMode get mode => _mode;

  Future<void> load() async {
    String? stored;
    final fallbackStore = fallback;
    if (fallbackStore != null) {
      try {
        stored = await fallbackStore.read();
      } catch (error, stackTrace) {
        onSaveFailure?.call(error, stackTrace, 0);
      }
    }
    stored ??= await _repository.read(settingKey);
    final loaded = PlannerMaterialModeValue.fromStored(stored);
    if (loaded == _mode) return;
    _mode = loaded;
    notifyListeners();
  }

  Future<void> setMode(PlannerMaterialMode value) async {
    if (value == _mode) return;
    final previous = _mode;
    _mode = value;
    notifyListeners();
    Object? lastError;
    StackTrace? lastStackTrace;
    var repositorySaved = false;
    for (var attempt = 0; ; attempt++) {
      try {
        await _repository.write(settingKey, value.storedValue);
        repositorySaved = true;
        break;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        onSaveFailure?.call(error, stackTrace, attempt + 1);
        if (attempt >= retryDelays.length) {
          break;
        }
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
    var fallbackSaved = false;
    final fallbackStore = fallback;
    if (fallbackStore != null) {
      try {
        await fallbackStore.write(value.storedValue);
        fallbackSaved = true;
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        onSaveFailure?.call(error, stackTrace, retryDelays.length + 2);
      }
    }
    if (repositorySaved || fallbackSaved) return;

    _mode = previous;
    notifyListeners();
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }
}
