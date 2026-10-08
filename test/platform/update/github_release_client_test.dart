// GitHub Release 客户端：**这是整个应用唯一的出网口**（路线图 §3.6 / §7.3 / §11 Task 10）。
//
// 因此这个文件的测试不只验证"能解析 JSON"，它同时是**联网边界**的一部分证据：
//   · 只请求固定仓库的公开 Release 元数据（URL 逐字断言，路径写错会连到别人的仓库）；
//   · 只发 `Accept` / `User-Agent` / `If-None-Match` 三个头——**不夹带任何本地数据**；
//   · 304 / 403 / 429 / 404 / 超时 / 离线 / 异常 JSON 各自映射成一条**结构化**原因，
//     而不是把异常对象抛给界面（本仓库已经因为"把异常原样打到界面上"踩过一次：
//     `backup_page.dart` 里 `FileSystemException` 连路径一起显示给了用户）。
//
// **一件刻意不做的事**：超时与限流**不重试**。GitHub 匿名额度按 IP 计，失败后立刻重试只会更快
// 用光额度；而这里的调用方（调度器）最多每 24 小时一次，本来就不需要重试。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/platform/update/github_release_client.dart';

/// 记录请求细节的 `http.Client` 替身。
///
/// **为什么不用 `package:http/testing.dart` 的 `MockClient`**：它只给"请求对象"，而本文件的
/// 核心断言之一是"**请求头里到底有什么**"；自己实现 `send` 可以直接把 `BaseRequest` 存下来，
/// 包括它带的所有头，也能精确控制"抛异常"与"返回状态码"两条不同路径。
final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  respond;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return respond(request);
  }

  http.BaseRequest get last => requests.last;

  Map<String, String> get lastHeaders => {
    for (final entry in last.headers.entries)
      entry.key.toLowerCase(): entry.value,
  };
}

