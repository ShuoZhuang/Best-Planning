// 签名清单的严格模型（规格 §6.2 / §6.3 / §6.4）。
//
// 解析在这里，**验签不在这一层**：规范化与 Ed25519 属于基础设施（`json_canonicalizer.dart`
// 与 `ed25519_manifest_verifier.dart`），领域层只描述"清单长什么样、哪些字段必须一致"。
//
// 严格性是刻意的：Schema 1 对未知字段一律拒绝。理由不是洁癖——签名保护的是**字节**，
// 如果客户端接受"认识一部分、忽略其余"，签名就只保护了被认识的那部分，协议扩展可以悄悄
// 搭车；而拒绝未知字段会让这种情况变成一个显式的版本升级。
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_version.dart';

/// 本客户端支持的清单 Schema 版本。
const int updateManifestSchemaVersion = 1;

/// 首版唯一通道。
const String updateChannelStable = 'stable';

/// 稳定版最新清单地址（规格 §6.1）。**写死在代码里**，不做成参数。
const String updateManifestLatestUrl =
    'https://github.com/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json';

/// 仓库根。清单里的下载地址必须落在它下面。
const String updateRepositoryUrl =
    'https://github.com/ShuoZhuang/Best-Planning';

/// 指定版本不可变清单地址。
Uri updateManifestUrlForTag(String tag) => Uri.parse(
  '$updateRepositoryUrl/releases/download/$tag/update-manifest.json',
);

/// 签名段。首版只接受 `Ed25519`。
final class ManifestSignature {
  const ManifestSignature({
    required this.algorithm,
    required this.keyId,
    required this.value,
  });

  static const String supportedAlgorithm = 'Ed25519';

  final String algorithm;
  final String keyId;

  /// Base64 编码的 64 字节签名。
  final String value;

  static const Set<String> _keys = {'algorithm', 'keyId', 'value'};

  /// 解析签名段；结构不合法返回 `null`，算法不受支持返回 [ManifestParseFailure]。
  static Object? tryParse(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, Object?>();
    final keys = map.keys.toSet();
    if (keys.any((key) => !_keys.contains(key))) return null;
    if (!keys.containsAll(_keys)) return null;
    final algorithm = map['algorithm'];
    final keyId = map['keyId'];
    final value = map['value'];
    if (algorithm is! String || keyId is! String || value is! String) {
      return null;
    }
    if (algorithm != supportedAlgorithm) {
      return const ManifestParseFailure(
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    }
    if (keyId.isEmpty || keyId.length > 64) return null;
    if (!_isBase64(value)) return null;
    return ManifestSignature(algorithm: algorithm, keyId: keyId, value: value);
  }

  static bool _isBase64(String value) {
    if (value.isEmpty || value.length % 4 != 0) return false;
    return RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(value);
  }
}

/// 清单信封：`{ payload, signature }`。
///
/// [payloadJson] **保留原始解码结果**。验签必须对原始字节对应的规范化结果进行，而不是对
/// "解析后再序列化"的对象——后者会悄悄丢掉解析器不认识的字段，而那正是签名要覆盖的东西。
final class UpdateManifestEnvelope {
  const UpdateManifestEnvelope({
    required this.payloadJson,
    required this.signature,
  });

  final Map<String, Object?> payloadJson;
  final ManifestSignature signature;

  static const Set<String> _keys = {'payload', 'signature'};

  /// 解析信封结构与签名段。
  ///
  /// 返回 [UpdateManifestEnvelope] 或 [ManifestParseFailure]，无法判断时返回 `null`。
  static Object? tryParse(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, Object?>();
    final keys = map.keys.toSet();
    if (keys.any((key) => !_keys.contains(key))) {
      // 外层多一个字段就意味着"协议扩展了"，拒绝而不是忽略。
      return const ManifestParseFailure(
        UpdateFailureCode.manifestSchemaUnsupported,
      );
    }
    if (!keys.containsAll(_keys)) return null;
    final payload = map['payload'];
    if (payload is! Map) return null;
    final signature = ManifestSignature.tryParse(map['signature']);
    if (signature is ManifestParseFailure) return signature;
    if (signature is! ManifestSignature) return null;
    return UpdateManifestEnvelope(
      payloadJson: payload.cast<String, Object?>(),
      signature: signature,
    );
  }
}

/// 一次解析失败。[code] 是唯一的失败事实。
final class ManifestParseFailure {
  const ManifestParseFailure(this.code);

