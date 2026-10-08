// 更新检查的**判定**（路线图 §3.6 / §7.3 / §11 Task 10）。
//
// 这一层不碰网络：网络在 `GithubReleaseClient` 里，这里只决定"拿到这些 Release 之后算不算有更新"
// 以及"这次到底该不该发请求"。三件事各自都能静默做错，因此各自钉住：
//
// ① **版本比较**。tag 有 `1.7.0` 也有 `v1.7.0`，还有 draft、prerelease 与非法 tag。把非法 tag
//    当成"更高版本"会让用户收到一条永远装不上的提示；把 `v1.7.0` 漏掉则相反——真有新版却一直
//    说"已是最新"。
// ② **24 小时窗口**。自动检查在窗口内**一次请求都不该发**（不是"发了再忽略结果"）：GitHub 的
//    匿名额度按 IP 计，重复请求换来的是 403，而用户看到的是"检查失败"。
// ③ **跳过此版本**。跳过的是**那一个版本**，更高版本仍然要提醒（§3.6 原文）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/app_version_provider.dart';
import 'package:personal_planner/application/update_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/platform/update/github_release_client.dart';

/// 可读的内存设置存储：读失败可由用例控制（设置文件被手改坏是真实场景）。
final class _Settings implements SettingsRepository {
  _Settings([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;
  bool failReads = false;

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('设置读不出来');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

final class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

/// 记录调用次数的客户端替身。**次数本身就是要断言的东西**：24 小时窗口内必须是 0 次。
///
/// 它接收的是 [`_release`] 造出来的 GitHub 原始 JSON，再走一遍与真实客户端同一套解析
/// （所以这里能直接断言"跳过的是版本号本身"这类规则，而不是断言一个手搭的 `ReleaseInfo`）。
final class _Client implements GithubReleaseClient {
  _Client({List<Map<String, Object?>>? releases, this.error})
    : releases = releases ?? const [];

  List<Map<String, Object?>> releases;
  Object? error;
  int calls = 0;
  String? lastEtag;

  @override
  Future<GithubReleasesResponse> fetchReleases({String? etag}) async {
    calls++;
    lastEtag = etag;
    final failure = error;
    if (failure != null) throw failure;
    final parsed = <ReleaseInfo>[];
    for (final raw in releases) {
      if (raw['draft'] == true || raw['prerelease'] == true) continue;
      final version = AppVersion.parse(raw['tag_name'] as String?);
      if (version == null) continue;
      parsed.add(
        ReleaseInfo(
          tagName: raw['tag_name']! as String,
          version: version,
          notes: raw['body'] as String? ?? '',
          publishedAtUtc: DateTime.tryParse(
            raw['published_at'] as String? ?? '',
          )?.toUtc(),
          htmlUrl: raw['html_url'] as String?,
        ),
      );
    }
    return GithubReleasesResponse(releases: parsed, etag: '"etag-1"');
  }
}

Map<String, Object?> _release({
  required String tag,
  bool draft = false,
  bool prerelease = false,
  String publishedAt = '2026-10-01T00:00:00Z',
  String body = '修好了几处让人困惑的地方。',
  String? htmlUrl,
}) => {
  'tag_name': tag,
  'name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'published_at': publishedAt,
  'body': body,
  'html_url':
      htmlUrl ??
      'https://github.com/ShuoZhuang/Best-Planning/releases/tag/$tag',
};

void main() {
  group('版本比较', () {
    test('1.7.0 与 v1.7.0 都算有更新', () async {
      for (final tag in const ['1.7.0', 'v1.7.0']) {
        final client = _Client(releases: [_release(tag: tag)]);
        final result = await _service(client: client).check(manual: true);
        expect(
          result.outcome,
          UpdateCheckOutcome.updateAvailable,
          reason: '$tag 必须能被识别为更新',
        );
        expect(result.version?.minor, 7);
        expect(result.release?.version, AppVersion(1, 7, 0));
      }
    });

    test('v 前缀去掉后与不带前缀的版本相等', () {
      expect(AppVersion.parse('v1.7.0'), AppVersion.parse('1.7.0'));
      expect(
        AppVersion.parse('v1.7.0')!.compareTo(AppVersion.parse('1.7.0')!),
        0,
      );
    });

    test('相同版本不算更新', () async {
      final client = _Client(
        releases: [
          _release(tag: 'v1.6.2', publishedAt: '2026-10-08T00:00:00Z'),
        ],
      );
      final result = await _service(client: client).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.upToDate);
      // "没有更新"时 `version` 保持为空：界面据此不显示版本行，而不是显示当前版本号的副本。
      expect(result.version, isNull);
      expect(result.release, isNull);
      expect(result.currentVersion, AppVersion(1, 6, 2));
    });

    test('低于当前版本的 Release 不算更新', () async {
      final client = _Client(releases: [_release(tag: '1.6.1')]);
      final result = await _service(client: client).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.upToDate);
    });

    test('构建号不参与比较：1.6.2+37 与 1.6.2 是同一个版本', () {
      expect(
        AppVersion.parse('1.6.2+37')!.compareTo(AppVersion.parse('1.6.2')!),
        0,
      );
      expect(AppVersion.parse('1.6.2+37')!.build, 37);
    });

    test('draft 与 prerelease 一律忽略', () async {
      final client = _Client(
        releases: [
          _release(tag: 'v1.8.0', draft: true),
          _release(tag: 'v1.7.5', prerelease: true),
          _release(tag: 'v1.7.0'),
        ],
      );
      final result = await _service(client: client).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.updateAvailable);
      expect(result.version, AppVersion(1, 7, 0));
    });

    test('只有 draft 与 prerelease 时是最新，而不是"有更新"', () async {
      final client = _Client(
        releases: [
          _release(tag: 'v9.9.9', draft: true),
          _release(tag: 'v9.9.8', prerelease: true),
        ],
      );
      final result = await _service(client: client).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.upToDate);
      expect(result.version, isNull);
    });

    test('非法 tag 被跳过，不会当成更高版本', () async {
      final client = _Client(
        releases: [
          _release(tag: 'nightly'),
          _release(tag: 'v1.7'),
          _release(tag: 'v1.7.0.1'),
          _release(tag: ''),
          _release(tag: 'v1.7.0'),
        ],
      );
      final result = await _service(client: client).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.updateAvailable);
      expect(result.release?.tagName, 'v1.7.0');
    });

