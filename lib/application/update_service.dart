// 更新检查的判定层（路线图 §3.6 / §7.3 / §5 / §11 Task 10）。
//
// 这一层回答三个问题，**每一个都有一种静默做错的方式**：
//   ① 这次到底该不该发请求？——自动检查受 24 小时窗口与开关约束，手动检查不受；
//   ② 拿到的 release 算不算更新？——draft、prerelease、非法 tag、更低版本都不算；
//   ③ 失败该怎么说？——只给一句枚举里的话，绝不把异常对象或本地路径带出去。
//
// **"这次不发请求"必须是真的不发**，而不是"发了再忽略结果"：GitHub 的匿名额度按 IP 计，
// 窗口内的重复请求只会把额度用光，然后用户看到的是"GitHub 暂时限制了请求"——一个由我们自己
// 造成的限流。
import 'package:personal_planner/application/app_version_provider.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/platform/update/github_release_client.dart';

/// 自动检查的最小间隔（§3.6："运行期间最多每 24 小时请求一次"）。
const Duration updateCheckMinimumInterval = Duration(hours: 24);

/// 版本读不出来时的比较基准。
///
/// `0.0.0` 的含义是"任何正式 release 都比它高"，也就是**宁可多提醒一次**。反过来（当成
/// 一个很大的版本）会让所有用户永远收不到更新提示，而那种失败没有任何界面症状。
const AppVersion unknownCurrentVersion = AppVersion(0, 0, 0);

final class UpdateService {
  UpdateService({
    required this.client,
    required this.clock,
    required SettingsRepository settings,
    this.versions,
  }) : _store = JsonUpdateSettingsStore(settings: settings);

  final GithubReleaseClient client;
  final Clock clock;

  /// 运行时版本的读取端口。为 `null` 时按 [unknownCurrentVersion] 比较——这条降级路径是
  /// **必然会发生**的（`package_info_plus` 在测试与未打包环境里读不到元数据），因此它是被
  /// 设计出来的一档，而不是一个"不该发生"的分支。
  final AppVersionProvider? versions;

  final JsonUpdateSettingsStore _store;

  Future<UpdateSettings> loadSettings() => _store.load();

  /// 保存设置。
  ///
  /// **写失败往上抛**（与偏好服务的"读失败回默认"不同）：调用它的地方是用户在页面上拨开关或
  /// 点"跳过此版本"，写不进去就必须让用户知道——静默失败会让"跳过"看起来生效，实际下次启动
  /// 又提醒一遍。
  Future<void> saveSettings(UpdateSettings settings) => _store.save(settings);

  /// 跳过**这一个**版本（§3.6）。更高版本仍然会提示：跳过是按版本号记的，不是"以后都别提醒"。
  Future<void> skipVersion(AppVersion version) async {
    final current = await _store.load();
    await _store.save(current.copyWith(skippedVersion: version.label));
  }

  /// 撤销跳过，让被跳过的版本重新提示。
  Future<void> clearSkippedVersion() async {
    final current = await _store.load();
    if (current.skippedVersion == null) return;
    await _store.save(current.copyWith(clearSkippedVersion: true));
  }

