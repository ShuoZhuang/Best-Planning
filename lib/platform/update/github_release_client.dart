// GitHub Release 客户端：**整个应用唯一的出网口**（路线图 §3.6 / §5 / §11 Task 10）。
//
// 为什么单独一个文件、单独一个类：本应用的产品承诺是"本地优先，数据不出本机"，而这条承诺此前由
// `test/architecture/no_network_test.dart` 以**禁止任何网络依赖与网络调用**的方式守着。加入更新
// 检查等于在这条门禁上开一个口子，因此这个口子必须**小到可以被逐行读完**：
//   · 固定仓库、固定 HTTPS URL（连 baseUrl 都不做成参数，否则它可以被指向别处）；
//   · 固定三个请求头，**不带任何本地数据**（不含 cookie、授权、查询参数里的版本）；
//   · 10 秒超时；
//   · 所有失败都变成 `UpdateCheckException`，异常对象里只有枚举名，没有主机名与路径。
//
// **刻意不做的事**：不重试。GitHub 的匿名额度按 IP 计，失败后立刻重试只会更快用光额度，
// 而调用方（`UpdateCheckController` 里的调度）本来就是"最多每 24 小时一次"。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:personal_planner/domain/models/app_update.dart';

/// 请求里带的 `User-Agent`。
///
/// **必须有**：GitHub 对没有 `User-Agent` 的请求直接回 403，而 403 在这里与"限流"是同一个
/// 状态码——不写它，用户看到的会是"GitHub 暂时限制了请求"，而真实原因是我们没报名字。
/// 带仓库名是为了让 GitHub 侧一眼看出请求来自哪个项目。
const String githubReleaseRequestUserAgent =
    'PersonalPlanner-UpdateCheck (+https://github.com/ShuoZhuang/Best-Planning)';

/// 被检查的仓库。**写死在代码里而不是做成参数**：做成参数就有第二个地方可以把它改成别的
/// 仓库，而"只请求这一个仓库"是隐私边界的一部分。
const String githubReleaseRepository = 'ShuoZhuang/Best-Planning';

/// 仓库的网页地址（更新页上"当前更新源"显示的就是它）。
const String githubReleaseRepositoryUrl =
    'https://github.com/ShuoZhuang/Best-Planning';

/// 列表接口。`per_page=20` 足够：本项目的 Release 节奏远低于这个数，而一页里通常已经有
/// 好几个历史版本可供比较。
final Uri githubReleasesEndpoint = Uri.parse(
  'https://api.github.com/repos/$githubReleaseRepository/releases?per_page=20',
);

/// 一次列表请求的结果。[etag] 为 `null` 表示这次的响应里没有 ETag（少见，但要能处理）。
final class GithubReleasesResponse {
  const GithubReleasesResponse({required this.releases, this.etag});

  /// 已经剔除 draft、prerelease 与非法 tag 的条目；**304 时为空表**。
  final List<ReleaseInfo> releases;

  final String? etag;
}

/// 端口 + 默认实现放在同一个文件：调用方（更新服务）只依赖 [GithubReleaseClient] 这个接口，
/// 测试可以给一个"一次都不发请求"的替身，而真实实现是这个文件里唯一 import `package:http` 的类。
abstract interface class GithubReleaseClient {
  Future<GithubReleasesResponse> fetchReleases({String? etag});
}

final class GithubReleaseClientImpl implements GithubReleaseClient {
  GithubReleaseClientImpl({
    http.Client? httpClient,
    this.timeout = defaultTimeout,
  }) : _http = httpClient ?? http.Client();

  /// 10 秒（§3.6 原文）。做成常量而不是字面量，是因为测试要断言"默认就是它"。
  static const Duration defaultTimeout = Duration(seconds: 10);

  final http.Client _http;
  final Duration timeout;

