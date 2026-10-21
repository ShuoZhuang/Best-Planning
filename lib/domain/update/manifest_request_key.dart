// 清单请求身份（1.11.1 事故修复 §4.1）。
//
// 事故的直接原因不是"缓存坏了"，而是**两种语义不同的请求共用了同一个缓存槽**：
//   · `latestStable`：stable 通道现在最新是什么；
//   · `releaseTag(tag)`：某个不可变历史版本自己的清单是什么（回退基线用）。
//
// 因此请求身份必须是一等类型：它同时决定缓存文件路径、`If-None-Match` 的归属，以及
// `304` 允许读取哪一份实体。**文件名只能由枚举与已验证 tag 生成**，绝不能用远端 URL 文本，
// 否则 `../` 就能把缓存写到目录之外。
import 'package:personal_planner/domain/update/update_manifest.dart';

/// 清单请求的两种语义。首版只有这两类，未来扩展也必须是枚举成员。
enum ManifestRequestKind {
  /// "stable 通道现在最新是什么"。地址固定，内容可变。
  latestStable,

  /// "tag `vX.Y.Z` 的不可变历史清单是什么"。地址与内容都固定。
  releaseTag,
}

/// 一次清单请求的稳定身份。
final class ManifestRequestKey {
  const ManifestRequestKey.latestStable()
    : kind = ManifestRequestKind.latestStable,
      tag = null;

  /// 用 tag 构造请求身份。非法 tag 直接抛 [ArgumentError]：**非法输入不产生文件名**。
  factory ManifestRequestKey.releaseTag(String tag) {
    final parsed = tryReleaseTag(tag);
    if (parsed == null) {
      throw ArgumentError.value(tag, 'tag', '不是合法的发布 tag（应为 vX.Y.Z）');
    }
    return parsed;
  }

  const ManifestRequestKey._({required this.kind, this.tag});

  /// tag 的严格格式：`v` + 三段无前导零数字。与清单/版本模型保持同一套规则。
  static final RegExp _tagPattern = RegExp(
    r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  /// 合法则返回请求身份，否则 `null`（用于解析不可信输入的路径）。
  static ManifestRequestKey? tryReleaseTag(String? tag) {
    if (tag == null || !_tagPattern.hasMatch(tag)) return null;
    return ManifestRequestKey._(kind: ManifestRequestKind.releaseTag, tag: tag);
  }

  static ManifestRequestKey? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    if (kind == 'latestStable') return const ManifestRequestKey.latestStable();
    if (kind == 'releaseTag') {
      final tag = json['tag'];
      if (tag is! String) return null;
      return tryReleaseTag(tag);
    }
    return null;
  }

  final ManifestRequestKind kind;

  /// 只有 [ManifestRequestKind.releaseTag] 时非空，且已通过 [_tagPattern]。
  final String? tag;

  bool get isLatestStable => kind == ManifestRequestKind.latestStable;

  /// 缓存文件名与诊断键：`latest-stable` / `tag-v1.10.2`。**只由枚举与已验证 tag 生成**。
  String get storageKey => switch (kind) {
    ManifestRequestKind.latestStable => 'latest-stable',
    ManifestRequestKind.releaseTag => 'tag-$tag',
  };

  /// 相对缓存根的路径（`/` 分隔，落到磁盘时按平台分隔符拼接）。
  String get relativePath => switch (kind) {
    ManifestRequestKind.latestStable => 'manifests/latest-stable.json',
    ManifestRequestKind.releaseTag => 'manifests/tags/$tag.json',
  };

  /// 固定请求地址：latest 是仓库固定地址，tag 是不可变下载地址。
  Uri get canonicalUri => switch (kind) {
    ManifestRequestKind.latestStable => Uri.parse(updateManifestLatestUrl),
    ManifestRequestKind.releaseTag => updateManifestUrlForTag(tag!),
  };

  String get canonicalRequestUrl => canonicalUri.toString();

  /// 界面可显示的中文来源名：不包含 URL、查询串或临时重定向。
  String get label => switch (kind) {
    ManifestRequestKind.latestStable => 'GitHub 稳定通道',
    ManifestRequestKind.releaseTag => 'GitHub 发布 $tag',
  };

  Map<String, Object?> toJson() => switch (kind) {
    ManifestRequestKind.latestStable => const {'kind': 'latestStable'},
    ManifestRequestKind.releaseTag => {'kind': 'releaseTag', 'tag': tag},
  };

  @override
  bool operator ==(Object other) =>
      other is ManifestRequestKey && other.kind == kind && other.tag == tag;

  @override
  int get hashCode => Object.hash(kind, tag);

  @override
  String toString() => 'ManifestRequestKey($storageKey)';
}
