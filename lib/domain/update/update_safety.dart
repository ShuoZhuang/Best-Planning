// 更新安全阻塞规则（规格 §11.4 / §11.5 / §14.2）。
//
// **阻塞与失败是两件事**：失败是"这次更新出了问题"，阻塞是"现在不能开始更新，但更新本身没
// 问题"。因此阻塞用独立类型表达、用可重试的错误码展示、且不改变目标版本的验证结论。
//
// 专注功能**不在这里**：规格 §2.1 第 10 条明确要求它不参与更新阻塞，也不增加专门分支。
// 如果将来有人往这里加一个 `focusing`，`update_safety_test.dart` 会立刻红。
import 'dart:async';

import 'package:personal_planner/domain/update/update_failure.dart';

/// 阻止安装的原因。下载与检查**不受**它们影响（规格 §11.4）。
enum UpdateBlocker {
  unsavedChanges(UpdateFailureCode.blockedUnsavedChanges, '请先保存或取消当前编辑，再进行更新。'),
  databaseTransaction(
    UpdateFailureCode.blockedDatabaseTransaction,
    '正在完成数据操作，完成后即可更新。',
  ),
  planApplying(UpdateFailureCode.blockedPlanApplying, '正在完成数据操作，完成后即可更新。'),
  importRunning(UpdateFailureCode.blockedImportRunning, '正在完成数据操作，完成后即可更新。'),
  backupRunning(UpdateFailureCode.blockedBackupRunning, '正在完成数据操作，完成后即可更新。'),
  executionSession(
    UpdateFailureCode.blockedExecutionSession,
    '正在记录一次执行，请先暂停或结束本次会话再更新。',
  ),
  rollbackNotReady(
    UpdateFailureCode.blockedRollbackNotReady,
    '正在准备回退基线，完成后即可更新。',
  ),
  diskSpaceLow(UpdateFailureCode.blockedDiskSpaceLow, '磁盘空间不足，暂时无法安装更新。'),
  installerBusy(UpdateFailureCode.blockedInstallerBusy, '另一个更新操作正在进行。');

  const UpdateBlocker(this.code, this.message);

  final UpdateFailureCode code;
  final String message;
}

/// 当前安全状态：阻塞项集合 + 可安装判定。
final class UpdateSafetyStatus {
  const UpdateSafetyStatus({this.blockers = const {}});

  const UpdateSafetyStatus.safe() : blockers = const {};

  final Set<UpdateBlocker> blockers;

  bool get canInstall => blockers.isEmpty;

  /// 主阻塞项的文案。多个阻塞同时存在时按枚举顺序取第一个，界面只显示一句。
  String? get message => blockers.isEmpty
      ? null
      : UpdateBlocker.values.firstWhere(blockers.contains).message;

  UpdateFailure? get failure => blockers.isEmpty
      ? null
      : UpdateFailure(UpdateBlocker.values.firstWhere(blockers.contains).code);

  UpdateSafetyStatus withBlocker(
    UpdateBlocker blocker, {
    required bool active,
  }) {
    final next = {...blockers};
    if (active) {
      next.add(blocker);
    } else {
      next.remove(blocker);
    }
    return UpdateSafetyStatus(blockers: Set.unmodifiable(next));
  }

  @override
  String toString() =>
      'UpdateSafetyStatus(${blockers.map((b) => b.name).join(',')})';
}

/// 一次"正在发生"的阻塞租约。调用方在 `finally` 里释放；重复释放无副作用。
///
/// 用租约而不是布尔值：两个并发的导入/备份各持一份租约，第一个结束时计数只减一，
/// 阻塞仍然存在，直到最后一个也结束。
abstract interface class UpdateBlockerLease {
  void release();
}

/// 业务层向更新子系统报告"现在有什么正在发生"的端口。
///
/// 刻意只有一组布尔事实，没有 `String` 原因：界面文案由 [UpdateBlocker] 统一给出，
/// 业务层不需要也不应该拼用户可见的句子。
abstract interface class UpdateSafetyCoordinator {
  /// 最近一次计算的阻塞项。编排器在安装前读取它，并在状态变化时收到通知。
  UpdateSafetyStatus get status;

  /// 状态变化流；界面用它刷新左下角入口与状态卡片。
  Stream<UpdateSafetyStatus> get changes;

