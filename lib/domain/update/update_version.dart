// 更新协议里的版本事实（规格 §6.3 / §6.5 / §6.6）。
//
// 这一层只做一件事：把"版本"从字符串变成可比较、可交叉验证的事实。它刻意不碰网络、文件、
// Flutter 或 Windows API——规格 §5.2 要求领域模型不得依赖这些。
//
// **为什么四种版本形式必须同时存在**：协议里同时出现 SemVer（`1.9.0`）、构建号（`46`）、
// 四段 MSIX 版本（`1.9.0.0`）与 tag（`v1.9.0`）。它们各自有用途，又必须互相一致：
//   · 是否更新只看 Windows 已安装的 MSIX 版本（§6.6），不看 SemVer 也不看 tag；
//   · SemVer/buildNumber/tag 用于验证清单自身是否自洽，**不得各自独立触发安装**；
//   · 历史 tag（`v1.8.1-build45`）不属于新协议，解析失败是它应有的结果，不是缺陷。
library;

/// 四段 Windows 包版本，例如 `1.9.0.0`。
///
/// 每段都是 `0..65535` 的整数——这是 Windows 包清单里 `Identity/@Version` 的实际宽度，
/// 超出范围的字符串即使"看起来像版本"也不可能被系统接受，因此在解析时就拒绝。
final class MsixVersion implements Comparable<MsixVersion> {
  const MsixVersion(this.major, this.minor, this.build, this.revision);

  final int major;
  final int minor;
  final int build;

  /// 第四段。**不是构建计数器**：它是"同一批代码重打包"的计数（见 `pubspec.yaml` 的说明）。
  final int revision;

  static final RegExp _pattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  /// 严格解析四段版本；不合法返回 `null`。
  ///
  /// 刻意拒绝的形式：`1.9.0`（三段）、`v1.9.0.0`（带 tag 前缀）、`01.9.0.0`（前导零）、
  /// `1.9.0.0.0`（五段）与任何非数字段。接受它们会让"同一个版本"有多种写法，而清单签名
  /// 保护的是字节，不是"等价的字符串"。
  static MsixVersion? tryParse(String? raw) {
    if (raw == null) return null;
    final match = _pattern.firstMatch(raw);
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 4; i++) int.parse(match.group(i)!)];
    if (parts.any((part) => part > 0xFFFF)) return null;
    return MsixVersion(parts[0], parts[1], parts[2], parts[3]);
  }

  /// 规范写法 `major.minor.build.revision`。
  String get value => '$major.$minor.$build.$revision';

  /// 前三段，用于与 SemVer 交叉核对。
  String get semanticLabel => '$major.$minor.$build';

  @override
  int compareTo(MsixVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (build != other.build) return build.compareTo(other.build);
    return revision.compareTo(other.revision);
  }

  bool operator >(MsixVersion other) => compareTo(other) > 0;

  bool operator <(MsixVersion other) => compareTo(other) < 0;

  bool operator >=(MsixVersion other) => compareTo(other) >= 0;

  bool operator <=(MsixVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is MsixVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, build, revision);

  @override
  String toString() => value;
}

/// 三段 SemVer，例如 `1.9.0`。
///
/// 本协议**不接受**预发布与构建元数据（`-beta.1`、`+46`）：稳定通道只有正式版，
/// 而把 `+46` 放进 SemVer 会与"构建号是独立字段"这一条冲突。
final class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  /// 严格解析三段 SemVer；不合法返回 `null`。
  static SemVer? tryParse(String? raw) {
    if (raw == null) return null;
    final match = _pattern.firstMatch(raw);
    if (match == null) return null;
    return SemVer(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  String get value => '$major.$minor.$patch';

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(SemVer other) => compareTo(other) > 0;

  bool operator <(SemVer other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => value;
}

/// Flutter 版本串 `主.次.修订+构建号`，例如 `1.9.0+46`。
///
/// 它在本协议里只有两个用途：与 `pubspec.yaml` 对账（发布流水线），以及作为
/// `release.buildNumber` 的来源。**更新判断不读它**（§6.6）。
final class AppBuildVersion implements Comparable<AppBuildVersion> {
  const AppBuildVersion(this.semantic, this.buildNumber);

  final SemVer semantic;
  final int buildNumber;

  static final RegExp _pattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)$',
  );

  static AppBuildVersion? tryParse(String? raw) {
    if (raw == null) return null;
    final match = _pattern.firstMatch(raw);
    if (match == null) return null;
    return AppBuildVersion(
      SemVer(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      ),
      int.parse(match.group(4)!),
    );
  }

  @override
  int compareTo(AppBuildVersion other) {
    final semanticOrder = semantic.compareTo(other.semantic);
    if (semanticOrder != 0) return semanticOrder;
    return buildNumber.compareTo(other.buildNumber);
  }

  @override
  bool operator ==(Object other) =>
      other is AppBuildVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(semantic, buildNumber);

  @override
  String toString() => '${semantic.value}+$buildNumber';
}

/// 一次候选发布里必须互相一致的四项版本事实。
///
/// **为什么要有一个组合类型**：规格 §6.6 要求 SemVer、MSIX 版本、build number 与 tag
/// 互相一致，任何一项不一致都必须拒绝。若把它们拆成四个独立参数，每个调用点都要重复写
/// 同一组等式，而漏写其中一条的症状是"安装了版本号对不上的包"。
final class ReleaseVersionSet {
  const ReleaseVersionSet({
    required this.version,
    required this.buildNumber,
    required this.msixVersion,
    required this.tag,
  });

  final SemVer version;
  final int buildNumber;
  final MsixVersion msixVersion;

  /// 必须严格等于 `v{version.value}`。
  final String tag;

  /// 从原始字段构造；任一项不合法返回 `null`。
  ///
  /// 注意它**不判断一致性**：一致性由 [issues] 报告，这样解析层可以区分"字段格式错误"
  /// （`UPDATE_MANIFEST_INVALID_JSON`）与"字段之间不一致"（`UPDATE_MANIFEST_VERSION_INCONSISTENT`）。
  static ReleaseVersionSet? tryParse({
    String? version,
    Object? buildNumber,
    String? msixVersion,
    String? tag,
  }) {
    final semantic = SemVer.tryParse(version);
    final msix = MsixVersion.tryParse(msixVersion);
    if (semantic == null ||
        msix == null ||
        tag == null ||
        buildNumber is! int ||
        buildNumber <= 0) {
      return null;
    }
    return ReleaseVersionSet(
      version: semantic,
      buildNumber: buildNumber,
      msixVersion: msix,
      tag: tag,
    );
  }

  /// 全部不一致项。空表示这份发布自洽。
  Set<ReleaseVersionIssue> get issues {
    final found = <ReleaseVersionIssue>{};
    if (tag != 'v${version.value}') found.add(ReleaseVersionIssue.tagMismatch);
    if (msixVersion.semanticLabel != version.value) {
      found.add(ReleaseVersionIssue.msixSemverMismatch);
    }
    return found;
  }

  bool get isConsistent => issues.isEmpty;
}

/// 版本字段之间的不一致类型。仅用于测试与结构化日志，**不直接展示给用户**。
enum ReleaseVersionIssue { tagMismatch, msixSemverMismatch }
