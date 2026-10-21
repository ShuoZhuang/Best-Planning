// 更新地址与重定向允许列表（UPD-008）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/update_manifest.dart';
import 'package:personal_planner/infrastructure/update/update_network_policy.dart';

void main() {
  group('清单地址', () {
    test('接受 latest 与指定版本的固定地址', () {
      expect(
        UpdateNetworkPolicy.isAllowedManifestUri(
          Uri.parse(
            'https://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json',
          ),
        ),
        isTrue,
      );
      expect(
        UpdateNetworkPolicy.isAllowedManifestUri(
          updateManifestUrlForTag('v1.9.0'),
        ),
        isTrue,
      );
    });

    test('拒绝明文、其他仓库、非版本 tag 与其他路径', () {
      for (final url in [
        'http://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json',
        'https://github.com/SomeoneElse/Best-Planning/releases/latest/download/update-manifest.json',
        'https://raw.githubusercontent.com/ShuoZhuang/Best-Planning/main/update-manifest.json',
        'https://github.com/ShuoZhuang/Best-Planning/releases/download/latest/update-manifest.json',
        'https://github.com/ShuoZhuang/Best-Planning/releases/download/1.9.0/update-manifest.json',
      ]) {
        expect(
          UpdateNetworkPolicy.isAllowedManifestUri(Uri.parse(url)),
          isFalse,
          reason: '不应接受 $url',
        );
      }
    });
  });

  group('重定向', () {
    test('允许本仓库与 GitHub 官方资产域', () {
      expect(
        UpdateNetworkPolicy.isAllowedRedirect(
          Uri.parse(
            'https://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/BestPlanning_1.9.0.0_x64.msix',
          ),
        ),
        isTrue,
      );
      expect(
        UpdateNetworkPolicy.isAllowedRedirect(
          Uri.parse(
            'https://release-assets.githubusercontent.com/github-production-release-asset/123',
          ),
        ),
        isTrue,
      );
      expect(
        UpdateNetworkPolicy.isAllowedRedirect(
          Uri.parse('https://objects.githubusercontent.com/object/1'),
        ),
        isTrue,
      );
    });

    test('拒绝明文、IP 字面量、未知域名与其他仓库', () {
      for (final url in [
        'http://github.com/ShuoZhuang/Best-Planning/releases/download/v1.9.0/a.msix',
        'https://192.168.1.10/a.msix',
        'https://[::1]/a.msix',
        'https://evil.example/a.msix',
        'https://github.com/SomeoneElse/repo/releases/download/v1.9.0/a.msix',
        'https://github.com/ShuoZhuang/Other/releases/download/v1.9.0/a.msix',
        'https://github.com.evil.example/ShuoZhuang/Best-Planning/a.msix',
      ]) {
        expect(
          UpdateNetworkPolicy.isAllowedRedirect(Uri.parse(url)),
          isFalse,
          reason: '不应接受 $url',
        );
      }
    });

    test('相对 Location 按当前地址解析', () {
      final current = Uri.parse(
        'https://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json',
      );
      expect(
        UpdateNetworkPolicy.resolveLocation(current, 'update-manifest.json'),
        current,
      );
      expect(
        UpdateNetworkPolicy.resolveLocation(current, '/a/b.json')!.path,
        '/a/b.json',
      );
      expect(UpdateNetworkPolicy.resolveLocation(current, null), isNull);
    });
  });
}