  /// 申请一份阻塞租约。适用于可能重叠的异步操作：每个操作各持一份，全部释放后才解除。
  ///
  /// 调用方必须用 `try/finally` 释放；重复调用同一个租约的 [UpdateBlockerLease.release]
  /// 不会多减计数。
  UpdateBlockerLease begin(UpdateBlocker blocker);

  /// 报告未保存编辑是否处于激活状态（任务、周期目标、固定日程、课程、设置等表单）。
  void setUnsavedChanges(bool active);

  /// 报告数据库事务是否正在进行。
  void setDatabaseTransaction(bool active);

  /// 报告计划应用或撤销是否正在运行。
  void setPlanApplying(bool active);

  /// 报告课程导入是否正在运行。
  void setImportRunning(bool active);

  /// 报告备份或恢复是否正在运行。
  void setBackupRunning(bool active);

  /// 报告安装器事务是否被占用（由编排器维护）。
  void setInstallerBusy(bool active);

  /// 报告回退基线是否尚未就绪。
  void setRollbackNotReady(bool active);

  /// 磁盘空间是否不足（由编排器在检查时更新）。
  void setDiskSpaceLow(bool active);

  void dispose();
}

/// 可测试的安全协调器：纯内存、同步通知。
///
/// 手工布尔（表单未保存、安装器占用、磁盘空间）与租约计数**分开维护**：表单反复调用
/// `setUnsavedChanges(true/false)` 不会泄漏计数；服务层的重叠操作则用 [begin] 租约。
final class InMemoryUpdateSafetyCoordinator implements UpdateSafetyCoordinator {
  final StreamController<UpdateSafetyStatus> _controller =
      StreamController<UpdateSafetyStatus>.broadcast();
  final Set<UpdateBlocker> _manual = <UpdateBlocker>{};
  final Map<UpdateBlocker, int> _leaseCounts = <UpdateBlocker, int>{};
  UpdateSafetyStatus _status = const UpdateSafetyStatus.safe();
  bool _disposed = false;

  @override
  UpdateSafetyStatus get status => _status;

  @override
  Stream<UpdateSafetyStatus> get changes => _controller.stream;

  @override
  UpdateBlockerLease begin(UpdateBlocker blocker) {
    _leaseCounts[blocker] = (_leaseCounts[blocker] ?? 0) + 1;
    _recompute();
    return _Lease(this, blocker);
  }

  @override
  void setUnsavedChanges(bool active) =>
      _setManual(UpdateBlocker.unsavedChanges, active);

  @override
  void setDatabaseTransaction(bool active) =>
      _setManual(UpdateBlocker.databaseTransaction, active);

  @override
  void setPlanApplying(bool active) =>
      _setManual(UpdateBlocker.planApplying, active);

  @override
  void setImportRunning(bool active) =>
      _setManual(UpdateBlocker.importRunning, active);

  @override
  void setBackupRunning(bool active) =>
      _setManual(UpdateBlocker.backupRunning, active);

  @override
  void setInstallerBusy(bool active) =>
      _setManual(UpdateBlocker.installerBusy, active);

  @override
  void setRollbackNotReady(bool active) =>
      _setManual(UpdateBlocker.rollbackNotReady, active);

  @override
  void setDiskSpaceLow(bool active) =>
      _setManual(UpdateBlocker.diskSpaceLow, active);

  void _setManual(UpdateBlocker blocker, bool active) {
    final changed = active ? _manual.add(blocker) : _manual.remove(blocker);
    if (changed) _recompute();
  }

  void _releaseLease(UpdateBlocker blocker) {
    final count = _leaseCounts[blocker];
    if (count == null || count <= 1) {
      _leaseCounts.remove(blocker);
    } else {
      _leaseCounts[blocker] = count - 1;
    }
    _recompute();
  }

  void _recompute() {
    final next = UpdateSafetyStatus(
      blockers: Set.unmodifiable({..._manual, ..._leaseCounts.keys}),
    );
    if (next.blockers.length == _status.blockers.length &&
        next.blockers.containsAll(_status.blockers)) {
      return;
    }
    _status = next;
    if (!_disposed) _controller.add(next);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.close();
  }
}

final class _Lease implements UpdateBlockerLease {
  _Lease(this._owner, this._blocker);

  final InMemoryUpdateSafetyCoordinator _owner;
  final UpdateBlocker _blocker;
  bool _released = false;

  @override
  void release() {
    if (_released) return;
    _released = true;
    _owner._releaseLease(_blocker);
  }
}