  final UpdateFailureCode code;
}

/// 发布信息段。
final class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.buildNumber,
    required this.msixVersion,
    required this.tag,
    required this.publishedAtUtc,
  });

  final SemVer version;
  final int buildNumber;
  final MsixVersion msixVersion;
  final String tag;
  final DateTime publishedAtUtc;
}

/// 兼容性段。是否与本机相符由 `compatibility.mismatches` 判断，解析层只校验形状。
final class UpdateCompatibility {
  const UpdateCompatibility({
    required this.architecture,
    required this.minimumWindowsBuild,
    required this.packageIdentityName,
    required this.packageFamilyName,
    required this.publisher,
  });

  final String architecture;
  final MsixVersion minimumWindowsBuild;
  final String packageIdentityName;
  final String packageFamilyName;
  final String publisher;

  CompatibilityAssessment get assessment => CompatibilityAssessment(
    identityName: packageIdentityName,
    publisher: publisher,
    familyName: packageFamilyName,
    architecture: architecture,
    minimumWindowsBuild: minimumWindowsBuild,
  );

  /// 与客户端事实不符的项。
  Set<CompatibilityMismatch> get mismatches => assessment.mismatches;

  bool get matchesClient => mismatches.isEmpty;
}

/// 安装包段。
final class UpdatePackage {
  const UpdatePackage({
    required this.fileName,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.sha256,
  });

  /// 必须与 Release Asset 完全一致，且只能是单段安全文件名。
  final String fileName;

  /// 必须是同仓库、同 Tag、同文件名的不可变地址。
  final String downloadUrl;

  final int sizeBytes;

  /// 64 位小写十六进制。
  final String sha256;

  /// 下载地址的路径（用于断点续传/日志，不含查询串）。
  Uri get downloadUri => Uri.parse(downloadUrl);
}

/// 展示段。**只作为纯文本渲染**，禁止 HTML/Markdown/任意链接协议。
final class UpdatePresentation {
  const UpdatePresentation({
    required this.title,
    required this.summary,
    required this.releaseUrl,
  });

  final String title;
  final String summary;
  final String releaseUrl;
}

/// 通过严格解析的清单。
final class UpdateManifest {
  const UpdateManifest({
    required this.schemaVersion,
    required this.channel,
    required this.release,
    required this.compatibility,
    required this.package,
    required this.presentation,
    required this.revokedVersions,
    required this.signature,
  });

  final int schemaVersion;
  final String channel;
  final UpdateRelease release;
  final UpdateCompatibility compatibility;
  final UpdatePackage package;
  final UpdatePresentation presentation;
  final List<MsixVersion> revokedVersions;
  final ManifestSignature signature;

  MsixVersion get msixVersion => release.msixVersion;

  SemVer get semanticVersion => release.version;

  String get tag => release.tag;

  /// 该版本是否被发布方撤回。
  bool get isRevoked => revokedVersions.contains(release.msixVersion);

  /// 候选版本是否严格高于当前已安装版本（规格 §6.6）。
  bool isNewerThan(MsixVersion current) => release.msixVersion > current;

  /// 与当前已安装版本的关系。
  UpdateVersionRelation relationTo(MsixVersion current) {
    final order = release.msixVersion.compareTo(current);
    if (order > 0) return UpdateVersionRelation.newer;
    if (order == 0) return UpdateVersionRelation.same;
    return UpdateVersionRelation.older;
  }
}

/// 候选版本与当前版本的关系。
enum UpdateVersionRelation { newer, same, older }

/// 清单解析结果。
final class ManifestParseResult {
  const ManifestParseResult.success(this.manifest)
    : failure = null;

  const ManifestParseResult.failure(this.failure) : manifest = null;

  final UpdateManifest? manifest;
  final ManifestParseFailure? failure;

  bool get isSuccess => manifest != null;
}

