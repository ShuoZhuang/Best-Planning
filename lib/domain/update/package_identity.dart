// 包身份事实与派生规则（规格 §3.1 / §6.3 / §10.1）。
//
// 这些值**不是配置**：它们决定 Windows 把升级当作"同一个应用"的覆盖安装，还是当作另一个
// 应用。改动其中任何一项都意味着用户数据容器换了一个，因此集中在一个文件里，并由
// `test/domain/update/package_identity_test.dart` 与 `pubspec.yaml` 对账。
//
// PFN（包族名）不是用户可配置的字符串：它是 `Name + "_" + PublisherId`，而 PublisherId
// 是 Publisher 字符串的 **UTF-16LE 字节**做 SHA-256 后取前 8 字节，再按 Windows 的
// base32 字母表编码成 13 个字符。这里自己算出来而不是抄一个常量，是为了让"清单里的
// packageFamilyName 与 publisher 是否自洽"可以被验证——抄来的常量无法证明这一点。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/update/update_version.dart';

/// 包身份名。与 `pubspec.yaml` 的 `msix_config.identity_name` 必须一致。
const String appPackageIdentityName = 'ShuoZhuang.PersonalPlanner';

/// 发布者全称。与 `msix_config.publisher`、MSIX 签名证书 Subject 一字不差。
const String appPublisher = 'CN=Shuo Zhuang, O=Personal User, C=CN';

/// 包族名。由 [packageFamilyNameFor] 从上面两项派生，这里保留常量供界面与测试引用；
/// 一致性由 `packageFamilyNameFor(appPackageIdentityName, appPublisher)` 的测试守着。
const String appPackageFamilyName = 'ShuoZhuang.PersonalPlanner_v9555qkaxdyym';

/// 真实 AUMID（规格 §12.5）。助手启动新版时用它，**不猜 WindowsApps 目录、不写死 EXE 路径**。
const String appAumid = '$appPackageFamilyName!personalplanner';

/// 首个正式通道要求的最低 Windows 构建（Windows 10 2004 起支持本更新链路所需的部署接口）。
const List<int> appMinimumWindowsBuild = [10, 0, 19041, 0];

/// 发布架构。首版只有 x64（规格 §4.1）。
const String appArchitecture = 'x64';

/// Windows 包清单允许的处理器架构。
enum PackageArchitecture {
  x64('x64'),
  x86('x86'),
  arm64('arm64'),
  arm('arm'),
  neutral('neutral');

  const PackageArchitecture(this.wireName);

  /// 清单里的原样写法（`ProcessorArchitecture`）。
  final String wireName;

  static PackageArchitecture? tryParse(String? raw) {
    if (raw == null) return null;
    for (final value in PackageArchitecture.values) {
      if (value.wireName == raw) return value;
    }
    return null;
  }
}

/// Windows base32 字母表：去掉了容易混淆的 `i`、`l`、`o`、`u`（Crockford 变体）。
const String _windowsBase32Alphabet = '0123456789abcdefghjkmnpqrstvwxyz';

/// 由包名与发布者派生包族名。
///
/// 算法（Windows 的 PublisherId 规则）：
///   1. 把 Publisher 按 **UTF-16LE** 编码（不是 UTF-8）；
///   2. SHA-256，取前 8 字节（64 位）；
///   3. 按 [_windowsBase32Alphabet] 从高位到低位编码成 13 个字符（65 位，末位补 0）。
///
/// **为什么不用 UTF-8**：用错编码得到的仍是一串合法的 base32，它不会报错，只会让算出的
/// PFN 与实际包不一致——这正是"清单校验通过但安装包身份对不上"的典型来源。
String packageFamilyNameFor(String name, String publisher) {
  final digest = sha256.convert(_utf16LeBytes(publisher)).bytes;
  final publisherId = _windowsBase32(digest.take(8).toList(), 13);
  return '${name}_$publisherId';
}

/// 由发布者派生 13 位 PublisherId。
String publisherIdFor(String publisher) =>
    _windowsBase32(sha256.convert(_utf16LeBytes(publisher)).bytes.take(8).toList(), 13);

List<int> _utf16LeBytes(String value) {
  final bytes = <int>[];
  for (final unit in value.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add((unit >> 8) & 0xFF);
  }
  return bytes;
}

