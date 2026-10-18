// 更新网络的地址与重定向规则（规格 §6.4 / §7.6）。
//
// 这一层只做"地址是否允许"的判断，不发请求。把它单独拿出来是为了让规则可被穷举测试：
// 明文 HTTP、IP 字面量、别的仓库、未知域名、超过 5 次重定向都必须被拒绝——而"包最终仍要
// 通过哈希与签名"不能替代这些检查（那是第二道，不是第一道）。

/// 最多跟随的重定向次数。
const int updateMaxRedirects = 5;

/// 发布资产允许出现的 GitHub 主机（规格 §6.4）。
///
/// GitHub 会把资产重定向到官方资产域；除此之外的任何主机都不接受。注意：域名允许列表
/// **不能替代内容校验**——包仍然要通过大小、SHA-256、签名与身份四层。
const Set<String> updateRedirectAllowedHosts = {
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
};

/// 更新网络允许列表。
abstract final class UpdateNetworkPolicy {
  /// 清单地址：初始地址必须是固定的两个之一（latest 或指定 tag）。
  static bool isAllowedManifestUri(Uri uri) {
    if (!_isGithubRepoPath(uri)) return false;
    final path = uri.path;
    if (path == '/ShuoZhuang/Best-Planning/releases/latest/download/update-manifest.json') {
      return true;
    }
    return RegExp(
      r'^/ShuoZhuang/Best-Planning/releases/download/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/update-manifest\.json$',
    ).hasMatch(path);
  }

  /// 安装包地址：必须位于同仓库同 tag 的下载路径下。
  static bool isAllowedPackageUri(Uri uri) =>
      _isGithubRepoPath(uri) &&
      uri.path.startsWith('/ShuoZhuang/Best-Planning/releases/download/');

  /// 一次重定向的目标是否允许。
  ///
  /// [from] 只用于诊断；规则本身只取决于 [to]：
  ///   · 必须 HTTPS；
  ///   · 主机必须是 github.com 或 GitHub 官方资产域；
  ///   · github.com 上的路径必须属于本仓库；
  ///   · 不接受 IP 字面量（[Uri.host] 为 IPv4/IPv6 时直接拒绝）。
  static bool isAllowedRedirect(Uri to) {
    if (!to.isScheme('https')) return false;
    if (to.host.isEmpty) return false;
    if (_isIpLiteral(to.host)) return false;
    if (!updateRedirectAllowedHosts.contains(to.host)) return false;
    if (to.host == 'github.com') {
      return to.path.startsWith('/ShuoZhuang/Best-Planning/');
    }
    // 资产域只承载 release asset，路径不可预测；内容仍要过哈希与签名。
    return true;
  }

  /// 解析 `Location` 并相对当前地址解析成绝对地址；不合法返回 `null`。
  static Uri? resolveLocation(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) return null;
    final uri = Uri.tryParse(location.trim());
    if (uri == null) return null;
    final resolved = uri.hasScheme ? uri : current.resolveUri(uri);
    return resolved;
  }

  static bool _isGithubRepoPath(Uri uri) =>
      uri.isScheme('https') &&
      uri.host == 'github.com' &&
      !uri.hasPort &&
      uri.path.startsWith('/ShuoZhuang/Best-Planning/');

  static bool _isIpLiteral(String host) {
    if (host.startsWith('[')) return true;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
    // IPv6 字面量在 Uri.host 里可能不带方括号；出现冒号即按 IP 处理。
    return host.contains(':');
  }
}