    test('全是非法 tag 时是最新，且不抛异常', () async {
      final client = _Client(
        releases: [
          _release(tag: 'latest'),
          _release(tag: 'x'),
        ],
      );
      final result = await _service(client: client).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.upToDate);
    });

    test('运行时版本读不出来时按 0.0.0 处理：宁可多提醒一次，也不要永远说"已是最新"', () async {
      final client = _Client(releases: [_release(tag: 'v1.0.0')]);
      final result = await _service(
        client: client,
        currentVersion: null,
      ).check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.updateAvailable);
      expect(result.currentVersion, isNull);
    });
  });

  group('24 小时窗口与开关', () {
    test('自动检查默认开启，且首次会发请求', () async {
      final client = _Client(releases: [_release(tag: 'v1.7.0')]);
      final service = _service(client: client);
      expect((await service.loadSettings()).autoCheckEnabled, isTrue);

      final result = await service.check(manual: false);
      expect(result.outcome, UpdateCheckOutcome.updateAvailable);
      expect(client.calls, 1);
    });

    test('自动检查在 24 小时内不重复请求（不是"发了再忽略"）', () async {
      final client = _Client(releases: [_release(tag: 'v1.6.2')]);
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final service = _service(client: client, clock: clock);

      expect(
        (await service.check(manual: false)).outcome,
        UpdateCheckOutcome.upToDate,
      );
      expect(client.calls, 1);

      clock.now = DateTime.utc(2026, 10, 8, 23, 59);
      final second = await service.check(manual: false);
      expect(second.outcome, UpdateCheckOutcome.throttled);
      expect(client.calls, 1, reason: '窗口内一次请求都不该发');

      clock.now = DateTime.utc(2026, 10, 9, 1);
      expect(
        (await service.check(manual: false)).outcome,
        UpdateCheckOutcome.upToDate,
      );
      expect(client.calls, 2);
    });

    test('手动检查不受 24 小时限制', () async {
      final client = _Client(releases: [_release(tag: 'v1.6.2')]);
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final service = _service(client: client, clock: clock);

      await service.check(manual: false);
      await service.check(manual: true);
      await service.check(manual: true);
      expect(client.calls, 3);
    });

    test('关闭自动检查后自动检查一次请求都不发，手动仍然可以', () async {
      final client = _Client(releases: [_release(tag: 'v1.7.0')]);
      final service = _service(client: client);
      await service.saveSettings(
        (await service.loadSettings()).copyWith(autoCheckEnabled: false),
      );

      final auto = await service.check(manual: false);
      expect(auto.outcome, UpdateCheckOutcome.disabled);
      expect(client.calls, 0);

      expect(
        (await service.check(manual: true)).outcome,
        UpdateCheckOutcome.updateAvailable,
      );
      expect(client.calls, 1);
    });

    test('检查成功后记下时间与 ETag；304 也算检查过', () async {
      final client = _Client(releases: [_release(tag: 'v1.6.2')]);
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final settings = _Settings();
      final service = _service(
        client: client,
        clock: clock,
        settings: settings,
      );

      await service.check(manual: false);
      final stored = await service.loadSettings();
      expect(stored.lastCheckedUtc, clock.now);
      expect(stored.etag, '"etag-1"');

      // 304：带上次的 ETag 去问，客户端返回空表 + 同一个 ETag。
      final notModified = _Client();
      final second = _service(
        client: notModified,
        clock: clock,
        settings: settings,
      );
      clock.now = DateTime.utc(2026, 10, 9, 2);
      final result = await second.check(manual: true);
      expect(result.outcome, UpdateCheckOutcome.upToDate);
      expect(notModified.lastEtag, '"etag-1"', reason: '必须把上次的 ETag 发出去');
    });

    test('上次检查时间早于未来时间（时钟被调后）时不认为窗口已过', () async {
      final client = _Client(releases: [_release(tag: 'v1.6.2')]);
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final service = _service(client: client, clock: clock);
      await service.check(manual: false);
      expect(client.calls, 1);

      // 用户把系统时间往回拨：lastChecked 变成"未来"。此时再算一次差值会得到负数而永远小于
      // 24 小时，于是自动检查会被**永久饿死**——那是用户完全看不出原因的一种"检查不动了"。
      clock.now = DateTime.utc(2026, 9, 1);
      final result = await service.check(manual: false);
      expect(result.outcome, UpdateCheckOutcome.upToDate);
      expect(client.calls, 2, reason: '时间往回拨之后必须允许重新检查');
    });
  });

  group('跳过此版本', () {
    test('跳过当前版本后不再提示，但更高版本仍然提示', () async {
      final client = _Client(releases: [_release(tag: 'v1.7.0')]);
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final service = _service(client: client, clock: clock);

      expect(
        (await service.check(manual: true)).outcome,
        UpdateCheckOutcome.updateAvailable,
      );
      await service.skipVersion(AppVersion(1, 7, 0));

      final skipped = await service.check(manual: true);
      expect(skipped.outcome, UpdateCheckOutcome.skippedVersion);
      expect(skipped.version, AppVersion(1, 7, 0));

      client.releases = [_release(tag: 'v1.7.1')];
      final higher = await service.check(manual: true);
      expect(higher.outcome, UpdateCheckOutcome.updateAvailable);
      expect(higher.version, AppVersion(1, 7, 1));
    });

    test('跳过的是版本号本身，重启后仍然生效（持久在设置里）', () async {
      final settings = _Settings();
      final first = _service(
        client: _Client(releases: [_release(tag: 'v1.7.0')]),
        settings: settings,
      );
      await first.skipVersion(AppVersion(1, 7, 0));

      final restarted = _service(
        client: _Client(releases: [_release(tag: 'v1.7.0')]),
        settings: settings,
      );
      expect(
        (await restarted.check(manual: true)).outcome,
        UpdateCheckOutcome.skippedVersion,
      );
    });
  });

  group('错误映射', () {
    Future<UpdateCheckResult> failing(Object error) => _service(
      client: _Client(error: error),
      clock: _Clock(DateTime.utc(2026, 10, 8)),
    ).check(manual: true);

    test('超时', () async {
      final result = await failing(
        const UpdateCheckException(UpdateFailureReason.timeout),
      );
      expect(result.outcome, UpdateCheckOutcome.failed);
      expect(result.failure, UpdateFailureReason.timeout);
    });

    test('离线', () async {
      final result = await failing(
        const UpdateCheckException(UpdateFailureReason.offline),
      );
      expect(result.outcome, UpdateCheckOutcome.failed);
      expect(result.failure, UpdateFailureReason.offline);
    });

    test('限流（403/429）', () async {
      final result = await failing(
        const UpdateCheckException(UpdateFailureReason.rateLimited),
      );
      expect(result.outcome, UpdateCheckOutcome.failed);
      expect(result.failure, UpdateFailureReason.rateLimited);
    });

    test('404 与其他非 200 都归为服务端问题', () async {
      final result = await failing(
        const UpdateCheckException(UpdateFailureReason.serverError),
      );
      expect(result.outcome, UpdateCheckOutcome.failed);
      expect(result.failure, UpdateFailureReason.serverError);
    });

    test('异常 JSON', () async {
      final result = await failing(
        const UpdateCheckException(UpdateFailureReason.malformedResponse),
      );
      expect(result.failure, UpdateFailureReason.malformedResponse);
    });

    test('未知异常也变成结构化失败，而不是把异常对象抛给界面', () async {
      final result = await failing(StateError('谁也没预料到的错'));
      expect(result.outcome, UpdateCheckOutcome.failed);
      expect(result.failure, UpdateFailureReason.unknown);
    });

    test('失败也要记下检查时间，否则每次启动都会重试一次', () async {
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final settings = _Settings();
      final client = _Client(
        error: const UpdateCheckException(UpdateFailureReason.offline),
      );
      final service = _service(
        client: client,
        clock: clock,
        settings: settings,
      );

      await service.check(manual: false);
      expect((await service.loadSettings()).lastCheckedUtc, clock.now);

      clock.now = DateTime.utc(2026, 10, 8, 2);
      expect(
        (await service.check(manual: false)).outcome,
        UpdateCheckOutcome.throttled,
      );
      expect(client.calls, 1);
    });
  });

  group('设置解析', () {
    test('默认：自动检查开启、没有上次时间、没有跳过版本', () async {
      final settings = await _service(settings: _Settings()).loadSettings();
      expect(settings.autoCheckEnabled, isTrue);
      expect(settings.lastCheckedUtc, isNull);
      expect(settings.skippedVersion, isNull);
      expect(settings.etag, isNull);
    });

    test('设置被手改坏时回默认，而不是让更新页打不开', () async {
      final settings = _Settings({
        JsonUpdateSettingsStore.storageKey: '{不是 JSON',
      });
      expect(
        (await _service(settings: settings).loadSettings()).autoCheckEnabled,
        isTrue,
      );
    });

    test('读设置抛异常时同样回默认', () async {
      final settings = _Settings()..failReads = true;
      expect(
        (await _service(settings: settings).loadSettings()).lastCheckedUtc,
        isNull,
      );
    });

    test('保存之后能读回来，且时间按 UTC 存', () async {
      final settings = _Settings();
      final clock = _Clock(DateTime.utc(2026, 10, 8, 1));
      final service = _service(settings: settings, clock: clock);

      await service.saveSettings(
        UpdateSettings(
          autoCheckEnabled: false,
          lastCheckedUtc: clock.now,
          skippedVersion: '1.7.0',
          etag: '"abc"',
        ),
      );
      final loaded = await service.loadSettings();
      expect(loaded.autoCheckEnabled, isFalse);
      expect(loaded.lastCheckedUtc, DateTime.utc(2026, 10, 8, 1));
      expect(loaded.skippedVersion, '1.7.0');
      expect(loaded.etag, '"abc"');
    });

    test('非法跳过版本在解析时被丢掉，不会永远压住某个版本', () async {
      final settings = _Settings({
        JsonUpdateSettingsStore.storageKey:
            '{"autoCheckEnabled":true,"skippedVersion":"latest"}',
      });
      expect(
        (await _service(settings: settings).loadSettings()).skippedVersion,
        isNull,
      );
    });
  });
}

UpdateService _service({
  GithubReleaseClient? client,
  Clock? clock,
  SettingsRepository? settings,
  AppVersion? currentVersion = const AppVersion(1, 6, 2),
}) => UpdateService(
  client: client ?? _Client(),
  clock: clock ?? _Clock(DateTime.utc(2026, 10, 8)),
  settings: settings ?? _Settings(),
  versions: currentVersion == null
      ? null
      : _FixedVersionProvider(currentVersion),
);

final class _FixedVersionProvider implements AppVersionProvider {
  const _FixedVersionProvider(this.version);
  final AppVersion version;
  @override
  Future<AppVersion?> currentVersion() async => version;
}
