// 更新缓存根解析（实施计划 §9.2 / §9.4）。
//
// 这里验证的是**决策**而不是 Windows API：原生通道返回什么、Dart 就怎么解释。
// 真实安装态的路径与写入验证见 `docs/testing/v1.10.0-packaged-update-storage-acceptance.md`。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/platform/update/windows_update_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(updateStorageChannelName);
  const localAppData = r'C:\Users\tester\AppData\Local';
  const localCache =
      r'C:\Users\tester\AppData\Local\Packages\ShuoZhuang.PersonalPlanner_v9555qkaxdyym\LocalCache';

  void respondWith(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  WindowsUpdateStorage storage() => WindowsUpdateStorage(
    channel: channel,
    environment: const {'LOCALAPPDATA': localAppData},
    isWindows: true,
  );

  test('已打包：使用 LocalCacheFolder，只追加一次 BestPlanning\\Updates', () async {
    var calls = 0;
    respondWith((call) async {
      calls++;
      expect(call.method, 'getLocalCacheRoot');
      return localCache;
    });

    final root = await storage().resolveRoot();

    expect(root.usedUnpackagedFallback, isFalse);
    expect(root.source, 'local-cache');
    expect(root.reason, isEmpty);
    expect(
      root.path,
      '$localCache${Platform.pathSeparator}BestPlanning'
      '${Platform.pathSeparator}Updates',
    );
    expect(calls, 1, reason: '根目录只解析一次，追加一次');
    expect('BestPlanning'.allMatches(root.path), hasLength(1));
    expect('Updates'.allMatches(root.path), hasLength(1));
  });

  test('无包身份：回退到 %LOCALAPPDATA% 并明确标注来源', () async {
    respondWith(
      (call) async => throw PlatformException(
        code: UpdateStorageErrorCode.unpackaged,
        message: 'no package identity',
      ),
    );

    final root = await storage().resolveRoot();

    expect(root.usedUnpackagedFallback, isTrue);
    expect(root.source, 'unpackaged-fallback');
    expect(root.reason, 'unpackaged');
    expect(
      root.path,
      '$localAppData${Platform.pathSeparator}BestPlanning'
      '${Platform.pathSeparator}Updates',
    );
  });

  test('已打包但原生失败：不静默回退，抛出带 HRESULT 的异常', () async {
    const hresult = 0x80070005;
    respondWith(
      (call) async => throw PlatformException(
        code: UpdateStorageErrorCode.failed,
        message: 'LocalCacheFolder failed',
        details: hresult,
      ),
    );

    await expectLater(
      storage().resolveRoot(),
      throwsA(
        isA<UpdateStorageException>()
            .having(
              (error) => error.code,
              'code',
              UpdateStorageErrorCode.failed,
            )
            .having((error) => error.hresult, 'hresult', hresult)
            .having(
              (error) => error.diagnostic,
              'diagnostic',
              contains('0x80070005'),
            ),
      ),
    );
  });

  test('原生返回空路径：按失败处理，不回退', () async {
    respondWith((call) async => '');

    await expectLater(
      storage().resolveRoot(),
      throwsA(
        isA<UpdateStorageException>().having(
          (error) => error.code,
          'code',
          UpdateStorageErrorCode.failed,
        ),
      ),
    );
  });

  test('没有原生通道（纯 Dart 测试）：回退并标注 no-native-channel', () async {
    // 不注册处理器 → MissingPluginException。
    final root = await storage().resolveRoot();

    expect(root.usedUnpackagedFallback, isTrue);
    expect(root.reason, 'no-native-channel');
  });

  test('非 Windows：回退并标注 non-windows', () async {
    final root = await WindowsUpdateStorage(
      channel: channel,
      environment: const {'LOCALAPPDATA': localAppData},
      isWindows: false,
    ).resolveRoot();

    expect(root.usedUnpackagedFallback, isTrue);
    expect(root.reason, 'non-windows');
  });
}
