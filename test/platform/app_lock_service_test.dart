import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

void main() {
  test('凭据不保存明文，正确密码可验证且关闭锁需再次验证', () async {
    final store = InMemoryAppLockCredentialStore();
    final delays = _RecordingDelay();
    final service = AppLockService(store: store, delays: delays);

    await service.enable('correct horse battery staple');

    expect(await store.read(), isNot(contains('correct horse battery staple')));
    expect(await store.read(), contains('"iterations":600000'));
    expect(await service.verify('correct horse battery staple'), isTrue);
    expect(await service.disable('wrong'), isFalse);
    expect(await service.isEnabled(), isTrue);
    expect(await service.disable('correct horse battery staple'), isTrue);
    expect(await service.isEnabled(), isFalse);
  });

  test('连续错误验证采用 1、2、4 秒递增等待，成功后重置', () async {
    final store = InMemoryAppLockCredentialStore();
    final delays = _RecordingDelay();
    final service = AppLockService(store: store, delays: delays);
    await service.enable('secret');

    expect(await service.verify('bad-1'), isFalse);
    expect(await service.verify('bad-2'), isFalse);
    expect(await service.verify('bad-3'), isFalse);
    expect(delays.values, const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]);
    expect(await service.verify('secret'), isTrue);
    expect(await service.verify('bad-again'), isFalse);
    expect(delays.values.last, const Duration(seconds: 1));
  });
}

final class _RecordingDelay implements AppLockDelayPort {
  final values = <Duration>[];
  @override
  Future<void> wait(Duration duration) async => values.add(duration);
}
