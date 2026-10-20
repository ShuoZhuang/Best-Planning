// 左下角入口的状态映射（UPD-022 / UPD-023 / UPD-025 / 规格 §11.2）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update/update_controller.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_safety.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/domain/update/update_version.dart';
import 'package:personal_planner/features/shell/update_indicator_model.dart';

UpdateSnapshot _snapshot(
  UpdatePhase phase, {
  UpdateFailure? failure,
  UpdateSafetyStatus safety = const UpdateSafetyStatus.safe(),
  double? progress,
  bool autoUpdateEnabled = true,
}) => UpdateSnapshot(
  state: UpdateState(
    phase: phase,
    target: const UpdateTarget(
      version: SemVerForTest.oneNineZero,
      buildNumber: 46,
      tag: 'v1.9.0',
      msixVersion: MsixVersionForTest.oneNineZero,
      fileName: 'p.msix',
      downloadUrl: 'https://example.invalid/p.msix',
      sizeBytes: 1000,
      sha256:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      manifestDigest:
          'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
      keyId: 'k',
    ),
    totalBytes: 1000,
    receivedBytes: progress == null ? 0 : (progress * 1000).round(),
    lastFailure: failure,
  ),
  safety: safety,
  autoUpdateEnabled: autoUpdateEnabled,
);

void main() {
  test('idle/checking/upToDate 不显示入口', () {
    for (final phase in [
      UpdatePhase.idle,
      UpdatePhase.checking,
      UpdatePhase.upToDate,
    ]) {
      final model = UpdateIndicatorModel.from(_snapshot(phase));
      expect(model.isVisible, isFalse, reason: phase.wireName);
      expect(model.action, UpdateIndicatorAction.none);
    }
  });

  test('updateAvailable/downloading 显示下载进度，点击展开卡片', () {
    for (final phase in [
      UpdatePhase.updateAvailable,
      UpdatePhase.downloading,
    ]) {
      final model = UpdateIndicatorModel.from(_snapshot(phase, progress: 0.42));
      expect(model.kind, UpdateIndicatorKind.downloading);
      expect(model.progress, 0.42);
      expect(model.action, UpdateIndicatorAction.expand);
      expect(model.canTap, isTrue);
    }
  });

  test('下载暂停：警示图标，点击执行重试', () {
    final model = UpdateIndicatorModel.from(
      _snapshot(
        UpdatePhase.downloadPaused,
        failure: const UpdateFailure(UpdateFailureCode.networkOffline),
      ),
    );
    expect(model.kind, UpdateIndicatorKind.paused);
    expect(model.action, UpdateIndicatorAction.retry);
  });

  test('验证中：校验动画，点击只展示“正在验证”', () {
    final model = UpdateIndicatorModel.from(_snapshot(UpdatePhase.verifying));
    expect(model.kind, UpdateIndicatorKind.verifying);
    expect(model.action, UpdateIndicatorAction.expand);
  });

  test('就绪：高亮图标，点击立即安装（没有二次确认）', () {
    final model = UpdateIndicatorModel.from(_snapshot(UpdatePhase.ready));
    expect(model.kind, UpdateIndicatorKind.ready);
    expect(model.canInstall, isTrue);
    expect(model.action, UpdateIndicatorAction.install);
    expect(model.showsBadge, isTrue);
  });

  test('就绪但有未保存编辑：保留入口但禁用安装，并显示原因', () {
    final model = UpdateIndicatorModel.from(
      _snapshot(
        UpdatePhase.ready,
        safety: const UpdateSafetyStatus(
          blockers: {UpdateBlocker.unsavedChanges},
        ),
      ),
    );
    expect(model.kind, UpdateIndicatorKind.ready);
    expect(model.canInstall, isFalse);
    expect(model.action, UpdateIndicatorAction.expand);
    expect(model.message, '请先保存或取消当前编辑，再进行更新。');
  });

  test('暂时受阻：图标可见但不可安装', () {
    final model = UpdateIndicatorModel.from(
      _snapshot(
        UpdatePhase.temporarilyBlocked,
        failure: const UpdateFailure(UpdateFailureCode.networkOffline),
      ),
    );
    expect(model.kind, UpdateIndicatorKind.blocked);
    expect(model.canInstall, isFalse);
    expect(model.canTap, isTrue, reason: '点击应能展开原因');
  });

  test('可重试失败点击重试；不可重试失败只显示原因', () {
    final retryable = UpdateIndicatorModel.from(
      _snapshot(
        UpdatePhase.failed,
        failure: const UpdateFailure(UpdateFailureCode.networkTimeout),
      ),
    );
    expect(retryable.kind, UpdateIndicatorKind.failedRetryable);
    expect(retryable.action, UpdateIndicatorAction.retry);

    final permanent = UpdateIndicatorModel.from(
      _snapshot(
        UpdatePhase.failed,
        failure: const UpdateFailure(
          UpdateFailureCode.packagePublisherMismatch,
        ),
      ),
    );
    expect(permanent.kind, UpdateIndicatorKind.failedPermanent);
    expect(permanent.action, UpdateIndicatorAction.expand);
  });

  test('正常流程没有任何“确认安装”的动作类型', () {
    expect(
      UpdateIndicatorAction.values.map((action) => action.name),
      isNot(contains('confirm')),
    );
  });
}

/// 只在本文件使用的版本常量，避免与领域类型的构造细节纠缠。
abstract final class SemVerForTest {
  static const oneNineZero = SemVer(1, 9, 0);
}

abstract final class MsixVersionForTest {
  static const oneNineZero = MsixVersion(1, 9, 0, 0);
}