  /// 检查更新。
  ///
  /// [manual] 为 `true` 时**总是立即请求**（§7.3："手动检查总能立即发起"），用户点了一次按钮
  /// 却什么都不发生，比多花一次额度糟得多。
  Future<UpdateCheckResult> check({required bool manual}) async {
    final settings = await _store.load();
    final now = clock.nowUtc();
    if (!manual && !settings.autoCheckEnabled) {
      // **一次请求都不发**，也不动 `lastCheckedUtc`。
      return const UpdateCheckResult.disabled();
    }
    if (!manual && !_windowElapsed(settings.lastCheckedUtc, now)) {
      return const UpdateCheckResult.throttled();
    }

    final currentVersion = await _readCurrentVersion();
    try {
      final response = await client.fetchReleases(etag: settings.etag);
      final release = _latestUsable(
        response.releases,
        currentVersion ?? unknownCurrentVersion,
      );
      final UpdateCheckOutcome outcome;
      if (release == null) {
        outcome = UpdateCheckOutcome.upToDate;
      } else if (AppVersion.parse(settings.skippedVersion) == release.version) {
        // **按版本号比，不按字符串比**：存下来的是 `1.7.0`，而 tag 可能是 `v1.7.0`。
        // 用字符串比会让"跳过"在带 `v` 的 tag 上静默失效。
        // 跳过版本与"有更新"因此合成一档结果，界面只有一个 true 分支，
        // 不会出现"该显示跳过却走了有更新"这种漏判。
        outcome = UpdateCheckOutcome.skippedVersion;
      } else {
        outcome = UpdateCheckOutcome.updateAvailable;
      }
      await _store.save(
        settings.copyWith(
          lastCheckedUtc: now,
          etag: response.etag,
          // 304（空表）时 `response.etag` 会带回原值；真的没有 ETag 时保留旧的，
          // 而不是把已经有效的验证器清掉。
          clearEtag: response.etag == null,
        ),
      );
      return UpdateCheckResult(
        outcome: outcome,
        currentVersion: currentVersion,
        version: release?.version,
        release: release,
      );
    } on UpdateCheckException catch (error) {
      await _rememberAttempt(settings, now);
      return UpdateCheckResult.failed(
        failure: error.reason,
        currentVersion: currentVersion,
      );
    } on Object {
      // **兜底必须存在**：客户端替身、将来的实现、或 `package:http` 之外的任何一层都可能抛
      // 出别的东西，而它们不允许以原始异常的形式到达界面。
      await _rememberAttempt(settings, now);
      return UpdateCheckResult.failed(
        failure: UpdateFailureReason.unknown,
        currentVersion: currentVersion,
      );
    }
  }

  /// 失败也要记下检查时间。
  ///
  /// **为什么**：不记的话，离线状态下每次启动都会重试一次，而用户看到的是一串失败提示；
  /// 记下来之后，24 小时窗口与开关对失败**同样生效**——"不再自动联网"是用户拨开关时得到的
  /// 承诺，失败不该成为绕过它的路径。
  Future<void> _rememberAttempt(UpdateSettings settings, DateTime now) =>
      _store.save(settings.copyWith(lastCheckedUtc: now));

  Future<AppVersion?> _readCurrentVersion() async {
    final provider = versions;
    if (provider == null) return null;
    try {
      return await provider.currentVersion();
    } on Object {
      // 端口自己已经保证不抛，但这一层不能因此假设它永远不抛：版本读不出来只是少一行显示，
      // 不该让整次检查失败。
      return null;
    }
  }

  /// 找到**比当前版本更高**的那个 release；没有就返回 `null`。
  ///
  /// 三条都在这里定：
  ///   · **`> current` 才算更新**：等于当前版本是"已是最新"，低了更不能提示（用户装了
  ///     `1.6.2+37` 却被告知 `1.6.1` 可下载，是明确的错误）；
  ///   · **列表顺序不假设**：GitHub 按创建时间返回，而我们比的是版本号，两者顺序可以不同
  ///     （手工补发一个旧版本的 Release 就会出现这种情形）；
  ///   · **基线未知时用 [unknownCurrentVersion]**：任何正式 release 都比它高，于是
  ///     "读不到版本"退化成"宁可多提醒一次"，而不是永远说已是最新。
  ReleaseInfo? _latestUsable(List<ReleaseInfo> releases, AppVersion current) {
    ReleaseInfo? best;
    for (final release in releases) {
      if (!(release.version > current)) continue;
      if (best == null || release.version > best.version) best = release;
    }
    return best;
  }

  /// 24 小时窗口是否已过。
  ///
  /// **时钟往回拨时返回 `true`**（允许检查）：`lastCheckedUtc` 落在未来会让差值恒为负数而
  /// 永远小于 24 小时，自动检查会被**永久饿死**——用户完全看不出原因的一种"检查不动了"。
  /// 宁可多检查一次，也不要卡死。
  bool _windowElapsed(DateTime? lastCheckedUtc, DateTime now) {
    if (lastCheckedUtc == null) return true;
    final elapsed = now.difference(lastCheckedUtc);
    if (elapsed.isNegative) return true;
    return elapsed >= updateCheckMinimumInterval;
  }
}