/// 解析清单 payload（签名已单独验证通过，或即将被验证）。
///
/// **调用顺序**：先由信封拿到原始 payload，再对它做 RFC 8785 规范化并验签，最后调用这里做
/// 严格解析。这样做的好处是：一个自相矛盾但签名正确的清单会得到
/// `UPDATE_MANIFEST_VERSION_INCONSISTENT`，而不是"签名无效"——诊断页能说清楚是谁的问题。
ManifestParseResult parseUpdateManifestPayload(
  Map<String, Object?> payload, {
  required ManifestSignature signature,
}) {
  const keys = {
    'schemaVersion',
    'channel',
    'release',
    'compatibility',
    'package',
    'presentation',
    'revokedVersions',
  };
  final payloadKeyFailure = _checkKeys(payload, keys);
  if (payloadKeyFailure != null) {
    return ManifestParseResult.failure(payloadKeyFailure);
  }

  final schemaVersion = payload['schemaVersion'];
  if (schemaVersion is! int) {
    return _invalidJson();
  }
  if (schemaVersion != updateManifestSchemaVersion) {
    return const ManifestParseResult.failure(
      ManifestParseFailure(UpdateFailureCode.manifestSchemaUnsupported),
    );
  }
  final channel = payload['channel'];
  if (channel is! String) return _invalidJson();
  if (channel != updateChannelStable) {
    return const ManifestParseResult.failure(
      ManifestParseFailure(UpdateFailureCode.manifestSchemaUnsupported),
    );
  }

  final release = _parseRelease(payload['release']);
  if (release is ManifestParseFailure) {
    return ManifestParseResult.failure(release);
  }
  if (release is! UpdateRelease) return _invalidJson();

  final compatibility = _parseCompatibility(payload['compatibility']);
  if (compatibility is ManifestParseFailure) {
    return ManifestParseResult.failure(compatibility);
  }
  if (compatibility is! UpdateCompatibility) return _invalidJson();

  final package = _parsePackage(payload['package']);
  if (package is ManifestParseFailure) {
    return ManifestParseResult.failure(package);
  }
  if (package is! UpdatePackage) return _invalidJson();

  final presentation = _parsePresentation(payload['presentation']);
  if (presentation is ManifestParseFailure) {
    return ManifestParseResult.failure(presentation);
  }
  if (presentation is! UpdatePresentation) return _invalidJson();

  final revokedRaw = payload['revokedVersions'];
  if (revokedRaw is! List) return _invalidJson();
  final revoked = <MsixVersion>[];
  for (final item in revokedRaw) {
    if (item is! String) return _invalidJson();
    final version = MsixVersion.tryParse(item);
    if (version == null) return _invalidJson();
    revoked.add(version);
  }

  // 版本自洽性：SemVer / build / MSIX / tag 必须互相一致（规格 §6.6）。
  final versionSet = ReleaseVersionSet.tryParse(
    version: release.version.value,
    buildNumber: release.buildNumber,
    msixVersion: release.msixVersion.value,
    tag: release.tag,
  );
  if (versionSet == null || !versionSet.isConsistent) {
    return const ManifestParseResult.failure(
      ManifestParseFailure(UpdateFailureCode.manifestVersionInconsistent),
    );
  }

  // 下载地址与展示地址必须与 tag/文件名自洽，且落在允许的仓库路径下（规格 §6.4）。
  final expectedDownload = Uri.parse(
    '$updateRepositoryUrl/releases/download/${release.tag}/${package.fileName}',
  );
  if (Uri.parse(package.downloadUrl) != expectedDownload) {
    return const ManifestParseResult.failure(
      ManifestParseFailure(UpdateFailureCode.manifestSourceNotAllowed),
    );
  }
  final expectedReleasePage = Uri.parse(
    '$updateRepositoryUrl/releases/tag/${release.tag}',
  );
  if (Uri.parse(presentation.releaseUrl) != expectedReleasePage) {
    return const ManifestParseResult.failure(
      ManifestParseFailure(UpdateFailureCode.manifestSourceNotAllowed),
    );
  }

  return ManifestParseResult.success(
    UpdateManifest(
      schemaVersion: schemaVersion,
      channel: channel,
      release: release,
      compatibility: compatibility,
      package: package,
      presentation: presentation,
      revokedVersions: List.unmodifiable(revoked),
      signature: signature,
    ),
  );
}

Object? _parseRelease(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, Object?>();
  const keys = {'version', 'buildNumber', 'msixVersion', 'tag', 'publishedAtUtc'};
  final keyFailure = _checkKeys(map, keys);
  if (keyFailure != null) return keyFailure;
  final version = map['version'];
  final buildNumber = map['buildNumber'];
  final msixVersion = map['msixVersion'];
  final tag = map['tag'];
  final publishedAtUtc = map['publishedAtUtc'];
  if (version is! String ||
      buildNumber is! int ||
      msixVersion is! String ||
      tag is! String ||
      publishedAtUtc is! String) {
    return null;
  }
  final set = ReleaseVersionSet.tryParse(
    version: version,
    buildNumber: buildNumber,
    msixVersion: msixVersion,
    tag: tag,
  );
  if (set == null) return null;
  if (!set.isConsistent) {
    return const ManifestParseFailure(
      UpdateFailureCode.manifestVersionInconsistent,
    );
  }
  final published = DateTime.tryParse(publishedAtUtc);
  if (published == null) return null;
  return UpdateRelease(
    version: set.version,
    buildNumber: set.buildNumber,
    msixVersion: set.msixVersion,
    tag: set.tag,
    // 统一 UTC：清单写的是 UTC，本地时区只在展示时参与。
    publishedAtUtc: published.toUtc(),
  );
}