String _windowsBase32(List<int> bytes, int characterCount) {
  final buffer = StringBuffer();
  var accumulator = 0;
  var bits = 0;
  var index = 0;
  while (buffer.length < characterCount) {
    if (bits < 5) {
      accumulator = (accumulator << 8) | (index < bytes.length ? bytes[index] : 0);
      bits += 8;
      index++;
    }
    final shift = bits - 5;
    buffer.write(_windowsBase32Alphabet[(accumulator >> shift) & 0x1F]);
    bits = shift;
  }
  return buffer.toString();
}

/// 已安装包的事实。来源是 Windows 包身份，而不是 `pubspec.yaml` 或备份清单（规格 §5.3）。
final class InstalledPackage {
  const InstalledPackage({
    required this.identityName,
    required this.publisher,
    required this.familyName,
    required this.architecture,
    required this.version,
    this.isPackaged = true,
  });

  final String identityName;
  final String publisher;
  final String familyName;
  final PackageArchitecture architecture;
  final MsixVersion version;

  /// 未打包运行（`flutter test`、绿色版 EXE）时为 `false`。更新功能据此显示"未打包"而不是
  /// 假装当前版本是 `0.0.0.0`。
  final bool isPackaged;

  /// 身份是否与客户端期望完全一致。任何一项不符都意味着"这不是同一个应用"。
  Set<PackageIdentityMismatch> get mismatches {
    final found = <PackageIdentityMismatch>{};
    if (identityName != appPackageIdentityName) {
      found.add(PackageIdentityMismatch.identityName);
    }
    if (publisher != appPublisher) {
      found.add(PackageIdentityMismatch.publisher);
    }
    if (familyName != appPackageFamilyName) {
      found.add(PackageIdentityMismatch.familyName);
    }
    if (architecture != PackageArchitecture.x64) {
      found.add(PackageIdentityMismatch.architecture);
    }
    return found;
  }

  bool get matchesClientIdentity => mismatches.isEmpty;

  @override
  String toString() =>
      'InstalledPackage($identityName, $version, ${architecture.wireName}, packaged=$isPackaged)';
}

/// 身份不一致的类别，用于映射到 `UPDATE_PACKAGE_*` 错误码。
enum PackageIdentityMismatch {
  identityName,
  publisher,
  familyName,
  architecture,
}

/// 清单的 `compatibility` 段与客户端事实比较后的结论。
///
/// 比较是**逐项的**：只报"不兼容"会让诊断页无法说明到底是发布者变了还是架构变了，
/// 而这两者的处置完全不同（前者要求拒绝安装，后者可能只是下错了资产）。
final class CompatibilityAssessment {
  const CompatibilityAssessment({
    required this.identityName,
    required this.publisher,
    required this.familyName,
    required this.architecture,
    required this.minimumWindowsBuild,
  });

  final String identityName;
  final String publisher;
  final String familyName;
  final String architecture;
  final MsixVersion minimumWindowsBuild;

  Set<CompatibilityMismatch> get mismatches {
    final found = <CompatibilityMismatch>{};
    if (identityName != appPackageIdentityName) {
      found.add(CompatibilityMismatch.identityName);
    }
    if (publisher != appPublisher) {
      found.add(CompatibilityMismatch.publisher);
    }
    if (familyName != appPackageFamilyName) {
      found.add(CompatibilityMismatch.familyName);
    }
    if (architecture != appArchitecture) {
      found.add(CompatibilityMismatch.architecture);
    }
    return found;
  }
}

enum CompatibilityMismatch {
  identityName,
  publisher,
  familyName,
  architecture,
}

/// 把 JSON 里的发布者字符串规范化成可比较的形式。
///
/// 只做**空白归一**（首尾空白与逗号后的空白），不改大小写、不改顺序：Publisher 是证书
/// Subject 的原文，任何"看起来等价"的重写都可能把不同的发布者判成同一个。
String normalizePublisher(String value) => value
    .split(',')
    .map((part) => part.trim())
    .where((part) => part.isNotEmpty)
    .join(', ');

/// 供日志与状态文件使用的短发布者标识（不含任何用户信息）。
String publisherFingerprint(String publisher) =>
    sha256.convert(utf8.encode(normalizePublisher(publisher))).toString().substring(0, 16);
