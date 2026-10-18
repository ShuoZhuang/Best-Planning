// 版本与包身份事实（规格 §6.3 / §6.5 / §6.6 / §3.1）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_version.dart';

void main() {
  group('MsixVersion', () {
    test('严格解析四段版本，并保留第四段', () {
      final version = MsixVersion.tryParse('1.9.1.0');
      expect(version, isNotNull);
      expect(version!.major, 1);
      expect(version.minor, 9);
      expect(version.build, 1);
      expect(version.revision, 0);
      expect(version.value, '1.9.1.0');
      expect(version.semanticLabel, '1.9.1');
    });

    test('拒绝三段、tag 前缀、前导零、五段与超范围段', () {
      for (final raw in [
        '1.9.0',
        'v1.9.0.0',
        '01.9.0.0',
        '1.9.0.0.0',
        '1.9.0.0 ',
        '1.9.0.a',
        '1.7.0.65536',
        '',
        null,
      ]) {
        expect(MsixVersion.tryParse(raw), isNull, reason: '不应接受 $raw');
      }
    });

    test('比较只看四段的数值，不按字符串', () {
      expect(
        MsixVersion.tryParse('1.9.0.10')!,
        greaterThan(MsixVersion.tryParse('1.9.0.9')!),
      );
      expect(
        MsixVersion.tryParse('1.10.0.0')!,
        greaterThan(MsixVersion.tryParse('1.9.99.0')!),
      );
    });
  });

  group('SemVer / AppBuildVersion', () {
    test('SemVer 只接受三段数字', () {
      expect(SemVer.tryParse('1.9.0'), const SemVer(1, 9, 0));
      for (final raw in ['1.9', '1.9.0.0', 'v1.9.0', '1.9.0-beta.1', '1.9.0+46']) {
        expect(SemVer.tryParse(raw), isNull, reason: '不应接受 $raw');
      }
    });

    test('Flutter 版本串必须带构建号', () {
      final parsed = AppBuildVersion.tryParse('1.9.0+46');
      expect(parsed, isNotNull);
      expect(parsed!.semantic, const SemVer(1, 9, 0));
      expect(parsed.buildNumber, 46);
      expect(AppBuildVersion.tryParse('1.9.0'), isNull);
      expect(AppBuildVersion.tryParse('1.9.0+0'), isNull);
    });
  });

  group('ReleaseVersionSet', () {
    test('四项互相一致时没有 issue', () {
      final set = ReleaseVersionSet.tryParse(
        version: '1.9.0',
        buildNumber: 46,
        msixVersion: '1.9.0.0',
        tag: 'v1.9.0',
      );
      expect(set, isNotNull);
      expect(set!.issues, isEmpty);
    });

    test('tag 与版本不符时报告 tagMismatch', () {
      final set = ReleaseVersionSet.tryParse(
        version: '1.9.0',
        buildNumber: 46,
        msixVersion: '1.9.0.0',
        tag: 'v1.8.1',
      );
      expect(set!.issues, contains(ReleaseVersionIssue.tagMismatch));
    });

    test('MSIX 前三段与 SemVer 不符时报告 msixSemverMismatch', () {
      final set = ReleaseVersionSet.tryParse(
        version: '1.9.0',
        buildNumber: 46,
        msixVersion: '1.9.1.0',
        tag: 'v1.9.0',
      );
      expect(set!.issues, contains(ReleaseVersionIssue.msixSemverMismatch));
    });

    test('历史非标准 tag 不属于新协议：解析失败而不是被猜测', () {
      expect(
        ReleaseVersionSet.tryParse(
          version: '1.8.1',
          buildNumber: 45,
          msixVersion: '1.8.1.0',
          tag: 'v1.8.1-build45',
        )!.issues,
        contains(ReleaseVersionIssue.tagMismatch),
      );
    });
  });

  group('包身份', () {
    test('包族名由 Publisher 按 UTF-16LE + SHA-256 + base32 派生', () {
      expect(
        packageFamilyNameFor(appPackageIdentityName, appPublisher),
        appPackageFamilyName,
      );
      expect(publisherIdFor(appPublisher), 'v9555qkaxdyym');
      // 发布者不同 → 包族名不同。这证明 PFN 不是抄来的常量。
      expect(
        packageFamilyNameFor(appPackageIdentityName, 'CN=Someone Else'),
        isNot(appPackageFamilyName),
      );
    });

    test('AUMID 由包族名与入口名组成', () {
      expect(appAumid, 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner');
      expect(appAumid.startsWith(appPackageFamilyName), isTrue);
    });

    test('已安装包与客户端期望逐项比较', () {
      const matching = InstalledPackage(
        identityName: appPackageIdentityName,
        publisher: appPublisher,
        familyName: appPackageFamilyName,
        architecture: PackageArchitecture.x64,
        version: MsixVersion(1, 8, 1, 0),
      );
      expect(matching.mismatches, isEmpty);
      expect(matching.matchesClientIdentity, isTrue);

      const otherPublisher = InstalledPackage(
        identityName: appPackageIdentityName,
        publisher: 'CN=Other',
        familyName: appPackageFamilyName,
        architecture: PackageArchitecture.x64,
        version: MsixVersion(1, 8, 1, 0),
      );
      expect(
        otherPublisher.mismatches,
        contains(PackageIdentityMismatch.publisher),
      );
    });

    test('兼容性段与客户端事实比较', () {
      const assessment = CompatibilityAssessment(
        identityName: appPackageIdentityName,
        publisher: appPublisher,
        familyName: appPackageFamilyName,
        architecture: 'arm64',
        minimumWindowsBuild: MsixVersion(10, 0, 19041, 0),
      );
      expect(
        assessment.mismatches,
        contains(CompatibilityMismatch.architecture),
      );
    });
  });
}
