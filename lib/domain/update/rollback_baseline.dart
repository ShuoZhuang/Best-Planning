// 回退基线与数据快照的领域事实（规格 §13.3 / §13.4）。
//
// 回退不是"再装一次旧包"这么简单：只有当**旧包有效**且**更新前快照完整**时，回退才是安全的。
// 因此基线把两样东西绑在同一个对象里——只保留其中之一的实现会在失败时才发现缺另一半。
import 'package:personal_planner/domain/update/update_version.dart';

/// 当前稳定版本的回退基线。
final class RollbackBaseline {
  const RollbackBaseline({
    required this.version,
    required this.packagePath,
    required this.sha256,
    required this.sizeBytes,
    required this.createdAtUtc,
    this.snapshotPath,
    this.snapshotSha256,
  });

  /// 基线对应的 MSIX 版本。每次成功更新后，本次目标包成为新的当前基线。
  final MsixVersion version;

  /// 已验证的 `.ready` 包规范路径。
  final String packagePath;

  final String sha256;
  final int sizeBytes;
  final String? snapshotPath;
  final String? snapshotSha256;
  final DateTime createdAtUtc;

  bool get hasSnapshot => snapshotPath != null && snapshotSha256 != null;

  /// 是否足够支撑一次回退（规格 §13.4 的"直接上一版本包有效 + 更新前快照完整"）。
  bool get isUsable => packagePath.isNotEmpty && sha256.length == 64;

  RollbackBaseline copyWith({
    MsixVersion? version,
    String? packagePath,
    String? sha256,
    int? sizeBytes,
    String? snapshotPath,
    String? snapshotSha256,
    DateTime? createdAtUtc,
  }) => RollbackBaseline(
    version: version ?? this.version,
    packagePath: packagePath ?? this.packagePath,
    sha256: sha256 ?? this.sha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    snapshotPath: snapshotPath ?? this.snapshotPath,
    snapshotSha256: snapshotSha256 ?? this.snapshotSha256,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
  );

  Map<String, Object?> toJson() => {
    'version': version.value,
    'packagePath': packagePath,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'snapshotPath': snapshotPath,
    'snapshotSha256': snapshotSha256,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
  };

  static RollbackBaseline? tryParse(Object? json) {
    if (json is! Map) return null;
    final version = MsixVersion.tryParse(json['version'] as String?);
    final packagePath = json['packagePath'];
    final sha256 = json['sha256'];
    final sizeBytes = json['sizeBytes'];
    final createdAt = json['createdAtUtc'];
    if (version == null ||
        packagePath is! String ||
        sha256 is! String ||
        sizeBytes is! int ||
        createdAt is! String) {
      return null;
    }
    final created = DateTime.tryParse(createdAt);
    if (created == null) return null;
    final snapshotPath = json['snapshotPath'];
    final snapshotSha256 = json['snapshotSha256'];
    return RollbackBaseline(
      version: version,
      packagePath: packagePath,
      sha256: sha256,
      sizeBytes: sizeBytes,
      createdAtUtc: created.toUtc(),
      snapshotPath: snapshotPath is String ? snapshotPath : null,
      snapshotSha256: snapshotSha256 is String ? snapshotSha256 : null,
    );
  }

  @override
  String toString() => 'RollbackBaseline(${version.value}, $packagePath)';
}
