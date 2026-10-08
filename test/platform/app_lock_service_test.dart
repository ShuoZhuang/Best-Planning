import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

/// **测试用的算法注入**（与其余四个 app-lock 测试同一写法）。
///
/// 生产默认是 `iterations: 600000` 的 PBKDF2-HMAC-SHA256。这在纯 Dart 下**每次派生要好几秒**，
/// 而这一条用例要 `enable` + `verify` + `disable` 若干次——本机实测**单文件要 48 秒**，
/// 超过 `package:test` 的 30 秒默认超时，于是**整个全量套件会随机变红**（实测发生过一次：
/// `1028 -1`）。随着套件从 870 条长到 1029 条、机器负载变高，这个余量就没了。
///
/// 这两条要验的是**凭据形状**（不存明文、元数据跟着算法走）与**延迟递增序列**，
/// **都不是**哈希强度。因此一律换成一次迭代：断言一句不改，用例从 48 秒降到毫秒级。
///
/// **生产默认值由下面那条独立的常量用例守着**——不靠跑 600000 次来证明它是 600000。
Pbkdf2 _fastAlgorithm(int iterations) =>
    Pbkdf2.hmacSha256(iterations: iterations, bits: 256);

void main() {
  test('生产默认迭代数是 600000（钉住这个常量，而不是去跑它）', () {
    // 一条毫秒级的常量断言代替"真跑 600000 次派生"。
    // 后者只能证明"600000 跑得动"，前者才是在守"默认值没被人悄悄改小"。
    expect(AppLockService.defaultIterations, 600000);
  });

  test('凭据不保存明文，正确密码可验证且关闭锁需再次验证', () async {
    final store = InMemoryAppLockCredentialStore();
    final delays = _RecordingDelay();
    const iterations = 17;
    final service = AppLockService(
      store: store,
      delays: delays,
      algorithm: _fastAlgorithm(iterations),
    );

    await service.enable('correct horse battery staple');

    expect(await store.read(), isNot(contains('correct horse battery staple')));
    // **断言的是"元数据跟着算法走"**，不是"默认是 600000"——后者由上面那条常量用例守。
    expect(await store.read(), contains('"iterations":$iterations'));
    expect(await store.read(), contains('"iterations":17'));
    expect(await service.verify('correct horse battery staple'), isTrue);
    expect(await service.disable('wrong'), isFalse);
    expect(await service.isEnabled(), isTrue);
    expect(await service.disable('correct horse battery staple'), isTrue);
    expect(await service.isEnabled(), isFalse);
  });

  test('连续错误验证采用 1、2、4 秒递增等待，成功后重置', () async {
    final store = InMemoryAppLockCredentialStore();
    final delays = _RecordingDelay();
    // 这一条只关心延迟序列，哈希强度与它无关 → 用一次迭代。
    final service = AppLockService(
      store: store,
      delays: delays,
      algorithm: _fastAlgorithm(1),
    );
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
