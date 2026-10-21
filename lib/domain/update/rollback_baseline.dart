// 回退基线的领域事实（规格 §13.3 / §13.4；1.11.1 修复 §4.4）。
//
// **基线只表示"当前已安装版本的已验证回退包"**。1.11.0 的模型里还带着"更新前数据快照"
// 字段，但下载基线时快照并不存在（它属于某一次具体安装事务），注释因此与事实不符
// （UPD-INC-020）。1.11.1 把快照彻底交给 `UpdateInstallService` 生成并写进 update request，
// 基线对象只保留"包"这一件事。
import 'package:personal_planner/domain/update/update_version.dart';

/// 当前已安装版本的回退基线。
final class RollbackBaseline {
  const RollbackBaseline({
    required this.version,
    required this.packagePath,
    required this.sha256,
    required this.sizeBytes,
    required this.createdAtUtc,
  });

  /// 基线对应的 MSIX 版本。健康确认成功后，本次目标包晋升为新的当前基线。
  final MsixVersion version;

  /// 已验证的回退包规范路径（必须位于更新根目录内）。
  final String packagePath;

  final String sha256;
  final int sizeBytes;
  final DateTime createdAtUtc;

  /// 是否具备回退所需的**形状**条件；真正的可用性必须走严格校验（版本、路径、长度、
  /// SHA-256、包身份、发布者），不能只用这个 getter 判断。
  bool get isUsable => packagePath.isNotEmpty && sha256.length == 64;

  RollbackBaseline copyWith({
    MsixVersion? version,
    String? packagePath,
    String? sha256,
    int? sizeBytes,
    DateTime? createdAtUtc,
  }) => RollbackBaseline(
    version: version ?? this.version,
    packagePath: packagePath ?? this.packagePath,
    sha256: sha256 ?? this.sha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
  );

  Map<String, Object?> toJson() => {
    'version': version.value,
    'packagePath': packagePath,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
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
    // 旧版本写入的 `snapshotPath` / `snapshotSha256` 被忽略：快照属于安装事务，
    // 不属于基线。保留解析宽容度只是为了让旧状态文件仍可迁移，不是继续承认它的语义。
    return RollbackBaseline(
      version: version,
      packagePath: packagePath,
      sha256: sha256,
      sizeBytes: sizeBytes,
      createdAtUtc: created.toUtc(),
    );
  }

  @override
  String toString() => 'RollbackBaseline(${version.value}, $packagePath)';
}
