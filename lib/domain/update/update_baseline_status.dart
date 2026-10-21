// 回退基线准备的显式状态（1.11.1 事故修复 §4.4 / §6）。
//
// 1.11.0 只用 `rollbackNotReady` 一个布尔量推断基线是否可用：文件存在但不完整、失败后没有
// 重试计划、成功后又没有清除阻塞，都表现为同一个"未就绪"，用户于是永久卡在
// `UPDATE_BLOCKED_ROLLBACK_NOT_READY`。这里把基线准备做成**独立子状态**：
// 它有阶段、尝试次数、下次重试时间与最近失败，并且可以单独被界面观察与重试。
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/rollback_baseline.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';

/// 基线准备阶段。
enum BaselinePhase {
  /// 还没有可用基线，也没有正在进行的任务。
  absent('absent'),

  /// 正在下载/校验基线包。
  preparing('preparing'),

  /// 当前已安装版本的回退包已通过完整校验。
  ready('ready'),

  /// 上次失败，等待退避时间或用户点击重试。
  retryWaiting('retryWaiting'),

  /// 不可自动恢复的失败（签名/身份/来源），只能由新版本或人工介入解决。
  failed('failed');

  const BaselinePhase(this.wireName);

  final String wireName;

  static BaselinePhase? fromWireName(Object? name) {
    if (name is! String) return null;
    for (final phase in BaselinePhase.values) {
      if (phase.wireName == name) return phase;
    }
    return null;
  }

  bool get isReady => this == BaselinePhase.ready;

  bool get isBusy => this == BaselinePhase.preparing;
}

/// 基线准备的持久化子状态。
final class BaselinePreparationState {
  const BaselinePreparationState({
    this.phase = BaselinePhase.absent,
    this.requiredForInstalledVersion,
    this.attempt = 0,
    this.nextAttemptUtc,
    this.lastFailure,
  });

  final BaselinePhase phase;

  /// 该基线是为哪个已安装版本准备的。升级后不等于当前已安装版本时视为过期。
  final MsixVersion? requiredForInstalledVersion;

  final int attempt;

  final DateTime? nextAttemptUtc;

  final UpdateFailure? lastFailure;

  bool get isReady => phase.isReady;

  bool get canAutoRetry {
    if (phase != BaselinePhase.retryWaiting) return false;
    final next = nextAttemptUtc;
    return next == null || !DateTime.now().toUtc().isBefore(next);
  }

  BaselinePreparationState copyWith({
    BaselinePhase? phase,
    MsixVersion? requiredForInstalledVersion,
    int? attempt,
    DateTime? nextAttemptUtc,
    UpdateFailure? lastFailure,
    bool clearNextAttempt = false,
    bool clearFailure = false,
    bool clearRequiredVersion = false,
  }) => BaselinePreparationState(
    phase: phase ?? this.phase,
    requiredForInstalledVersion: clearRequiredVersion
        ? null
        : (requiredForInstalledVersion ?? this.requiredForInstalledVersion),
    attempt: attempt ?? this.attempt,
    nextAttemptUtc: clearNextAttempt
        ? null
        : (nextAttemptUtc ?? this.nextAttemptUtc),
    lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
  );

  Map<String, Object?> toJson() => {
    'phase': phase.wireName,
    'requiredForInstalledVersion': requiredForInstalledVersion?.value,
    'attempt': attempt,
    'nextAttemptUtc': nextAttemptUtc?.toUtc().toIso8601String(),
    'lastFailure': lastFailure == null
        ? null
        : {
            'code': lastFailure!.code.code,
            'detail': lastFailure!.detail,
            'windowsResultCode': lastFailure!.windowsResultCode,
            'occurredAtUtc': lastFailure!.occurredAtUtc
                ?.toUtc()
                .toIso8601String(),
            'attempt': lastFailure!.attempt,
          },
  };

  static BaselinePreparationState? tryParse(Object? json) {
    if (json is! Map) return null;
    final phase = BaselinePhase.fromWireName(json['phase']);
    if (phase == null) return null;
    final attempt = json['attempt'];
    if (attempt is! int || attempt < 0) return null;
    final required = json['requiredForInstalledVersion'];
    MsixVersion? requiredVersion;
    if (required is String) {
      requiredVersion = MsixVersion.tryParse(required);
      if (requiredVersion == null) return null;
    } else if (required != null) {
      return null;
    }
    UpdateFailure? failure;
    final failureJson = json['lastFailure'];
    if (failureJson is Map) {
      final code = UpdateFailureCode.fromCode(failureJson['code'] as String?);
      if (code == null) return null;
      failure = UpdateFailure(
        code,
        detail: failureJson['detail'] as String?,
        windowsResultCode: failureJson['windowsResultCode'] as int?,
        occurredAtUtc: _parseUtc(failureJson['occurredAtUtc']),
        attempt: failureJson['attempt'] is int
            ? failureJson['attempt'] as int
            : 0,
      );
    } else if (failureJson != null) {
      return null;
    }
    return BaselinePreparationState(
      phase: phase,
      requiredForInstalledVersion: requiredVersion,
      attempt: attempt,
      nextAttemptUtc: _parseUtc(json['nextAttemptUtc']),
      lastFailure: failure,
    );
  }

  @override
  String toString() => 'BaselinePreparationState(${phase.wireName})';
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// 一次基线准备的结果。失败带结构化错误码，便于日志与重试策略分类。
final class UpdateBaselineResult {
  const UpdateBaselineResult({this.baseline, this.failure});

  final RollbackBaseline? baseline;
  final UpdateFailure? failure;

  bool get ok => baseline != null;

  String? get failureCode => failure?.code.code;
}

/// 基线校验结论：**建立与复用走同一个校验**（INV-06）。
final class BaselineValidationResult {
  const BaselineValidationResult.valid({required this.identity})
    : failure = null;

  const BaselineValidationResult.invalid(this.failure) : identity = null;

  /// 从基线包里读出的真实身份（不是清单里的声明）。
  final InstalledPackage? identity;
  final UpdateFailure? failure;

  bool get usable => failure == null;
}

/// 编排器只依赖这个接口，因此测试可以替换基线任务而不启动真实下载。
abstract interface class UpdateBaselinePreparer {
  Future<UpdateBaselineResult> ensureBaseline({
    required InstalledPackage installed,
    required UpdateState state,
  });

  /// 严格校验"当前已安装版本的回退包是否真的可用"。
  Future<BaselineValidationResult> validate({
    required InstalledPackage installed,
    required RollbackBaseline baseline,
  });
}