Object? _parseCompatibility(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, Object?>();
  const keys = {
    'architecture',
    'minimumWindowsBuild',
    'packageIdentityName',
    'packageFamilyName',
    'publisher',
  };
  final keyFailure = _checkKeys(map, keys);
  if (keyFailure != null) return keyFailure;
  final architecture = map['architecture'];
  final minimumWindowsBuild = map['minimumWindowsBuild'];
  final identityName = map['packageIdentityName'];
  final familyName = map['packageFamilyName'];
  final publisher = map['publisher'];
  if (architecture is! String ||
      minimumWindowsBuild is! String ||
      identityName is! String ||
      familyName is! String ||
      publisher is! String) {
    return null;
  }
  final minimumBuild = MsixVersion.tryParse(minimumWindowsBuild);
  if (minimumBuild == null) return null;
  if (identityName.isEmpty ||
      identityName.length > 50 ||
      familyName.isEmpty ||
      familyName.length > 100 ||
      publisher.isEmpty ||
      publisher.length > 512 ||
      architecture.isEmpty ||
      architecture.length > 16) {
    return null;
  }
  return UpdateCompatibility(
    architecture: architecture,
    minimumWindowsBuild: minimumBuild,
    packageIdentityName: identityName,
    packageFamilyName: familyName,
    publisher: publisher,
  );
}

Object? _parsePackage(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, Object?>();
  const keys = {'fileName', 'downloadUrl', 'sizeBytes', 'sha256'};
  final keyFailure = _checkKeys(map, keys);
  if (keyFailure != null) return keyFailure;
  final fileName = map['fileName'];
  final downloadUrl = map['downloadUrl'];
  final sizeBytes = map['sizeBytes'];
  final sha256 = map['sha256'];
  if (fileName is! String ||
      downloadUrl is! String ||
      sizeBytes is! int ||
      sha256 is! String) {
    return null;
  }
  if (sizeBytes <= 0 || sizeBytes > 4 * 1024 * 1024 * 1024) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.msix$').hasMatch(fileName)) {
    return null;
  }
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) return null;
  final uri = Uri.tryParse(downloadUrl);
  if (uri == null || !uri.isScheme('https')) {
    return const ManifestParseFailure(
      UpdateFailureCode.manifestSourceNotAllowed,
    );
  }
  return UpdatePackage(
    fileName: fileName,
    downloadUrl: downloadUrl,
    sizeBytes: sizeBytes,
    sha256: sha256,
  );
}

Object? _parsePresentation(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, Object?>();
  const keys = {'title', 'summary', 'releaseUrl'};
  final keyFailure = _checkKeys(map, keys);
  if (keyFailure != null) return keyFailure;
  final title = map['title'];
  final summary = map['summary'];
  final releaseUrl = map['releaseUrl'];
  if (title is! String || summary is! String || releaseUrl is! String) {
    return null;
  }
  if (title.trim().isEmpty || title.length > 120 || summary.length > 500) {
    return null;
  }
  if (!_isPlainText(title) || !_isPlainText(summary)) return null;
  final uri = Uri.tryParse(releaseUrl);
  if (uri == null || !uri.isScheme('https')) {
    return const ManifestParseFailure(
      UpdateFailureCode.manifestSourceNotAllowed,
    );
  }
  return UpdatePresentation(
    title: title,
    summary: summary,
    releaseUrl: releaseUrl,
  );
}

/// 展示文本只允许纯文本：拒绝 NUL 与其他控制字符（换行保留给摘要）。
bool _isPlainText(String value) =>
    !RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]').hasMatch(value);

/// 键集合检查：多一个键是"协议扩展"，少一个键是"结构不合法"。
///
/// 两者都拒绝，但错误码不同——诊断页需要区分"这份清单是给更新版本客户端用的"与"这份清单坏了"。
ManifestParseFailure? _checkKeys(
  Map<String, Object?> map,
  Set<String> expected,
) {
  final keys = map.keys.toSet();
  if (keys.any((key) => !expected.contains(key))) {
    return const ManifestParseFailure(
      UpdateFailureCode.manifestSchemaUnsupported,
    );
  }
  if (!keys.containsAll(expected)) {
    return const ManifestParseFailure(UpdateFailureCode.manifestInvalidJson);
  }
  return null;
}

ManifestParseResult _invalidJson() => const ManifestParseResult.failure(
  ManifestParseFailure(UpdateFailureCode.manifestInvalidJson),
);

