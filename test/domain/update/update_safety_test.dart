// 安全阻塞（UPD-027～UPD-030 / 规格 §11.4 / §11.5）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_safety.dart';

void main() {
  test('默认安全，可以安装', () {
    const status = UpdateSafetyStatus.safe();
    expect(status.canInstall, isTrue);
    expect(status.message, isNull);
    expect(status.failure, isNull);
  });

  test('未保存编辑：文案与错误码与规格一致，且阻止安装', () {
    const status = UpdateSafetyStatus(blockers: {UpdateBlocker.unsavedChanges});
    expect(status.canInstall, isFalse);
    expect(status.message, '请先保存或取消当前编辑，再进行更新。');
    expect(status.failure!.code, UpdateFailureCode.blockedUnsavedChanges);
  });

  test('业务事务类阻塞共用同一句“正在完成数据操作”', () {
    for (final blocker in [
      UpdateBlocker.databaseTransaction,
      UpdateBlocker.planApplying,
      UpdateBlocker.importRunning,
      UpdateBlocker.backupRunning,
    ]) {
      final status = UpdateSafetyStatus(blockers: {blocker});
      expect(status.message, '正在完成数据操作，完成后即可更新。');
    }
  });

  test('多个阻塞同时存在时只显示主阻塞的文案', () {
    const status = UpdateSafetyStatus(blockers: {
      UpdateBlocker.diskSpaceLow,
      UpdateBlocker.unsavedChanges,
    });
    expect(status.message, startsWith('请先保存'));
    expect(status.canInstall, isFalse);
  });

  test('移除阻塞后恢复可安装', () {
    final blocked = const UpdateSafetyStatus.safe()
        .withBlocker(UpdateBlocker.databaseTransaction, active: true);
    expect(blocked.canInstall, isFalse);
    final cleared = blocked.withBlocker(
      UpdateBlocker.databaseTransaction,
      active: false,
    );
    expect(cleared.canInstall, isTrue);
  });

  test('专注不参与更新阻塞（规格 §2.1 第 10 条）', () {
    expect(
      UpdateBlocker.values.map((blocker) => blocker.name),
      isNot(contains('focusing')),
    );
    expect(
      UpdateBlocker.values.map((blocker) => blocker.name),
      isNot(contains('focus')),
    );
  });

  test('协调器按布尔事实维护阻塞集合，并发出变化', () async {
    final coordinator = InMemoryUpdateSafetyCoordinator();
    addTearDown(coordinator.dispose);
    final events = <UpdateSafetyStatus>[];
    final subscription = coordinator.changes.listen(events.add);
    addTearDown(subscription.cancel);

    expect(coordinator.status.canInstall, isTrue);

    coordinator.setUnsavedChanges(true);
    coordinator.setDatabaseTransaction(true);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.status.canInstall, isFalse);
    expect(
      coordinator.status.blockers,
      containsAll([
        UpdateBlocker.unsavedChanges,
        UpdateBlocker.databaseTransaction,
      ]),
    );
    expect(events, isNotEmpty);

    coordinator.setUnsavedChanges(false);
    coordinator.setDatabaseTransaction(false);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.status.canInstall, isTrue);
  });

  test('重叠租约：全部释放后才解除阻塞（UPD-029）', () {
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    final first = safety.begin(UpdateBlocker.importRunning);
    expect(safety.status.blockers, contains(UpdateBlocker.importRunning));

    final second = safety.begin(UpdateBlocker.importRunning);
    first.release();
    expect(
      safety.status.blockers,
      contains(UpdateBlocker.importRunning),
      reason: '第一个操作结束不应解除第二个操作的阻塞',
    );

    second.release();
    expect(safety.status.canInstall, isTrue);
  });

  test('租约重复释放不会多减计数，手工阻塞与租约可以叠加', () {
    final safety = InMemoryUpdateSafetyCoordinator();
    addTearDown(safety.dispose);
    final lease = safety.begin(UpdateBlocker.backupRunning);
    safety.setUnsavedChanges(true);
    lease.release();
    lease.release();
    expect(safety.status.blockers, contains(UpdateBlocker.unsavedChanges));
    expect(safety.status.blockers, isNot(contains(UpdateBlocker.backupRunning)));
    safety.setUnsavedChanges(false);
    expect(safety.status.canInstall, isTrue);
  });
}
