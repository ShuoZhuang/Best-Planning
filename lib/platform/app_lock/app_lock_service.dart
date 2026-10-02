import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

abstract interface class AppLockCredentialStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

abstract interface class AppLockDelayPort {
  Future<void> wait(Duration duration);
}

final class SystemAppLockDelay implements AppLockDelayPort {
  const SystemAppLockDelay();
  @override
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}

final class InMemoryAppLockCredentialStore implements AppLockCredentialStore {
  InMemoryAppLockCredentialStore([this._value]);
  String? _value;

  @override
  Future<void> clear() async => _value = null;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async => _value = value;
}

final class SettingsAppLockCredentialStore implements AppLockCredentialStore {
  const SettingsAppLockCredentialStore(this.settings);

  static const credentialKey = 'security.appLock.credential.v1';
  final SettingsRepository settings;

  @override
  Future<void> clear() => settings.remove(credentialKey);

  @override
  Future<String?> read() => settings.read(credentialKey);

  @override
  Future<void> write(String value) => settings.write(credentialKey, value);
}

final class AppLockService {
  AppLockService({
    required this.store,
    this.delays = const SystemAppLockDelay(),
    Pbkdf2? algorithm,
    Random? random,
  }) : _algorithm =
           algorithm ??
           Pbkdf2.hmacSha256(iterations: defaultIterations, bits: 256),
       _random = random ?? Random.secure();

  static const defaultIterations = 600000;
  static const _saltLength = 16;

  final AppLockCredentialStore store;
  final AppLockDelayPort delays;
  final Pbkdf2 _algorithm;
  final Random _random;
  int _failedAttempts = 0;

  Future<bool> isEnabled() async => await store.read() != null;

  Future<void> enable(String password) async {
    if (password.isEmpty) throw ArgumentError.value(password, 'password');
    final salt = List<int>.generate(_saltLength, (_) => _random.nextInt(256));
    final hash = await _derive(password, salt);
    await store.write(
      jsonEncode({
        'schemaVersion': 1,
        'algorithm': 'PBKDF2-HMAC-SHA256',
        'iterations': _algorithm.iterations,
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
      }),
    );
    _failedAttempts = 0;
  }

  Future<bool> verify(String password) async {
    final raw = await store.read();
    if (raw == null) return true;
    try {
      final value = jsonDecode(raw) as Map<String, Object?>;
      if (value['algorithm'] != 'PBKDF2-HMAC-SHA256' ||
          value['iterations'] != _algorithm.iterations) {
        throw const FormatException('Unsupported app-lock credential.');
      }
      final salt = base64Decode(value['salt'] as String);
      final expected = base64Decode(value['hash'] as String);
      final actual = await _derive(password, salt);
      if (_constantTimeEquals(actual, expected)) {
        _failedAttempts = 0;
        return true;
      }
    } catch (_) {
      // Invalid stored credentials fail closed.
    }
    _failedAttempts++;
    await delays.wait(_delayFor(_failedAttempts));
    return false;
  }

  Future<bool> disable(String password) async {
    if (!await verify(password)) return false;
    await store.clear();
    return true;
  }

  Future<List<int>> _derive(String password, List<int> salt) async {
    final key = await _algorithm.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    return key.extractBytes();
  }

  static Duration _delayFor(int attempts) {
    final seconds = min(30, 1 << min(attempts - 1, 5));
    return Duration(seconds: seconds);
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    var difference = left.length ^ right.length;
    final length = min(left.length, right.length);
    for (var index = 0; index < length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
