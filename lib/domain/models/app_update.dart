// 更新检查的领域模型（路线图 §5「更新模型」/ §11 Task 10）。
//
// 这一层只表达事实与规则，不碰网络也不碰设置存储。它存在的理由是**版本号的解析与比较被三处
// 共用**：GitHub 客户端（解析 tag）、更新服务（比大小）、更新页（显示与"跳过此版本"）。
// 三处各写一遍 `split('.')` 就会各自漏掉 `v` 前缀、构建号 `+37` 或非法 tag 中的一种。
import 'dart:convert';

import 'package:personal_planner/domain/repositories/settings_repository.dart';

/// 本应用用来做更新判断的版本号：`<major>.<minor>.<patch>[+<构建号>]`。
///
/// **只用于比较与显示，不冒充安装包版本**。真实的安装版本从 `package_info_plus` 读
/// （见 `AppVersionProvider`），因为手写常量会漂移——备份清单里记的版本与用户实际装的版本
/// 不符，而界面又拿它去和 GitHub 的 tag 比大小。
final class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.build});

  final int major;
  final int minor;
  final int patch;

  /// `1.6.2+37` 里的 `37`。**不参与比较**，只用于显示：把构建号算进大小会让
  /// `1.6.2+37` 大于 `1.6.3`（37 > 3），那是错的。
  final int? build;

  /// 解析一个 tag 或版本串；**不合法时返回 `null` 而不是抛异常**。
  ///
  /// 调用方分别是"遍历 GitHub 返回的一串 tag"与"读用户可手改的设置"。两处都可能遇到
  /// 不合法输入，而**跳过一条**与**整次检查失败**的后果差别很大：前者只是少考虑一个 release，
  /// 后者会让用户看到"检查更新失败"。
  ///
  /// 刻意接受的形式：`1.7.0`、`v1.7.0`、`1.6.2+37`。
  /// 刻意拒绝的形式：`1.7`、`1.7.0.1`、`nightly`、``（GitHub 上确实存在这类 tag，
  /// 而 `1.7` 若被接受就会与 `1.7.0` 混淆——它们不是同一个版本）。
  static AppVersion? parse(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
        .firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      build: match.group(4) == null ? null : int.parse(match.group(4)!),
    );
  }

  /// 三段数字，用于显示（不带 `v`，也不带构建号）。与 GitHub 上的 tag 比较时用这个形式。
  String get label => '$major.$minor.$patch';

  /// 只比三段数字。**构建号不参与**：`1.6.2+37` 与 `1.6.2` 是同一个版本。
  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  bool operator <(AppVersion other) => compareTo(other) < 0;

  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  bool operator <=(AppVersion other) => compareTo(other) <= 0;

  /// **相等只看三段数字**：`v1.7.0`、`1.7.0`、`1.7.0+5` 相等。这样"跳过此版本"用
  /// 用户手写的值与 GitHub 的 tag 去比时不会因为带不带 `v` 而失效。
  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => build == null ? label : '$label+$build';
}

/// 一条 GitHub Release 里本应用真正会用到的东西。
///
/// **draft 与 prerelease 的条目根本不会到这里**：客户端已经把它们丢掉（§3.6）。这里不保留
/// 那两个布尔，是因为"保留但忘了判断"正是这类字段最常见的失败方式——模型里没有，就写不出
/// 那种漏判。
final class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.notes,
    this.publishedAtUtc,
    this.htmlUrl,
  });

  /// 原始 tag，例如 `v1.7.0`。显示时用 [version]，因为 tag 可能带 `v` 也可能不带。
  final String tagName;
  final AppVersion version;

  /// 更新说明正文。GitHub 上可以是空字符串（有的 Release 没写正文）。
  final String notes;

  final DateTime? publishedAtUtc;

  /// Release 页面地址。**为 `null` 时界面不显示"查看下载"**：宁可少一个按钮，
  /// 也不要给一个打开不了或指向别处的链接。
  final String? htmlUrl;
}