http.StreamedResponse _json(
  Object body, {
  int status = 200,
  Map<String, String>? headers,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: headers ?? const {},
);

Map<String, Object?> _release({
  String tag = 'v1.7.0',
  bool draft = false,
  bool prerelease = false,
  String? body = '本版修好了几处让人困惑的地方。',
  String? publishedAt = '2026-10-01T00:00:00Z',
  String? htmlUrl,
  bool omitHtmlUrl = false,
}) {
  final json = <String, Object?>{
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
  };
  if (body != null) json['body'] = body;
  if (publishedAt != null) json['published_at'] = publishedAt;
  if (!omitHtmlUrl) {
    json['html_url'] =
        htmlUrl ??
        'https://github.com/ShuoZhuang/Best-Planning/releases/tag/$tag';
  }
  return json;
}

void main() {
  test('只请求固定仓库的公开 Release 元数据', () async {
    final client = _RecordingClient((_) async => _json([_release()]));
    await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();

    expect(client.requests, hasLength(1));
    final request = client.last;
    expect(request.method, 'GET');
    expect(
      request.url.toString(),
      'https://api.github.com/repos/ShuoZhuang/Best-Planning/releases?per_page=20',
    );
    expect(request.url.scheme, 'https'); // 明文 HTTP 在这里是不可接受的
  });

  test('请求头只有 Accept / User-Agent，不夹带任何本地数据', () async {
    final client = _RecordingClient((_) async => _json([_release()]));
    await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();

    final headers = client.lastHeaders;
    expect(headers['accept'], 'application/vnd.github+json');
    expect(headers['user-agent'], isNotEmpty);
    // **这一条是隐私边界**：出现任何一个"会被当成用户数据"的头都算失败。
    for (final forbidden in const [
      'cookie',
      'authorization',
      'x-forwarded-for',
      'referer',
    ]) {
      expect(headers.containsKey(forbidden), isFalse, reason: '不该发 $forbidden');
    }
    expect(headers.length, 2);
  });

  test('User-Agent 里带仓库名，便于 GitHub 侧识别请求来源', () {
    expect(githubReleaseRequestUserAgent, contains('Best-Planning'));
  });

  test('200：解析出 Release 列表、忽略 draft 与 prerelease', () async {
    final client = _RecordingClient(
      (_) async => _json([
        _release(tag: 'v1.8.0', draft: true),
        _release(tag: 'v1.7.5', prerelease: true),
        _release(tag: 'v1.7.0'),
        _release(tag: 'v1.6.2', publishedAt: '2026-10-08T00:00:00Z'),
      ]),
    );
    final response = await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();

    expect(response.releases.map((item) => item.version.label), [
      '1.7.0',
      '1.6.2',
    ]);
    final first = response.releases.first;
    expect(first.tagName, 'v1.7.0');
    expect(first.notes, contains('修好'));
    expect(first.publishedAtUtc, DateTime.utc(2026, 10, 1));
    expect(first.htmlUrl, contains('/releases/tag/v1.7.0'));
  });

  test('200：非法 tag 的条目直接丢掉，不进入结果', () async {
    final client = _RecordingClient(
      (_) async => _json([
        _release(tag: 'nightly'),
        _release(tag: 'v1.7'),
        _release(tag: 'v1.7.0'),
      ]),
    );
    final response = await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();
    expect(response.releases.map((item) => item.tagName), ['v1.7.0']);
  });

  test('200：缺字段的条目被丢掉，而不是整批失败', () async {
    final client = _RecordingClient(
      (_) async => _json([
        {'not_a_release': true},
        _release(tag: 'v1.7.0', omitHtmlUrl: true),
      ]),
    );
    final response = await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();
    expect(response.releases.map((item) => item.tagName), ['v1.7.0']);
    // 没有 html_url 时不编一个出来：界面据此不显示"查看下载"，而不是给一个假链接。
    expect(response.releases.single.htmlUrl, isNull);
  });

  test('200：响应体不是 JSON 数组时抛结构化异常', () async {
    final client = _RecordingClient((_) async => _json({'message': 'ok'}));
    await expectLater(
      GithubReleaseClientImpl(
        httpClient: client,
        timeout: const Duration(seconds: 10),
      ).fetchReleases(),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.reason,
          'reason',
          UpdateFailureReason.malformedResponse,
        ),
      ),
    );
  });

  test('200：响应体根本不是 JSON', () async {
    final client = _RecordingClient(
      (_) async => http.StreamedResponse(
        Stream.value(utf8.encode('<html>502 Bad Gateway</html>')),
        200,
      ),
    );
    await expectLater(
      GithubReleaseClientImpl(
        httpClient: client,
        timeout: const Duration(seconds: 10),
      ).fetchReleases(),
      throwsA(isA<UpdateCheckException>()),
    );
  });

  test('304：返回空列表，且带回 ETag', () async {
    final client = _RecordingClient(
      (_) async => http.StreamedResponse(
        const Stream.empty(),
        304,
        headers: {'etag': '"W/abc"'},
      ),
    );
    final response = await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();
    expect(response.releases, isEmpty);
    expect(response.etag, '"W/abc"');
  });

  test('带上 ETag 时发 If-None-Match；没有 ETag 时一个都不发', () async {
    final client = _RecordingClient((_) async => _json(const []));
    final releaseClient = GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    );

    await releaseClient.fetchReleases(etag: '"W/abc"');
    expect(client.lastHeaders['if-none-match'], '"W/abc"');

    await releaseClient.fetchReleases();
    expect(client.lastHeaders.containsKey('if-none-match'), isFalse);
  });

  test('200 也会带回响应里的 ETag，供下次使用', () async {
    final client = _RecordingClient(
      (_) async => _json([_release()], headers: {'etag': '"W/next"'}),
    );
    final response = await GithubReleaseClientImpl(
      httpClient: client,
      timeout: const Duration(seconds: 10),
    ).fetchReleases();
    expect(response.etag, '"W/next"');
  });

  test('403 与 429 都是限流', () async {
    for (final status in const [403, 429]) {
      final client = _RecordingClient(
        (_) async => _json(const {'message': 'rate limit'}, status: status),
      );
      await expectLater(
        GithubReleaseClientImpl(
          httpClient: client,
          timeout: const Duration(seconds: 10),
        ).fetchReleases(),
        throwsA(
          isA<UpdateCheckException>().having(
            (error) => error.reason,
            'reason',
            UpdateFailureReason.rateLimited,
          ),
        ),
        reason: 'HTTP $status 必须被识别为限流',
      );
    }
  });

  test('404 与其他非 200 归为服务端问题', () async {
    for (final status in const [404, 500, 503]) {
      final client = _RecordingClient(
        (_) async => _json(const {}, status: status),
      );
      await expectLater(
        GithubReleaseClientImpl(
          httpClient: client,
          timeout: const Duration(seconds: 10),
        ).fetchReleases(),
        throwsA(
          isA<UpdateCheckException>().having(
            (error) => error.reason,
            'reason',
            UpdateFailureReason.serverError,
          ),
        ),
        reason: 'HTTP $status 必须归为服务端问题',
      );
    }
  });

  test('超时映射成 timeout', () async {
    final client = _RecordingClient(
      (_) => Future.delayed(const Duration(seconds: 30), () => _json(const [])),
    );
    await expectLater(
      GithubReleaseClientImpl(
        httpClient: client,
        timeout: const Duration(milliseconds: 30),
      ).fetchReleases(),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.reason,
          'reason',
          UpdateFailureReason.timeout,
        ),
      ),
    );
  });

  test('离线（SocketException）映射成 offline', () async {
    final client = _RecordingClient(
      (_) => Future.error(
        const SocketException('Failed host lookup: api.github.com'),
      ),
    );
    await expectLater(
      GithubReleaseClientImpl(
        httpClient: client,
        timeout: const Duration(seconds: 10),
      ).fetchReleases(),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.reason,
          'reason',
          UpdateFailureReason.offline,
        ),
      ),
    );
  });

  test('http.ClientException 同样映射成 offline，而不是泄漏成未知异常', () async {
    final client = _RecordingClient(
      (_) => Future.error(http.ClientException('Connection closed')),
    );
    await expectLater(
      GithubReleaseClientImpl(
        httpClient: client,
        timeout: const Duration(seconds: 10),
      ).fetchReleases(),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.reason,
          'reason',
          UpdateFailureReason.offline,
        ),
      ),
    );
  });

  test('异常对象里不带任何本地路径或请求头内容', () async {
    // 这条守的是"用户看到的那句话"：异常最终会被界面显示出来，而它**绝不能**像
    // `FileSystemException` 那样把目录结构一起带出去。
    final client = _RecordingClient(
      (_) => Future.error(const SocketException('Failed host lookup')),
    );
    try {
      await GithubReleaseClientImpl(
        httpClient: client,
        timeout: const Duration(seconds: 10),
      ).fetchReleases();
      fail('应当抛出 UpdateCheckException');
    } on UpdateCheckException catch (error) {
      expect('$error', isNot(contains(r'\')));
      expect('$error', isNot(contains('Users')));
      expect('$error', isNot(contains('G:')));
    }
  });

  test('默认超时是 10 秒（规格写死的那个数）', () {
    expect(GithubReleaseClientImpl.defaultTimeout, const Duration(seconds: 10));
  });
}
