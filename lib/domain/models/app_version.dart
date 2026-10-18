// Flutter 版本号 `<major>.<minor>.<patch>[+build]` 的领域表示。
//
// **它不再是更新判断的依据**：自更新协议只看 Windows 包版本（`MsixVersion`）。这个类型现在
// 只服务于两件事：备份清单里记录"是哪个构建写的"，以及界面上的版本显示。
//
// 因此它留在 `domain/models/`，而更新协议自己的版本类型在 `domain/update/update_version.dart`。
final class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.build});

  final int major;
  final int minor;
  final int patch;

  /// `1.6.2+37` 里的 `37`。**不参与比较**：把构建号算进大小会让
  /// `1.6.2+37` 大于 `1.6.3`（37 > 3），那是错的。
  final int? build;

  /// 解析版本串；不合法返回 `null`。
  ///
  /// 接受：`1.7.0`、`v1.7.0`、`1.6.2+37`。
  /// 拒绝：`1.7`、`1.7.0.1`、`nightly`、``（`1.7` 若被接受会与 `1.7.0` 混淆）。
  static AppVersion? parse(String? raw) {
    if (raw == null) return null;
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      build: match.group(4) == null ? null : int.parse(match.group(4)!),
    );
  }

  String get label => '$major.$minor.$patch';

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => build == null ? label : '$label+$build';
}