/// 更新检查的结论。前六种是"有结论"的，[failed] 是失败。
enum UpdateCheckOutcome {
  /// 有更高的正式版本。
  updateAvailable,

  /// 已经是最新（或只有更低版本、draft、prerelease）。
  upToDate,

  /// 有更新，但这个版本被用户跳过过。**跳过的是这一个版本**，更高版本会重新变成
  /// [updateAvailable]（§3.6）。
  skippedVersion,

  /// 自动检查被关掉了，本次没有发请求。
  disabled,

  /// 还在 24 小时窗口内，本次没有发请求。
  throttled,

  /// 请求发了但没有结论。原因见 `UpdateCheckResult.failure`。
  failed,
}

/// 失败原因。**刻意是一组固定的枚举，而不是异常对象的字符串**。
///
/// 理由与 `backup_page.dart` 里那条修正完全一样：界面上显示 `$error` 时，Dart 的
/// `FileSystemException`／`SocketException` 会连**完整路径与主机名**一起显示出来，而那句话
/// 对用户没有任何用。这里让"能显示的原因"只有这几种，界面就无法泄漏别的东西。
enum UpdateFailureReason {
  /// 10 秒超时。
  timeout('请求超时'),

  /// 断网、DNS 失败、连接被关闭。
  offline('网络不可用'),

  /// GitHub 的 403／429：匿名额度用完了。
  rateLimited('GitHub 暂时限制了请求'),

  /// 404 与其他非 200。
  serverError('更新服务器返回了错误'),

  /// 响应不是预期的 JSON。
  malformedResponse('更新信息格式异常'),

  /// 兜底。**存在的意义**：让"没预料到的异常"也走同一条结构化通道，
  /// 而不是被原样抛到界面上。
  unknown('检查更新失败');

  const UpdateFailureReason(this.label);

  /// 给用户看的一句话。自动与手动两种检查都用它，因此失败文案只有一处。
  final String label;
}

/// 客户端与服务之间唯一的失败通道。
final class UpdateCheckException implements Exception {
  const UpdateCheckException(this.reason);

  final UpdateFailureReason reason;

  @override
  String toString() => 'UpdateCheckException(${reason.name})';
}

/// 一次检查的结论。
final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.outcome,
    this.currentVersion,
    this.version,
    this.release,
    this.failure,
  });

  const UpdateCheckResult.upToDate({this.currentVersion})
    : outcome = UpdateCheckOutcome.upToDate,
      version = null,
      release = null,
      failure = null;

  const UpdateCheckResult.disabled({this.currentVersion})
    : outcome = UpdateCheckOutcome.disabled,
      version = null,
      release = null,
      failure = null;

  const UpdateCheckResult.throttled({this.currentVersion})
    : outcome = UpdateCheckOutcome.throttled,
      version = null,
      release = null,
      failure = null;

  const UpdateCheckResult.failed({
    required UpdateFailureReason this.failure,
    this.currentVersion,
  }) : outcome = UpdateCheckOutcome.failed,
       version = null,
       release = null;

  final UpdateCheckOutcome outcome;

  /// 当前安装版本；读不出来时为 `null`（界面据此不显示版本行，而不是编一个 `0.0.0`）。
  final AppVersion? currentVersion;

  /// 有更新时是**那个**版本；否则为 `null`。
  final AppVersion? version;

  final ReleaseInfo? release;

  /// 只在 [outcome] 为 [UpdateCheckOutcome.failed] 时有值。
  final UpdateFailureReason? failure;

  /// 界面上"有更新"这一档。集中判定，避免页面重复写三个条件的与。
  bool get hasUpdate => outcome == UpdateCheckOutcome.updateAvailable;
}

/// 更新检查的持久设置。字段名与 §11 Task 10 的接口一一对应。
final class UpdateSettings {
  const UpdateSettings({
    this.autoCheckEnabled = true,
    this.lastCheckedUtc,
    this.skippedVersion,
    this.etag,
  });