  @override
  Future<GithubReleasesResponse> fetchReleases({String? etag}) async {
    final request = http.Request('GET', githubReleasesEndpoint)
      // `application/vnd.github+json` 是 GitHub 推荐的媒体类型；用默认的 `*/*` 时
      // 响应里的字段名会随 API 版本漂移。
      ..headers['Accept'] = 'application/vnd.github+json'
      ..headers['User-Agent'] = githubReleaseRequestUserAgent;
    if (etag != null && etag.isNotEmpty) {
      // 只发 `If-None-Match`：**不发 `If-Modified-Since`**。后者要求我们自己保存并重放
      // 上次的 `Last-Modified`，而 ETag 已经是同一个目的的更强形式，多存一个时间戳只是多一处
      // 可能过期的状态。
      request.headers['If-None-Match'] = etag;
    }

    http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw const UpdateCheckException(UpdateFailureReason.timeout);
    } on SocketException {
      // 断网、DNS 失败。`SocketException` 的 `toString()` 带着主机名，因此这里**只取原因**，
      // 不把它带进异常。
      throw const UpdateCheckException(UpdateFailureReason.offline);
    } on http.ClientException {
      // 连接被中途关闭也走"网络不可用"：对用户来说两者是同一件事（再试一次或检查网络）。
      throw const UpdateCheckException(UpdateFailureReason.offline);
    } on Object {
      // 兜底：任何没预料到的异常也必须变成结构化原因，**不能原样抛给界面**
      // （本仓库已经因为把 `FileSystemException` 原样显示踩过一次）。
      throw const UpdateCheckException(UpdateFailureReason.unknown);
    }

    final responseEtag = response.headers['etag'];
    if (response.statusCode == 304) {
      // 304：内容没变。**不算失败**，它就是"已经是最新"的一种更省的表达方式。
      return GithubReleasesResponse(releases: const [], etag: responseEtag);
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const UpdateCheckException(UpdateFailureReason.rateLimited);
    }
    if (response.statusCode != 200) {
      // 404（仓库或 Release 不存在）与其他非 200 归为一类：对用户来说"服务器这边有问题"，
      // 而细分对用户没有任何可执行的区别。
      throw const UpdateCheckException(UpdateFailureReason.serverError);
    }

    final body = await _readBody(response);
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const UpdateCheckException(UpdateFailureReason.malformedResponse);
    }
    if (decoded is! List) {
      throw const UpdateCheckException(UpdateFailureReason.malformedResponse);
    }

    final releases = <ReleaseInfo>[];
    for (final item in decoded) {
      final release = _parseRelease(item);
      if (release != null) releases.add(release);
    }
    return GithubReleasesResponse(releases: releases, etag: responseEtag);
  }

  /// 读响应体。
  ///
  /// **读失败也映射成"网络不可用"**：连接在读完状态行之后被掐断时，异常会在这里冒出来，
  /// 而它在用户那边的含义与一开始就连不上是同一件事。
  Future<String> _readBody(http.StreamedResponse response) async {
    try {
      return await response.stream.bytesToString().timeout(timeout);
    } on TimeoutException {
      throw const UpdateCheckException(UpdateFailureReason.timeout);
    } on Object {
      throw const UpdateCheckException(UpdateFailureReason.offline);
    }
  }

  /// 把一条 JSON 变成 [ReleaseInfo]，**不合格就返回 `null`**。
  ///
  /// 在这里丢掉而不是报错，是刻意的取舍：一次响应里只要有一条能用的 release 就足够回答
  /// "有没有新版本"，为了别人的一条畸形数据让用户看到"检查更新失败"是本末倒置。
  ReleaseInfo? _parseRelease(Object? item) {
    if (item is! Map) return null;
    // §3.6：忽略 draft 与 prerelease。**先判这两个再解析版本**：它们的 tag 往往是
    // `v1.8.0-beta.1` 这类会解析失败的值，先解析会让"忽略 prerelease"看起来像"解析失败"。
    if (item['draft'] == true || item['prerelease'] == true) return null;
    final tag = item['tag_name'];
    if (tag is! String) return null;
    final version = AppVersion.parse(tag);
    if (version == null) return null;
    final publishedAt = item['published_at'];
    return ReleaseInfo(
      tagName: tag,
      version: version,
      // 正文缺省为空串（有的 Release 没写说明），界面据此不渲染说明区。
      notes: item['body'] is String ? item['body'] as String : '',
      publishedAtUtc: publishedAt is String
          ? DateTime.tryParse(publishedAt)?.toUtc()
          : null,
      // 缺失时不编一个链接出来：更新页据此不显示"查看下载"。
      htmlUrl: item['html_url'] is String ? item['html_url'] as String : null,
    );
  }
}
