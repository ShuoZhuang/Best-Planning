import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/extension_rejection_store.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

void main() {
  test('拒绝记忆跨仓储实例保留，输入哈希不同则重新允许', () async {
    final repository = MemorySettingsRepository();
    final first = SettingsExtensionRejectionStore(repository);
    const key = 'hash-a|2026-10-17|1500|1890|task-1';
    expect(await first.isRejected(key), isFalse);
    await first.rememberRejected(key);
    expect(await first.isRejected(key), isTrue);
    expect(
      await first.isRejected('hash-b|2026-10-17|1500|1890|task-1'),
      isFalse,
    );

    // 模拟应用重启：新的仓储实例读取同一份设置。
    final restarted = SettingsExtensionRejectionStore(repository);
    expect(await restarted.isRejected(key), isTrue);
  });

  test('损坏的记忆按“未拒绝”处理，不让页面打不开', () async {
    final repository = MemorySettingsRepository();
    await repository.write(SettingsExtensionRejectionStore.storageKey, '{bad');
    final store = SettingsExtensionRejectionStore(repository);
    expect(await store.isRejected('any'), isFalse);
  });
}