  /// **默认开启**（§3.6）。默认值写在这里而不是界面里：页面、调度器与组合根三处都从
  /// 这一个常量取值，因此"默认开"只有一处实现。
  final bool autoCheckEnabled;

  final DateTime? lastCheckedUtc;

  /// 用户点过"跳过此版本"的那个版本号，形如 `1.7.0`。
  final String? skippedVersion;

  /// 上次响应的 ETag。带上它去问，没变就是 304，既省带宽也省 GitHub 的匿名额度。
  final String? etag;

  /// **清空型字段用显式的 `clear*` 开关**，不靠"传 null"：`lastCheckedUtc` 与 `etag`
  /// 本身可空，传 null 到底是"不改"还是"清掉"无法从调用处看出来——那正是这类 copyWith
  /// 最常出的错。
  UpdateSettings copyWith({
    bool? autoCheckEnabled,
    DateTime? lastCheckedUtc,
    String? skippedVersion,
    String? etag,
    bool clearLastChecked = false,
    bool clearSkippedVersion = false,
    bool clearEtag = false,
  }) => UpdateSettings(
    autoCheckEnabled: autoCheckEnabled ?? this.autoCheckEnabled,
    lastCheckedUtc: clearLastChecked
        ? null
        : (lastCheckedUtc ?? this.lastCheckedUtc),
    skippedVersion: clearSkippedVersion
        ? null
        : (skippedVersion ?? this.skippedVersion),
    etag: clearEtag ? null : (etag ?? this.etag),
  );
}

/// 设置的读写端口。
abstract interface class UpdateSettingsStore {
  Future<UpdateSettings> load();

  Future<void> save(UpdateSettings settings);
}

/// 写进 `SettingsRepository` 的实现：一条键、一段 JSON。
///
/// 与 `WeekViewPreferenceService`、`AnalyticsChartPreferenceService` 同一形状
/// （`SettingsRepository` + JSON + **读失败回默认**）。
final class JsonUpdateSettingsStore implements UpdateSettingsStore {
  const JsonUpdateSettingsStore({required this.settings});

  /// 设置键。**带 `.v1`**：将来字段含义变了可以换键，而不是让旧值被按新规则解释。
  static const String storageKey = 'update.check.v1';

  final SettingsRepository settings;

  @override
  Future<UpdateSettings> load() async {
    try {
      final raw = await settings.read(storageKey);
      if (raw == null || raw.isEmpty) return const UpdateSettings();
      final json = jsonDecode(raw);
      if (json is! Map) return const UpdateSettings();
      return UpdateSettings(
        // 键在但类型不对时按默认处理。`autoCheckEnabled` 的默认值是**开启**，而"读不出来就
        // 关掉"会让一次写入失败永久关掉自动检查——用户没关过，却再也不会自动检查。
        autoCheckEnabled: json['autoCheckEnabled'] is bool
            ? json['autoCheckEnabled'] as bool
            : true,
        lastCheckedUtc: _parseUtc(json['lastCheckedUtc']),
        skippedVersion: _parseSkipped(json['skippedVersion']),
        etag: json['etag'] is String ? json['etag'] as String : null,
      );
    } on Object {
      // 设置可能来自旧版本、被手改过或写坏。回默认，而不是让更新页打不开。
      return const UpdateSettings();
    }
  }

  @override
  Future<void> save(UpdateSettings value) async {
    await settings.write(
      storageKey,
      jsonEncode({
        'autoCheckEnabled': value.autoCheckEnabled,
        'lastCheckedUtc': value.lastCheckedUtc?.toUtc().toIso8601String(),
        'skippedVersion': value.skippedVersion,
        'etag': value.etag,
      }),
    );
  }
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// 跳过版本只接受**能解析的版本号**。
///
/// 一个 `"latest"` 这样的值若被原样保留，就永远不会与任何 release 相等，于是"跳过"看起来
/// 生效（不再提醒）却其实压不住任何东西——**静默失效**。宁可不认它，按"没跳过"处理。
String? _parseSkipped(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return AppVersion.parse(raw)?.label;
}
